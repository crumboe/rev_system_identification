/// Validation screen: run closed-loop step-response tests to verify
/// computed PID + FeedForward gains on the real (or simulated) controller.
///
/// Layout mirrors [TestScreen]: live charts on the left, mechanism visual
/// on the right, status bar and controls at the top.
library;

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../data/test_data.dart';
import '../../devices/device_manager.dart';

import '../tutorials/tutorial_keys.dart';
import '../../mechanisms/mechanism.dart';
import '../../simulation/project_physics_factory.dart';
import '../../simulation/simulated_device.dart';
import '../../simulation/flywheel_physics.dart';
import '../../state/app_state.dart';
import '../../sysid/pid_autotuner.dart';
import '../../sysid/response_diagnostics.dart';
import '../../sysid/validation_runner.dart';
import '../../can/spark_protocol.dart';
import '../widgets/arm_visual.dart';
import '../widgets/elevator_visual.dart';
import '../widgets/flywheel_visual.dart';
import '../widgets/jog_panel.dart';
import '../widgets/logo_header.dart';

class ValidationScreen extends ConsumerStatefulWidget {
  const ValidationScreen({super.key});

  @override
  ConsumerState<ValidationScreen> createState() => _ValidationScreenState();
}

class _ValidationScreenState extends ConsumerState<ValidationScreen> {
  ValidationRunner? _runner;
  bool _isRunning = false;
  bool _useStoredControllerGains = false;
  String _statusMessage =
      'Ready — compute and write gains from the Results '
      'page before running a validation test.';

  double _currentPosition = 0.0;
  Timer? _positionPollTimer;

  /// Live data for the current validation run.
  final List<DataPoint> _liveData = [];

  /// Setpoint at each sample index.
  final List<double> _liveSetpoints = [];

  /// Completed result (null until a test finishes).
  ValidationResult? _result;
  String? _error;

  /// Diagnosed response issues from the last completed test.
  List<ResponseDiagnostic> _diagnostics = [];

  // Setpoint editing controllers
  late TextEditingController _velSpCtrl;
  late TextEditingController _posSpCtrl;

  // Allowed closed-loop error controller
  late TextEditingController _clErrorCtrl;

  // Simulated load controller (raw voltage fallback for flywheel)
  late TextEditingController _loadCtrl;

  // Typed simulated mass controller for disturbance testing (arm/elevator sim).
  late TextEditingController _disturbanceMassCtrl;

  // Simulated load mass in kg for arm/elevator
  double? _simulatedLoadMassKg;

  // Validation-only integral overrides. Null means "use the auto-tuned value".
  double? _velocityIntegralOverride;
  double? _positionIntegralOverride;

  // Baseline gains captured from Results-page values before validation retuning.
  FeedforwardGains? _baselineFf;
  PidResult? _baselineVelocityPid;
  PidResult? _baselinePositionPid;
  bool _suppressBaselineAutoUpdate = false;

  // MAXMotion configuration controllers
  late TextEditingController _mmCruiseCtrl;
  late TextEditingController _mmAccelCtrl;
  late TextEditingController _mmJerkCtrl;
  late TextEditingController _mmErrorCtrl;
  int _mmPositionMode = kMAXMotionPositionModeTrapezoidal;
  final _mmFlyoutController = FlyoutController();

  @override
  void initState() {
    super.initState();
    final config = ref.read(mechanismConfigProvider);
    final defaults = ValidationParams.forMechanism(
      config.type,
      imperial: config.useImperialUnits,
    );
    _velSpCtrl = TextEditingController(
      text: defaults.velocitySetpoint.toString(),
    );
    _posSpCtrl = TextEditingController(
      text: defaults.positionSetpoint.toString(),
    );

    // MAXMotion defaults derived from the identified system and soft-limit range.
    const nominalVoltage = 12.0;
    // Guard against unrealistically large static friction (> 90 % of bus voltage).
    const maxKsFraction = 0.9;
    // Use 75 % of theoretical peak velocity and 50 % of theoretical peak accel
    // as conservative safe cruise/accel defaults.
    const cruiseFraction = 0.75;
    const accelFraction = 0.50;
    // Target 1 % of the working range as the allowed error (capped at 10 %).
    const errorRangePercent = 0.01;
    const maxErrorRangePercent = 0.1;

    final ff = ref.read(feedforwardGainsProvider);
    final fwdLimit = config.forwardSoftLimit;
    final revLimit = config.reverseSoftLimit;

    // Effective voltage available for motion after overcoming static friction.
    final effectiveVoltage = ff != null
        ? nominalVoltage - ff.kS.clamp(0.0, nominalVoltage * maxKsFraction)
        : 0.0;

    // Cruise velocity: cruiseFraction of the theoretical maximum velocity from kV.
    // Plant model: V = kS + kV·vel + kA·accel (V in volts, user units).
    // At nominal voltage with no acceleration: max_vel = (V_nom - kS) / kV.
    // Falls back to half the validation velocity setpoint when gains are absent.
    final double mmCruise;
    if (ff != null && ff.kV > 0) {
      final maxVel = effectiveVoltage / ff.kV;
      mmCruise = (maxVel * cruiseFraction).clamp(1.0, double.infinity);
    } else {
      mmCruise = defaults.velocitySetpoint * 0.5;
    }

    // Max acceleration: accelFraction of the theoretical maximum from kA.
    // At nominal voltage from rest: max_accel = (V_nom - kS) / kA.
    // Falls back to twice the validation velocity setpoint when gains are absent.
    final double mmAccel;
    if (ff != null && ff.kA > 0) {
      final maxAccel = effectiveVoltage / ff.kA;
      mmAccel = (maxAccel * accelFraction).clamp(1.0, double.infinity);
    } else {
      mmAccel = defaults.velocitySetpoint * 2.0;
    }

    // Allowed error: errorRangePercent of the soft-limit working range.
    // Falls back to 1 % of the position setpoint (minimum 0.01).
    final double mmError;
    if (fwdLimit != null && revLimit != null) {
      final range = (fwdLimit - revLimit).abs();
      mmError = (range * errorRangePercent).clamp(0.01, range * maxErrorRangePercent);
    } else {
      mmError = (defaults.positionSetpoint * errorRangePercent).clamp(0.01, 1.0);
    }

    _mmCruiseCtrl = TextEditingController(text: mmCruise.toStringAsFixed(1));
    _mmAccelCtrl = TextEditingController(text: mmAccel.toStringAsFixed(1));
    _mmJerkCtrl = TextEditingController(text: '0');
    _mmErrorCtrl = TextEditingController(text: mmError.toStringAsFixed(4));
    _clErrorCtrl = TextEditingController(text: '0');
    _loadCtrl = TextEditingController(text: '0');
    _disturbanceMassCtrl = TextEditingController(text: '0');
    _clErrorCtrl.addListener(_syncClErrorToProviders);
    _captureBaselineFromCurrentIfNeeded();

    _positionPollTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _pollPosition(),
    );
  }

  @override
  void dispose() {
    _positionPollTimer?.cancel();
    _velSpCtrl.dispose();
    _posSpCtrl.dispose();
    _mmCruiseCtrl.dispose();
    _mmAccelCtrl.dispose();
    _mmJerkCtrl.dispose();
    _mmErrorCtrl.dispose();
    _clErrorCtrl.removeListener(_syncClErrorToProviders);
    _clErrorCtrl.dispose();
    _loadCtrl.dispose();
    _disturbanceMassCtrl.dispose();
    _mmFlyoutController.dispose();
    super.dispose();
  }

  void _pollPosition() {
    if (_isRunning) return;
    final device = ref.read(deviceManagerProvider).leader;
    if (device == null || !device.isConnected) return;
    final config = ref.read(mechanismConfigProvider);
    final double rawPos;
    if (config.feedbackSensor == FeedbackSensor.absoluteEncoder) {
      rawPos =
          device.connection.lastStatus5?.absoluteEncoderPosition ??
          (device.connection.lastStatus2?.positionRotations ?? 0.0);
    } else if (config.feedbackSensor == FeedbackSensor.analogSensor) {
      rawPos = device.connection.lastStatus3?.analogPosition ??
          (device.connection.lastStatus2?.positionRotations ?? 0.0);
    } else {
      rawPos = device.connection.lastStatus2?.positionRotations ?? 0.0;
    }
    // Status frames already report in user units (onboard CFs).
    final userPos = rawPos;
    if ((userPos - _currentPosition).abs() > 0.01) {
      setState(() => _currentPosition = userPos);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<FeedforwardGains?>(feedforwardGainsProvider, (previous, next) {
      if (_suppressBaselineAutoUpdate || previous == next || !mounted) return;
      setState(() => _captureBaselineFromCurrentIfNeeded(force: true));
    });
    ref.listen<PidResult?>(pidResultProvider, (previous, next) {
      if (_suppressBaselineAutoUpdate || previous == next || !mounted) return;
      setState(() => _captureBaselineFromCurrentIfNeeded(force: true));
    });
    ref.listen<PidResult?>(posPidResultProvider, (previous, next) {
      if (_suppressBaselineAutoUpdate || previous == next || !mounted) return;
      setState(() => _captureBaselineFromCurrentIfNeeded(force: true));
    });

    final dm = ref.watch(deviceManagerProvider);
    final config = ref.watch(mechanismConfigProvider);
    final device = dm.leader;
    final ff = ref.watch(feedforwardGainsProvider);
    final velPid = ref.watch(pidResultProvider);
    final posPid = ref.watch(posPidResultProvider);

    final hasGains = ff != null && velPid != null;
    final hasPositionGains = ff != null && posPid != null;
    final usingStored = _useStoredControllerGains;
    final canRunVelocity =
        device != null &&
        device.isConnected &&
        !_isRunning &&
        (usingStored || hasGains);
    final canRunPosition =
        device != null &&
        device.isConnected &&
        !_isRunning &&
        (usingStored || hasPositionGains);
    final canRunDisturbance =
        canRunPosition &&
        (config.type == MechanismType.arm ||
            config.type == MechanismType.elevator);
    final canRunMAXMotion = canRunPosition;

    // Unit labels
    final velUnit = config.velocityUnit;
    final posUnit = config.positionUnit;

    return ScaffoldPage(
      header: LogoPageHeader(
        title: 'Validation',
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Allowed CL Error', style: TextStyle(fontSize: 11)),
            const SizedBox(width: 5),
            SizedBox(
              width: 170,
              child: TextBox(controller: _clErrorCtrl, enabled: !_isRunning),
            ),
          ],
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Compact status bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: _isRunning
                    ? Colors.warningPrimaryColor.withValues(alpha: 0.10)
                    : _error != null
                    ? Colors.red.withValues(alpha: 0.10)
                    : FluentTheme.of(
                        context,
                      ).resources.subtleFillColorSecondary,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(
                    _isRunning
                        ? FluentIcons.progress_loop_outer
                        : _error != null
                        ? FluentIcons.error
                        : FluentIcons.info,
                    size: 14,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _statusMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    onPressed: _isRunning ? _emergencyStop : null,
                    child: const Text('E-Stop'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            if (!usingStored && !hasGains) ...[
              const InfoBar(
                title: Text('No gains'),
                content: Text(
                  'Compute and write gains from the Results page first.',
                ),
                severity: InfoBarSeverity.info,
              ),
              const SizedBox(height: 8),
            ],

            // Setpoint controls + run buttons
            Row(
              key: TutorialKeys.validationTestSelector,
              children: [
                // Velocity setpoint
                SizedBox(
                  width: 160,
                  child: InfoLabel(
                    label: 'Velocity setpoint ($velUnit)',
                    child: TextBox(
                      controller: _velSpCtrl,
                      enabled: !_isRunning,
                      placeholder: velUnit,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: canRunVelocity
                      ? () => _runTest(
                          ValidationMode.velocity,
                          config,
                          device,
                          ff: ff,
                          velPid: velPid,
                          posPid: posPid,
                        )
                      : null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isRunning)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child: SizedBox(
                            width: 12,
                            height: 12,
                            child: ProgressRing(strokeWidth: 2),
                          ),
                        ),
                      const Text('Run Velocity Test'),
                    ],
                  ),
                ),

                const SizedBox(width: 24),

                // Position setpoint
                ...[
                  SizedBox(
                    width: 160,
                    child: InfoLabel(
                      label: 'Position setpoint ($posUnit)',
                      child: TextBox(
                        controller: _posSpCtrl,
                        enabled: !_isRunning,
                        placeholder: posUnit,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton(
                    onPressed: canRunPosition
                        ? () => _runTest(
                            ValidationMode.position,
                            config,
                            device,
                            ff: ff,
                            velPid: velPid,
                            posPid: posPid,
                          )
                        : null,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isRunning)
                          const Padding(
                            padding: EdgeInsets.only(right: 6),
                            child: SizedBox(
                              width: 12,
                              height: 12,
                              child: ProgressRing(strokeWidth: 2),
                            ),
                          ),
                        const Text('Run Position Test'),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    onPressed: canRunDisturbance
                        ? () {
                            _applyDisturbanceMassFromText(device, config);
                            _runTest(
                              ValidationMode.disturbancePosition,
                              config,
                              device,
                              ff: ff,
                              velPid: velPid,
                              posPid: posPid,
                            );
                          }
                        : null,
                    child: const Text('Run Disturbance Test'),
                  ),
                ],

                if (_isRunning) ...[
                  const SizedBox(width: 16),
                  Button(onPressed: _abort, child: const Text('Abort')),
                ],

                // MAXMotion run button + configuration flyout
                const SizedBox(width: 24),
                Column(
                  children: [
                    FilledButton(
                      onPressed: canRunMAXMotion
                          ? () => _runTest(
                              ValidationMode.maxMotionPosition,
                              config,
                              device!,
                              ff: ff,
                              velPid: velPid,
                              posPid: posPid,
                            )
                          : null,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(FluentIcons.rocket, size: 14),
                          const SizedBox(width: 6),
                          if (_isRunning &&
                              _lastMode == ValidationMode.maxMotionPosition)
                            const Padding(
                              padding: EdgeInsets.only(right: 6),
                              child: SizedBox(
                                width: 12,
                                height: 12,
                                child: ProgressRing(strokeWidth: 2),
                              ),
                            ),
                          const Text('Run MAXMotion Test'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    FlyoutTarget(
                      controller: _mmFlyoutController,
                      child: Button(
                        onPressed: _isRunning
                            ? null
                            : () {
                                _mmFlyoutController.showFlyout(
                                  placementMode:
                                      FlyoutPlacementMode.rightCenter,
                                  barrierDismissible: true,
                                  dismissOnPointerMoveAway: false,
                                  builder: (context) {
                                    return StatefulBuilder(
                                      builder: (context, setFlyoutState) {
                                        return FlyoutContent(
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 320,
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.all(16),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  const Text(
                                                    'MAXMotion Profile',
                                                    style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      fontSize: 14,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 12),
                                                  InfoLabel(
                                                    label:
                                                        'Cruise velocity ($velUnit)',
                                                    child: TextBox(
                                                      controller: _mmCruiseCtrl,
                                                      placeholder: velUnit,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  InfoLabel(
                                                    label:
                                                        'Max acceleration ($velUnit/s)',
                                                    child: TextBox(
                                                      controller: _mmAccelCtrl,
                                                      placeholder: '$velUnit/s',
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  InfoLabel(
                                                    label:
                                                        'Max jerk ($velUnit/s\u00b2)',
                                                    child: TextBox(
                                                      controller: _mmJerkCtrl,
                                                      placeholder:
                                                          '0 = trapezoidal',
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  InfoLabel(
                                                    label:
                                                        'Allowed error ($posUnit)',
                                                    child: TextBox(
                                                      controller: _mmErrorCtrl,
                                                      placeholder: posUnit,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  InfoLabel(
                                                    label: 'Profile mode',
                                                    child: ComboBox<int>(
                                                      value: _mmPositionMode,
                                                      isExpanded: true,
                                                      items: const [
                                                        ComboBoxItem(
                                                          value: 0,
                                                          child: Text(
                                                            'Trapezoidal',
                                                          ),
                                                        ),
                                                        ComboBoxItem(
                                                          value: 1,
                                                          child: Text(
                                                            'S-Curve',
                                                          ),
                                                        ),
                                                      ],
                                                      onChanged: (v) {
                                                        if (v != null) {
                                                          setState(
                                                            () =>
                                                                _mmPositionMode =
                                                                    v,
                                                          );
                                                          setFlyoutState(() {});
                                                        }
                                                      },
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    );
                                  },
                                );
                              },
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(FluentIcons.settings, size: 14),
                            SizedBox(width: 6),
                            Text('Profile Settings'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                // Simulated load control (sim-only, inline next to MAXMotion)
                if (device != null &&
                    device.isSimulated &&
                    device.connection is SimulatedSparkConnection) ...[
                  const SizedBox(width: 24),
                  if (config.type == MechanismType.arm ||
                      config.type == MechanismType.elevator) ...[
                    const Text('Simulated load mass (kg): '),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 120,
                      child: TextBox(
                        controller: _disturbanceMassCtrl,
                        enabled: !_isRunning,
                        placeholder: '0',
                        onChanged: (value) {
                          final parsed = double.tryParse(value);
                          if (parsed == null || _isRunning) return;
                          _setSimulatedLoadMassKg(
                            device,
                            config,
                            parsed,
                            updateTextField: false,
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Button(
                      onPressed: () =>
                          _adjustSimulatedLoadMassKg(device, config, -0.5),
                      child: const Text('-0.5 kg'),
                    ),
                    const SizedBox(width: 6),
                    Button(
                      onPressed: () =>
                          _adjustSimulatedLoadMassKg(device, config, 0.5),
                      child: const Text('+0.5 kg'),
                    ),
                    if (_simulatedLoadMassKg != null &&
                        _simulatedLoadMassKg! > 0)
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: InfoBadge(
                          source: const Text('LOADED'),
                          color: Colors.orange,
                        ),
                      ),
                  ] else ...[
                    SizedBox(
                      width: 200,
                      child: InfoLabel(
                        label: 'Simulated load (V)',
                        child: TextBox(
                          controller: _loadCtrl,
                          enabled: !_isRunning,
                          placeholder: '0',
                          onChanged: (val) {
                            final load = double.tryParse(val) ?? 0.0;
                            final conn =
                                device.connection as SimulatedSparkConnection;
                            conn.physics.loadTorqueVolts = load;
                          },
                        ),
                      ),
                    ),
                  ],
                ],
              ],
            ),

            // Live charts + mechanism visual
            Expanded(
              key: TutorialKeys.validationChart,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const chartAreaMinHeight = 520.0;
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: constraints.maxHeight),
                      child: Column(
                        children: [
                          SizedBox(
                            height: chartAreaMinHeight,
                            child: Row(
                      children: [
                        // Charts
                        Expanded(
                          flex: 3,
                          child: Column(
                            children: [
                              // Top row: velocity + voltage
                              Expanded(
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: _ValidationLiveChart(
                                        title: 'Velocity',
                                        data: _liveData,
                                        setpoints: _liveSetpoints,
                                        yExtractor: (dp) => dp.velocity,
                                        showSetpoint:
                                            _result?.mode ==
                                                ValidationMode.velocity ||
                                            (_isRunning &&
                                                _lastMode ==
                                                    ValidationMode.velocity),
                                        yLabel: velUnit,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: _ValidationLiveChart(
                                        title: 'Voltage',
                                        data: _liveData,
                                        setpoints: const [],
                                        yExtractor: (dp) => dp.voltage,
                                        showSetpoint: false,
                                        yLabel: 'V',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              // Bottom row: position + current
                              Expanded(
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: _ValidationLiveChart(
                                        title: 'Position',
                                        data: _liveData,
                                        setpoints: _liveSetpoints,
                                        yExtractor: (dp) => dp.position,
                                        showSetpoint:
                                            _result?.mode ==
                                                ValidationMode.position ||
                                            _result?.mode ==
                                                ValidationMode
                                                    .disturbancePosition ||
                                            _result?.mode ==
                                                ValidationMode
                                                    .maxMotionPosition ||
                                            (_isRunning &&
                                                (_lastMode ==
                                                        ValidationMode
                                                            .position ||
                                                    _lastMode ==
                                                        ValidationMode
                                                            .disturbancePosition ||
                                                    _lastMode ==
                                                        ValidationMode
                                                            .maxMotionPosition)),
                                        yLabel: posUnit,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: _ValidationLiveChart(
                                        title: 'Current',
                                        data: _liveData,
                                        setpoints: const [],
                                        yExtractor: (dp) => dp.current,
                                        showSetpoint: false,
                                        yLabel: 'A',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),

                        // Mechanism visual panel
                        if (config.type == MechanismType.arm) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 260,
                            child: Column(
                              children: [
                                Expanded(
                                  child: ArmVisual(
                                    currentAngleDeg: _currentPosition,
                                    forwardLimitDeg: config.forwardSoftLimit,
                                    reverseLimitDeg: config.reverseSoftLimit,
                                    isDraggable:
                                        device != null &&
                                        device.isSimulated &&
                                        !_isRunning,
                                    onAngleChanged: (deg) =>
                                        _onDragPosition(device, config, deg),
                                  ),
                                ),
                                if (device != null && device.isConnected) ...[
                                  const SizedBox(height: 4),
                                  SizedBox(
                                    height: 190,
                                    child: JogPanel(
                                      device: device,
                                      config: config,
                                      enabled: !_isRunning,
                                      onPositionChanged: (pos) => setState(
                                        () => _currentPosition = pos,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                        if (config.type == MechanismType.elevator) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 260,
                            child: Column(
                              children: [
                                Expanded(
                                  child: ElevatorVisual(
                                    currentPosition: _currentPosition,
                                    forwardLimit: config.forwardSoftLimit,
                                    reverseLimit: config.reverseSoftLimit,
                                    unitLabel: config.useImperialUnits
                                        ? 'in'
                                        : 'm',
                                    isDraggable:
                                        device != null &&
                                        device.isSimulated &&
                                        !_isRunning,
                                    onPositionChanged: (pos) =>
                                        _onDragPosition(device, config, pos),
                                  ),
                                ),
                                if (device != null && device.isConnected) ...[
                                  const SizedBox(height: 4),
                                  SizedBox(
                                    height: 190,
                                    child: JogPanel(
                                      device: device,
                                      config: config,
                                      enabled: !_isRunning,
                                      onPositionChanged: (pos) => setState(
                                        () => _currentPosition = pos,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                        if ((config.type == MechanismType.flywheel ||
                                config.type == MechanismType.simple) &&
                            device != null &&
                            device.isConnected) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 260,
                            child: Column(
                              children: [
                                Expanded(
                                  child: FlywheelVisual(
                                    currentRotations: _currentPosition,
                                    isDraggable:
                                        device.isSimulated && !_isRunning,
                                    onRotationChanged: (rot) =>
                                        _onDragPosition(device, config, rot),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                SizedBox(
                                  height: 190,
                                  child: JogPanel(
                                    device: device,
                                    config: config,
                                    enabled: !_isRunning,
                                    onPositionChanged: (pos) =>
                                        setState(() => _currentPosition = pos),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Metrics strip and diagnostics appear below the chart area.
                  if (_result != null) ...[
                    const SizedBox(height: 8),
                    _MetricsStrip(
                      result: _result!,
                      velocityPid: velPid,
                      positionPid: posPid,
                      velocityIntegralOverride: _velocityIntegralOverride,
                      positionIntegralOverride: _positionIntegralOverride,
                      onVelocityIntegralOverrideChanged: (v) => setState(() {
                        final tuned = velPid?.kI;
                        _velocityIntegralOverride =
                            tuned == null ||
                                v == null ||
                                (v - tuned).abs() < 1e-12
                            ? null
                            : v;
                      }),
                      onPositionIntegralOverrideChanged: (v) => setState(() {
                        final tuned = posPid?.kI;
                        _positionIntegralOverride =
                            tuned == null ||
                                v == null ||
                                (v - tuned).abs() < 1e-12
                            ? null
                            : v;
                      }),
                      onApplyAndRetest: _applyTuningAndRetest,
                    ),
                    const SizedBox(height: 6),
                    _PidFfComparisonCard(
                      baselineFf: _baselineFf,
                      currentFf: ff,
                      baselineVelocityPid: _baselineVelocityPid,
                      currentVelocityPid: velPid,
                      baselinePositionPid: _baselinePositionPid,
                      currentPositionPid: posPid,
                      onUseCurrentAsBaseline: () {
                        setState(() {
                          _captureBaselineFromCurrentIfNeeded(force: true);
                        });
                      },
                    ),
                    const SizedBox(height: 4),
                    // Response diagnostics — fix-it bars
                    if (_diagnostics.isNotEmpty)
                      ..._diagnostics.map(
                        (d) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: InfoBar(
                            title: Text(d.description),
                            content: Text(d.remedy),
                            severity: d.type == DiagnosticType.oscillation
                                ? InfoBarSeverity.error
                                : d.type == DiagnosticType.largeOvershoot
                                ? InfoBarSeverity.warning
                                : d.type == DiagnosticType.noisyResponse
                                ? InfoBarSeverity.warning
                                : InfoBarSeverity.info,
                            action: FilledButton(
                              child: Text(d.title),
                              onPressed: () => _applyDiagnosticFix(d),
                            ),
                            isLong: true,
                          ),
                        ),
                      ),
                    const SizedBox(height: 4),
                  ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Test execution
  // -----------------------------------------------------------------------

  ValidationMode? _lastMode;

  static const double _realStartPositionBandwidthScale = 0.7;

  /// Apply the user-entered allowed CL error to a PidResult.
  PidResult? _applyClError(PidResult? pid) {
    if (pid == null) return null;
    final val = double.tryParse(_clErrorCtrl.text) ?? 0.0;
    if (val == pid.allowedClosedLoopError) return pid;
    return pid.copyWith(allowedClosedLoopError: val);
  }

  void _syncClErrorToProviders() {
    final val = double.tryParse(_clErrorCtrl.text);
    if (val == null) return;

    final velPid = ref.read(pidResultProvider);
    final posPid = ref.read(posPidResultProvider);
    _suppressBaselineAutoUpdate = true;
    try {
      if (velPid != null && (velPid.allowedClosedLoopError - val).abs() > 1e-12) {
        ref.read(pidResultProvider.notifier).state = velPid.copyWith(
          allowedClosedLoopError: val,
        );
      }

      if (posPid != null && (posPid.allowedClosedLoopError - val).abs() > 1e-12) {
        ref.read(posPidResultProvider.notifier).state = posPid.copyWith(
          allowedClosedLoopError: val,
        );
      }
    } finally {
      _suppressBaselineAutoUpdate = false;
    }
  }

  void _captureBaselineFromCurrentIfNeeded({bool force = false}) {
    final currentFf = ref.read(feedforwardGainsProvider);
    final currentVelocityPid = ref.read(pidResultProvider);
    final currentPositionPid = ref.read(posPidResultProvider);

    if (force || (_baselineFf == null && currentFf != null)) {
      _baselineFf = currentFf;
    }
    if (force || (_baselineVelocityPid == null && currentVelocityPid != null)) {
      _baselineVelocityPid = currentVelocityPid;
    }
    if (force || (_baselinePositionPid == null && currentPositionPid != null)) {
      _baselinePositionPid = currentPositionPid;
    }
  }

  PidResult? _applyValidationPidOverrides(
    PidResult? pid, {
    required bool isVelocity,
  }) {
    final adjusted = _applyClError(pid);
    if (adjusted == null) return null;

    final overrideKi = isVelocity
        ? _velocityIntegralOverride
        : _positionIntegralOverride;
    if (overrideKi == null || (overrideKi - adjusted.kI).abs() < 1e-12) {
      return adjusted;
    }

    var iZone = adjusted.iZone;
    final integralWindowVolts = adjusted.kI.abs() > 1e-12
        ? adjusted.kI.abs() * adjusted.iZone
        : 0.0;
    if (overrideKi.abs() <= 1e-12) {
      iZone = 0.0;
    } else if (integralWindowVolts > 0) {
      iZone = (integralWindowVolts / overrideKi.abs()).clamp(0.0, 100.0);
    }

    return adjusted.copyWith(kI: overrideKi, iZone: iZone);
  }

  Future<void> _runTest(
    ValidationMode mode,
    MechanismConfig config,
    SparkDevice device, {
    FeedforwardGains? ff,
    PidResult? velPid,
    PidResult? posPid,
  }) async {
    _captureBaselineFromCurrentIfNeeded();
    _applyConservativeRealPositionBandwidthStart(mode, device);

    var velSp = double.tryParse(_velSpCtrl.text);
    final posSp = double.tryParse(_posSpCtrl.text);

    String? simulationLimitMessage;
    if (mode == ValidationMode.velocity &&
        velSp != null &&
        device.isSimulated &&
        device.connection is SimulatedSparkConnection) {
      final conn = device.connection as SimulatedSparkConnection;
      final physics = conn.physics;
      if (physics is FlywheelPhysics && physics.kV > 0) {
        final maxRpm =
            ((physics.nominalVoltage - physics.kS).clamp(
              0.0,
              double.infinity,
            )) /
            physics.kV;
        if (velSp.abs() > maxRpm) {
          final clamped = maxRpm * 0.95 * velSp.sign;
          simulationLimitMessage =
              'Sim flywheel max speed is about ${maxRpm.toStringAsFixed(0)} RPM; '
              'clamped setpoint to ${clamped.toStringAsFixed(0)} RPM.';
          velSp = clamped;
        }
      }
    }

    if (mode == ValidationMode.velocity && (velSp == null || velSp == 0)) {
      setState(() => _error = 'Invalid velocity setpoint.');
      return;
    }
    if ((mode == ValidationMode.position ||
            mode == ValidationMode.disturbancePosition ||
            mode == ValidationMode.maxMotionPosition) &&
        (posSp == null)) {
      setState(() => _error = 'Invalid position setpoint.');
      return;
    }

    // Build MAXMotion config if running a profiled test.
    MAXMotionConfig? maxMotionConfig;
    if (mode == ValidationMode.maxMotionPosition) {
      final cruise = double.tryParse(_mmCruiseCtrl.text);
      final accel = double.tryParse(_mmAccelCtrl.text);
      final jerk = double.tryParse(_mmJerkCtrl.text);
      final error = double.tryParse(_mmErrorCtrl.text);
      if (cruise == null || accel == null || cruise <= 0 || accel <= 0) {
        setState(
          () =>
              _error = 'Invalid MAXMotion cruise velocity or max acceleration.',
        );
        return;
      }
      maxMotionConfig = MAXMotionConfig(
        cruiseVelocity: cruise,
        maxAcceleration: accel,
        maxJerk: jerk ?? 0,
        allowedError: error ?? 0,
        positionMode: _mmPositionMode,
      );
    }

    final params = ValidationParams(
      velocitySetpoint: velSp ?? 0,
      positionSetpoint: posSp ?? 0,
      holdDuration: 3.0,
      settleDuration: mode == ValidationMode.velocity ? 2.0 : 1.0,
      maxMotionConfig: maxMotionConfig,
    );

    setState(() {
      _isRunning = true;
      _lastMode = mode;
      _liveData.clear();
      _liveSetpoints.clear();
      _result = null;
      _error = null;
      _diagnostics = [];
      _statusMessage = mode == ValidationMode.velocity
          ? 'Running velocity step test — setpoint: '
                '${velSp?.toStringAsFixed(1)} ${config.velocityUnit} ...'
          : mode == ValidationMode.disturbancePosition
          ? 'Running disturbance hold test — target: '
                '${posSp?.toStringAsFixed(2)} ${config.positionUnit} (manual stop) ...'
          : mode == ValidationMode.maxMotionPosition
          ? 'Running MAXMotion position test — target: '
                '${posSp?.toStringAsFixed(2)} ${config.positionUnit} ...'
          : 'Running position step test — setpoint: '
                '${posSp?.toStringAsFixed(2)} ${config.positionUnit} ...';
      if (simulationLimitMessage != null) {
        _statusMessage = simulationLimitMessage!;
      }
    });

    _runner = ValidationRunner(
      device: device,
      mechanismConfig: config,
      feedforwardGains: ff,
      velocityPidGains: _applyValidationPidOverrides(velPid, isVelocity: true),
      positionPidGains: _applyValidationPidOverrides(posPid, isVelocity: false),
      useStoredControllerGains: _useStoredControllerGains,
    );

    try {
      late final ValidationResult result;
      if (mode == ValidationMode.velocity) {
        result = await _runner!.runVelocityTest(
          params: params,
          onProgress: _onProgress,
        );
      } else if (mode == ValidationMode.disturbancePosition) {
        result = await _runner!.runDisturbancePositionTest(
          params: params,
          onProgress: _onProgress,
        );
      } else if (mode == ValidationMode.maxMotionPosition) {
        result = await _runner!.runMAXMotionPositionTest(
          params: params,
          onProgress: _onProgress,
        );
      } else {
        result = await _runner!.runPositionTest(
          params: params,
          onProgress: _onProgress,
        );
      }

      if (mounted) {
        final tuning = ref.read(pidTuningParamsProvider);
        setState(() {
          _result = result;
          _error = result.error;
          _isRunning = false;
          _runner = null;
          _statusMessage = result.completed
              ? 'Validation ${mode.name} test completed — '
                    '${result.data.length} samples.'
              : 'Test stopped: ${result.error ?? "aborted"}';
          if (result.completed) {
            _diagnostics = ResponseDiagnostics.analyze(
              result: result,
              currentTauMs: tuning.velocityTimeConstantMs,
              currentBwHz: tuning.positionBandwidthHz,
              currentDamping: tuning.dampingRatio,
              currentClosedLoopError: double.tryParse(_clErrorCtrl.text) ?? 0.0,
            );
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isRunning = false;
          _runner = null;
          _statusMessage = 'Error: $e';
        });
      }
    }
  }

  void _applyConservativeRealPositionBandwidthStart(
    ValidationMode mode,
    SparkDevice device,
  ) {
    if (device.isSimulated || mode == ValidationMode.velocity) return;

    final notifier = ref.read(pidTuningParamsProvider.notifier);
    if (!notifier.isAtDefaults) return;

    final tuning = ref.read(pidTuningParamsProvider);
    final conservative = PidTuningParams.clampPositionBw(
      tuning.positionBandwidthHz * _realStartPositionBandwidthScale,
    );

    if ((conservative - tuning.positionBandwidthHz).abs() > 1e-9) {
      notifier.setPositionBandwidth(conservative);
    }
  }

  void _applyDiagnosticFix(ResponseDiagnostic diagnostic) {
    final action = diagnostic.action;
    final notifier = ref.read(pidTuningParamsProvider.notifier);

    // 1. Apply parameter changes.
    if (action.velocityTimeConstantMs != null) {
      notifier.setVelocityTimeConstant(action.velocityTimeConstantMs!);
    }
    if (action.positionBandwidthHz != null) {
      notifier.setPositionBandwidth(action.positionBandwidthHz!);
    }
    if (action.dampingRatio != null) {
      notifier.setDampingRatio(action.dampingRatio!);
    }
    if (action.closedLoopError != null) {
      _clErrorCtrl.text = action.closedLoopError!.toStringAsFixed(3);
    }

    _retuneAndRetest();
  }

  /// Called by the metrics strip flyout sliders — update tuning params then
  /// retune PID and rerun the same test.
  void _applyTuningAndRetest({
    double? velocityTimeConstantMs,
    double? positionBandwidthHz,
    double? dampingRatio,
  }) {
    final notifier = ref.read(pidTuningParamsProvider.notifier);
    if (velocityTimeConstantMs != null) {
      notifier.setVelocityTimeConstant(velocityTimeConstantMs);
    }
    if (positionBandwidthHz != null) {
      notifier.setPositionBandwidth(positionBandwidthHz);
    }
    if (dampingRatio != null) {
      notifier.setDampingRatio(dampingRatio);
    }
    _retuneAndRetest();
  }

  /// Retune PID gains from current provider state and rerun the last test.
  void _retuneAndRetest() {
    final tuning = ref.read(pidTuningParamsProvider);
    final ff = ref.read(feedforwardGainsProvider);
    final ffLoaded = ref.read(loadedFeedforwardGainsProvider);
    final config = ref.read(mechanismConfigProvider);

    if (ff == null) return;

    final totalDelaySec = PidAutoTuner.defaultTransportDelaySec +
        config.filterPhaseDelaySec;

    PidResult velPid;
    PidResult posPid;

    if (ffLoaded != null) {
      velPid = PidAutoTuner.tuneRobustVelocity(
        ffUnloaded: ff,
        ffLoaded: ffLoaded,
        mechanismType: config.type,
        desiredTimeConstantMs: tuning.velocityTimeConstantMs,
      );
      posPid = PidAutoTuner.tuneRobustPosition(
        ffUnloaded: ff,
        ffLoaded: ffLoaded,
        mechanismType: config.type,
        desiredBandwidthHz: tuning.positionBandwidthHz,
        dampingRatio: tuning.dampingRatio,
      );
    } else {
      velPid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: config.type,
        desiredTimeConstantMs: tuning.velocityTimeConstantMs,
        transportDelaySec: totalDelaySec,
      );
      posPid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: config.type,
        desiredBandwidthHz: tuning.positionBandwidthHz,
        dampingRatio: tuning.dampingRatio,
        transportDelaySec: totalDelaySec,
      );
    }

    // Store the retuned gains.
    _suppressBaselineAutoUpdate = true;
    try {
      ref.read(pidResultProvider.notifier).state = _applyClError(velPid);
      ref.read(posPidResultProvider.notifier).state = _applyClError(posPid);
    } finally {
      _suppressBaselineAutoUpdate = false;
    }

    // Rerun the same test with updated gains.
    final device = ref.read(deviceManagerProvider).leader;
    if (device == null || !device.isConnected) return;

    final mode = _lastMode;
    if (mode == null) return;

    _runTest(mode, config, device, ff: ff, velPid: velPid, posPid: posPid);
  }

  void _onProgress(ValidationProgress p) {
    if (!mounted) return;
    setState(() {
      _liveData.add(
        DataPoint(
          timestamp: p.elapsedSeconds,
          voltage: p.voltage,
          velocity: p.velocity,
          position: p.position,
          current: p.current,
        ),
      );
      _liveSetpoints.add(p.setpoint);
      _currentPosition = p.position;
    });
  }

  void _abort() {
    _runner?.abort();
  }

  void _emergencyStop() {
    _runner?.emergencyStop();
    setState(() {
      _isRunning = false;
      _statusMessage = 'EMERGENCY STOP — motor disabled.';
    });
  }

  void _onDragPosition(
    SparkDevice? device,
    MechanismConfig config,
    double userUnits,
  ) {
    if (device == null || !device.isSimulated) return;
    final conn = device.connection;
    if (conn is SimulatedSparkConnection) {
      final convFactor = config.positionConversionFactor;
      final rotations = convFactor != 0 ? userUnits / convFactor : 0.0;
      conn.physics.setPositionRotations(rotations);
      setState(() => _currentPosition = userUnits);
    }
  }

  void _setSimulatedLoadMassKg(
    SparkDevice device,
    MechanismConfig config,
    double massKg,
    {bool updateTextField = true}
  ) {
    final clamped = massKg.clamp(0.0, 100.0).toDouble();
    setState(() {
      _simulatedLoadMassKg = clamped;
      if (updateTextField) {
        _disturbanceMassCtrl.text = clamped.toStringAsFixed(2);
      }
    });
    final conn = device.connection as SimulatedSparkConnection;
    conn.physics.loadTorqueVolts = computeLoadTorqueVolts(
      loadMassKg: clamped,
      config: config,
      physics: conn.physics,
    );
  }

  void _applyDisturbanceMassFromText(
    SparkDevice device,
    MechanismConfig config,
  ) {
    final parsed = double.tryParse(_disturbanceMassCtrl.text);
    if (parsed == null) return;
    _setSimulatedLoadMassKg(device, config, parsed);
  }

  void _adjustSimulatedLoadMassKg(
    SparkDevice device,
    MechanismConfig config,
    double deltaKg,
  ) {
    final current = _simulatedLoadMassKg ?? 0.0;
    _setSimulatedLoadMassKg(device, config, current + deltaKg);
  }
}

// ---------------------------------------------------------------------------
// Metrics strip — compact row of key performance indicators with
// hover tooltips and click-to-adjust flyout sliders.
// ---------------------------------------------------------------------------

class _MetricsStrip extends ConsumerStatefulWidget {
  final ValidationResult result;
  final PidResult? velocityPid;
  final PidResult? positionPid;
  final double? velocityIntegralOverride;
  final double? positionIntegralOverride;
  final ValueChanged<double?>? onVelocityIntegralOverrideChanged;
  final ValueChanged<double?>? onPositionIntegralOverrideChanged;
  final void Function({
    double? velocityTimeConstantMs,
    double? positionBandwidthHz,
    double? dampingRatio,
  })
  onApplyAndRetest;

  const _MetricsStrip({
    required this.result,
    this.velocityPid,
    this.positionPid,
    this.velocityIntegralOverride,
    this.positionIntegralOverride,
    this.onVelocityIntegralOverrideChanged,
    this.onPositionIntegralOverrideChanged,
    required this.onApplyAndRetest,
  });

  @override
  ConsumerState<_MetricsStrip> createState() => _MetricsStripState();
}

class _MetricsStripState extends ConsumerState<_MetricsStrip> {
  final _riseTimeFlyout = FlyoutController();
  final _overshootFlyout = FlyoutController();
  final _ssErrorFlyout = FlyoutController();
  final _integralFlyout = FlyoutController();

  @override
  void dispose() {
    _riseTimeFlyout.dispose();
    _overshootFlyout.dispose();
    _ssErrorFlyout.dispose();
    _integralFlyout.dispose();
    super.dispose();
  }

  bool get _isVelocity => widget.result.mode == ValidationMode.velocity;

  bool _isLikelyLongDecayOvershoot() {
    final result = widget.result;
    final overshoot = result.overshootPercent;
    if (overshoot == null || overshoot <= 0 || result.data.length < 12) {
      return false;
    }

    final target = result.setpoints.first != 0
        ? result.setpoints.first
        : result.setpoints.last;
    final initial = _isVelocity
        ? result.data.first.velocity
        : result.data.first.position;
    final stepAmplitude = target - initial;
    if (stepAmplitude.abs() < 1e-9) return false;

    final stepSign = stepAmplitude >= 0 ? 1.0 : -1.0;
    final deadband = stepAmplitude.abs() * 0.01;

    final normalizedErrors = <double>[];
    for (var i = 0; i < result.data.length; i++) {
      final measured = _isVelocity
          ? result.data[i].velocity
          : result.data[i].position;
      final setpoint = i < result.setpoints.length
          ? result.setpoints[i]
          : target;
      normalizedErrors.add((measured - setpoint) * stepSign);
    }

    var peakIndex = 0;
    var peakValue = -double.infinity;
    for (var i = 0; i < normalizedErrors.length; i++) {
      if (normalizedErrors[i] > peakValue) {
        peakValue = normalizedErrors[i];
        peakIndex = i;
      }
    }
    if (peakValue <= deadband) return false;

    int postPeakCrossings = 0;
    double? prev;
    for (var i = peakIndex; i < normalizedErrors.length; i++) {
      final e = normalizedErrors[i];
      final signed = e.abs() <= deadband ? 0.0 : (e > 0 ? 1.0 : -1.0);
      if (prev != null && prev != 0.0 && signed != 0.0 && prev != signed) {
        postPeakCrossings++;
      }
      if (signed != 0.0) prev = signed;
    }

    final tailStart = (normalizedErrors.length * 0.8).floor();
    final tail = normalizedErrors.sublist(tailStart);
    final avgTailError =
        tail.fold<double>(0.0, (sum, v) => sum + v) / tail.length;

    // Long-decay overshoot tends to cross at most once after the first peak,
    // then approaches the target slowly from the same side.
    return postPeakCrossings <= 1 && avgTailError > deadband;
  }

  double _equivalentTauMsFromBw(double bwHz) {
    if (bwHz <= 0) return double.infinity;
    return 1000.0 / (2.0 * 3.141592653589793 * bwHz);
  }

  String _focusAdvice(String focus) {
    final riseMs = widget.result.riseTime != null
        ? (widget.result.riseTime! * 1000.0)
        : null;
    final overshoot = widget.result.overshootPercent;
    final ssError = widget.result.steadyStateError?.abs();

    switch (focus) {
      case 'rise':
        final measured = riseMs != null
            ? 'Current rise time is ${riseMs.toStringAsFixed(0)} ms. '
            : '';
        return _isVelocity
        ? '${measured}If it feels sluggish, decrease time constant slightly. '
          'Change \u03c4 in 10-20 ms steps; if overshoot grows, increase \u03c4 back one step.'
        : '${measured}Increase bandwidth to make it respond faster. '
          'Raise BW in 5-10% steps and keep \u03b6 around 0.8-1.2 if overshoot appears.';
      case 'overshoot':
        final measured = overshoot != null
            ? 'Current overshoot is ${overshoot.toStringAsFixed(1)}%. '
            : '';
        final longDecayOvershoot = !_isVelocity && _isLikelyLongDecayOvershoot();
        return _isVelocity
        ? '${measured}If it bounces past target, slow it down. '
          'Increase \u03c4 until overshoot drops below about 10-15%.'
        : longDecayOvershoot
            ? '${measured}This looks like a long-decay overshoot (little ringing). '
            'Keep damping healthy (\u03b6 around 0.9-1.3) and try increasing BW by about 5-15% '
                'to improve setpoint tracking, then retest for oscillation.'
            : '${measured}Add damping to calm ringing. '
            'Increase \u03b6 by about 0.1-0.3 or reduce BW by 10-20%.';
      case 'sse':
        final measured = ssError != null
            ? 'Current steady-state error is ${ssError.toStringAsFixed(3)}. '
            : '';
        return _isVelocity
        ? '${measured}If it never quite reaches target, check the model first. '
          'Verify feedforward and current limits, then adjust \u03c4 conservatively.'
        : '${measured}If it settles with offset, ease aggressiveness first. '
          'Reduce BW slightly and/or increase allowed closed-loop error if hunting persists.';
      default:
        return 'Adjust one parameter at a time, retest, and keep the version with the best rise/overshoot/error tradeoff.';
    }
  }

  Widget _buildTuningReference({required String focus}) {
    final tuning = ref.read(pidTuningParamsProvider);
    final eqTauMs = _equivalentTauMsFromBw(tuning.positionBandwidthHz);
    final advice = _focusAdvice(focus);

    Widget item({
      required String label,
      required String value,
      required String tooltip,
    }) {
      return Tooltip(
        message: tooltip,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            color: FluentTheme.of(context).micaBackgroundColor.withValues(alpha: 0.45),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 10)),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'Consolas',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            item(
              label: 'Damping Ratio',
              value: tuning.dampingRatio.toStringAsFixed(2),
              tooltip:
              'Higher damping reduces bounce. \u03b6 controls transient shape; low \u03b6 can oscillate. $advice',
            ),
            item(
              label: 'Bandwidth',
              value: '${tuning.positionBandwidthHz.toStringAsFixed(1)} Hz',
              tooltip:
              'Higher bandwidth reacts faster. BW raises loop crossover and sensitivity to noise/resonance. $advice',
            ),
            item(
              label: 'Time Constant',
              value: '${tuning.velocityTimeConstantMs.toStringAsFixed(0)} ms (vel), ${eqTauMs.toStringAsFixed(0)} ms (eq from BW)',
              tooltip:
              'Larger time constant is smoother and slower. \u03c4 sets velocity loop speed; BW roughly maps to 1/(2\u03c0BW). $advice',
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          advice,
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final modeLabel = switch (result.mode) {
      ValidationMode.velocity => 'Velocity',
      ValidationMode.position => 'Position',
      ValidationMode.disturbancePosition => 'Disturbance Position',
      ValidationMode.maxMotionPosition => 'MAXMotion Position',
    };

    return Card(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '$modeLabel step — '
            '${result.completed ? "Completed" : "Incomplete"}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          if (result.completed &&
              (widget.velocityPid != null || widget.positionPid != null)) ...[
            const SizedBox(width: 12),
            FlyoutTarget(
              controller: _integralFlyout,
              child: Tooltip(
                message: 'Validation-only kI overrides',
                child: Button(
                  onPressed: () {
                    _integralFlyout.showFlyout(
                      placementMode: FlyoutPlacementMode.topCenter,
                      barrierDismissible: true,
                      dismissOnPointerMoveAway: false,
                      builder: (_) => _buildIntegralOverrideFlyout(),
                    );
                  },
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.settings, size: 12),
                      SizedBox(width: 6),
                      Text('Integral Override'),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(width: 24),
          _plainMetric('Samples', '${result.data.length}'),
          _plainMetric(
            'Duration',
            '${result.durationSeconds.toStringAsFixed(1)}s',
          ),
          if (result.riseTime != null)
            _clickableMetric(
              label: 'Rise Time',
              value: '${(result.riseTime! * 1000).toStringAsFixed(0)} ms',
              tooltip: _isVelocity
                  ? 'Adjust \u03c4 to trade off speed vs stability. Open for guided recommendations.'
                  : 'Adjust bandwidth and damping to improve settling speed. Open for guided recommendations.',
              controller: _riseTimeFlyout,
              flyoutBuilder: _buildRiseTimeFlyout,
            ),
          if (result.overshootPercent != null)
            _clickableMetric(
              label: 'Overshoot',
              value: '${result.overshootPercent!.toStringAsFixed(1)}%',
              warn: result.overshootPercent! > 20,
              tooltip: _isVelocity
                  ? 'Overshoot is mainly managed with \u03c4 in velocity mode. Open for guided recommendations.'
                  : 'Overshoot is managed with damping ratio and bandwidth. Open for guided recommendations.',
              controller: _overshootFlyout,
              flyoutBuilder: _buildOvershootFlyout,
            ),
          if (result.steadyStateError != null)
            _clickableMetric(
              label: 'SS Error',
              value: result.steadyStateError!.toStringAsFixed(3),
              tooltip: _isVelocity
                  ? 'Steady-state error may indicate FF mismatch or conservative loop tuning. Open for guided recommendations.'
                  : 'Steady-state error can improve with BW, damping, and CL error tuning. Open for guided recommendations.',
              controller: _ssErrorFlyout,
              flyoutBuilder: _buildSsErrorFlyout,
            ),
        ],
      ),
    );
  }

  // -- Plain (non-interactive) metric ---------------------------------------

  Widget _plainMetric(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 10)),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontFamily: 'Consolas',
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // -- Clickable metric with tooltip + flyout --------------------------------

  Widget _clickableMetric({
    required String label,
    required String value,
    required String tooltip,
    required FlyoutController controller,
    required Widget Function() flyoutBuilder,
    bool warn = false,
  }) {
    return FlyoutTarget(
      controller: controller,
      child: Tooltip(
        message: tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () {
              controller.showFlyout(
                placementMode: FlyoutPlacementMode.topCenter,
                barrierDismissible: true,
                dismissOnPointerMoveAway: false,
                builder: (_) => flyoutBuilder(),
              );
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(label, style: const TextStyle(fontSize: 10)),
                      const SizedBox(width: 3),
                      Icon(
                        FluentIcons.chevron_up_small,
                        size: 8,
                        color: FluentTheme.of(
                          context,
                        ).typography.body?.color?.withValues(alpha: 0.5),
                      ),
                    ],
                  ),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'Consolas',
                      fontWeight: FontWeight.w600,
                      color: warn ? Colors.warningPrimaryColor : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // -- Flyout builders -------------------------------------------------------

  Widget _buildRiseTimeFlyout() {
    return StatefulBuilder(
      builder: (context, setFlyoutState) {
        final currentTuning = ref.read(pidTuningParamsProvider);
        return FlyoutContent(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isVelocity
                        ? 'Velocity Time Constant (\u03c4)'
                        : 'Position Bandwidth',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isVelocity
                        ? 'Lower \u03c4 rises faster, but reduces stability margin.'
                        : 'Higher BW responds faster, but increases sensitivity to noise and resonance.',
                    style: const TextStyle(fontSize: 11),
                  ),
                  const SizedBox(height: 10),
                  _buildTuningReference(focus: 'rise'),
                  const SizedBox(height: 12),
                  _TuningSlider(
                    label: '\u03c4',
                    unit: 'ms',
                    value: currentTuning.velocityTimeConstantMs,
                    min: 20,
                    max: 500,
                    onChanged: (v) {
                      ref
                          .read(pidTuningParamsProvider.notifier)
                          .setVelocityTimeConstant(v);
                      setFlyoutState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  _TuningSlider(
                    label: 'BW',
                    unit: 'Hz',
                    value: currentTuning.positionBandwidthHz,
                    min: 0.5,
                    max: 10,
                    onChanged: (v) {
                      ref
                          .read(pidTuningParamsProvider.notifier)
                          .setPositionBandwidth(v);
                      setFlyoutState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  _TuningSlider(
                    label: '\u03b6',
                    unit: '',
                    value: currentTuning.dampingRatio,
                    min: 0.1,
                    max: 5.0,
                    divisions: 49,
                    onChanged: (v) {
                      ref
                          .read(pidTuningParamsProvider.notifier)
                          .setDampingRatio(v);
                      setFlyoutState(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  _GainPreview(isVelocity: _isVelocity),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        final t = ref.read(pidTuningParamsProvider);
                        widget.onApplyAndRetest(
                          velocityTimeConstantMs: t.velocityTimeConstantMs,
                          positionBandwidthHz: t.positionBandwidthHz,
                          dampingRatio: t.dampingRatio,
                        );
                      },
                      child: const Text('Apply & Retest'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildOvershootFlyout() {
    return StatefulBuilder(
      builder: (context, setFlyoutState) {
        final currentTuning = ref.read(pidTuningParamsProvider);
        return FlyoutContent(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isVelocity
                        ? 'Velocity Time Constant (\u03c4)'
                        : 'Damping Ratio (\u03b6)',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isVelocity
                        ? 'Increase \u03c4 to reduce overshoot. Larger \u03c4 lowers loop bandwidth and peak response.'
                        : 'Increase \u03b6 to reduce bounce. \u03b6<1 is underdamped, \u03b6\u22481 is near-critical, \u03b6>1 is overdamped.',
                    style: const TextStyle(fontSize: 11),
                  ),
                  const SizedBox(height: 10),
                  _buildTuningReference(focus: 'overshoot'),
                  const SizedBox(height: 12),
                  _TuningSlider(
                    label: '\u03c4',
                    unit: 'ms',
                    value: currentTuning.velocityTimeConstantMs,
                    min: 20,
                    max: 500,
                    onChanged: (v) {
                      ref
                          .read(pidTuningParamsProvider.notifier)
                          .setVelocityTimeConstant(v);
                      setFlyoutState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  _TuningSlider(
                    label: 'BW',
                    unit: 'Hz',
                    value: currentTuning.positionBandwidthHz,
                    min: 0.5,
                    max: 10,
                    onChanged: (v) {
                      ref
                          .read(pidTuningParamsProvider.notifier)
                          .setPositionBandwidth(v);
                      setFlyoutState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  _TuningSlider(
                    label: '\u03b6',
                    unit: '',
                    value: currentTuning.dampingRatio,
                    min: 0.1,
                    max: 5.0,
                    divisions: 49,
                    onChanged: (v) {
                      ref
                          .read(pidTuningParamsProvider.notifier)
                          .setDampingRatio(v);
                      setFlyoutState(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  _GainPreview(isVelocity: _isVelocity),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        final t = ref.read(pidTuningParamsProvider);
                        widget.onApplyAndRetest(
                          velocityTimeConstantMs: t.velocityTimeConstantMs,
                          positionBandwidthHz: t.positionBandwidthHz,
                          dampingRatio: t.dampingRatio,
                        );
                      },
                      child: const Text('Apply & Retest'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSsErrorFlyout() {
    return StatefulBuilder(
      builder: (context, setFlyoutState) {
        final currentTuning = ref.read(pidTuningParamsProvider);
        return FlyoutContent(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isVelocity
                        ? 'Velocity Time Constant (\u03c4)'
                        : 'Position Bandwidth',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isVelocity
                        ? 'Check feedforward first, then tune \u03c4. Feedforward bias often dominates velocity steady-state error.'
                        : 'Reduce BW if it hunts near target. Lower BW or widen CL error deadband to avoid chatter.',
                    style: const TextStyle(fontSize: 11),
                  ),
                  const SizedBox(height: 10),
                  _buildTuningReference(focus: 'sse'),
                  const SizedBox(height: 12),
                  _TuningSlider(
                    label: '\u03c4',
                    unit: 'ms',
                    value: currentTuning.velocityTimeConstantMs,
                    min: 20,
                    max: 500,
                    onChanged: (v) {
                      ref
                          .read(pidTuningParamsProvider.notifier)
                          .setVelocityTimeConstant(v);
                      setFlyoutState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  _TuningSlider(
                    label: 'BW',
                    unit: 'Hz',
                    value: currentTuning.positionBandwidthHz,
                    min: 0.5,
                    max: 10,
                    onChanged: (v) {
                      ref
                          .read(pidTuningParamsProvider.notifier)
                          .setPositionBandwidth(v);
                      setFlyoutState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  _TuningSlider(
                    label: '\u03b6',
                    unit: '',
                    value: currentTuning.dampingRatio,
                    min: 0.1,
                    max: 5.0,
                    divisions: 49,
                    onChanged: (v) {
                      ref
                          .read(pidTuningParamsProvider.notifier)
                          .setDampingRatio(v);
                      setFlyoutState(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  _GainPreview(isVelocity: _isVelocity),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        final t = ref.read(pidTuningParamsProvider);
                        widget.onApplyAndRetest(
                          velocityTimeConstantMs: t.velocityTimeConstantMs,
                          positionBandwidthHz: t.positionBandwidthHz,
                          dampingRatio: t.dampingRatio,
                        );
                      },
                      child: const Text('Apply & Retest'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildIntegralOverrideFlyout() {
    return FlyoutContent(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Validation-Only Integral Override',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const SizedBox(height: 6),
              const Text(
                'Overrides apply to future validation runs only. '
                'Use Auto restores the computed kI.',
                style: TextStyle(fontSize: 11),
              ),
              const SizedBox(height: 12),
              if (widget.velocityPid != null)
                _integralOverrideControl(
                  label: 'Velocity kI',
                  tunedValue: widget.velocityPid!.kI,
                  overrideValue: widget.velocityIntegralOverride,
                  onChanged: widget.onVelocityIntegralOverrideChanged,
                ),
              if (widget.positionPid != null) ...[
                const SizedBox(height: 10),
                _integralOverrideControl(
                  label: 'Position kI',
                  tunedValue: widget.positionPid!.kI,
                  overrideValue: widget.positionIntegralOverride,
                  onChanged: widget.onPositionIntegralOverrideChanged,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _integralOverrideControl({
    required String label,
    required double tunedValue,
    required double? overrideValue,
    required ValueChanged<double?>? onChanged,
  }) {
    final active =
        overrideValue != null && (overrideValue - tunedValue).abs() > 1e-12;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '$label${active ? ' (override)' : ''}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Button(
              onPressed: onChanged == null ? null : () => onChanged(null),
              child: const Text('Use Auto'),
            ),
          ],
        ),
        NumberBox<double>(
          value: overrideValue ?? tunedValue,
          min: 0,
          max: 10,
          smallChange: 0.0001,
          clearButton: true,
          mode: SpinButtonPlacementMode.inline,
          onChanged: onChanged,
        ),
        const SizedBox(height: 2),
        Text(
          'Auto-tuned: ${tunedValue.toStringAsFixed(6)}',
          style: const TextStyle(fontSize: 11),
        ),
      ],
    );
  }
}

// -- Slider helper used inside flyouts ----------------------------------------

class _TuningSlider extends StatelessWidget {
  final String label;
  final String unit;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  const _TuningSlider({
    required this.label,
    required this.unit,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final displayValue = unit == 'ms'
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text('$label: ', style: const TextStyle(fontSize: 12)),
            Text(
              '$displayValue $unit',
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'Consolas',
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions:
              divisions ??
              ((max - min) / (unit == 'ms' ? 10 : 0.1)).round().clamp(10, 400),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

// -- Live gain preview inside flyout -----------------------------------------

class _GainPreview extends ConsumerWidget {
  final bool isVelocity;

  const _GainPreview({required this.isVelocity});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tuning = ref.watch(pidTuningParamsProvider);
    final ff = ref.watch(feedforwardGainsProvider);
    final ffLoaded = ref.watch(loadedFeedforwardGainsProvider);
    final config = ref.watch(mechanismConfigProvider);

    if (ff == null) return const SizedBox.shrink();

    final totalDelaySec = PidAutoTuner.defaultTransportDelaySec +
        config.filterPhaseDelaySec;

    final PidResult preview;
    if (isVelocity) {
      preview = ffLoaded != null
          ? PidAutoTuner.tuneRobustVelocity(
              ffUnloaded: ff,
              ffLoaded: ffLoaded,
              mechanismType: config.type,
              desiredTimeConstantMs: tuning.velocityTimeConstantMs,
            )
          : PidAutoTuner.tuneVelocity(
              ff: ff,
              mechanismType: config.type,
              desiredTimeConstantMs: tuning.velocityTimeConstantMs,
              transportDelaySec: totalDelaySec,
            );
    } else {
      preview = ffLoaded != null
          ? PidAutoTuner.tuneRobustPosition(
              ffUnloaded: ff,
              ffLoaded: ffLoaded,
              mechanismType: config.type,
              desiredBandwidthHz: tuning.positionBandwidthHz,
              dampingRatio: tuning.dampingRatio,
            )
          : PidAutoTuner.tunePosition(
              ff: ff,
              mechanismType: config.type,
              desiredBandwidthHz: tuning.positionBandwidthHz,
              dampingRatio: tuning.dampingRatio,
              transportDelaySec: totalDelaySec,
            );
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: FluentTheme.of(
          context,
        ).micaBackgroundColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          _gainCell('kP', preview.kP),
          if (preview.kI != 0) _gainCell('kI', preview.kI),
          _gainCell('kD', preview.kD),
        ],
      ),
    );
  }

  Widget _gainCell(String label, double value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 10)),
          Text(
            value.toStringAsFixed(6),
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'Consolas',
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _PidFfComparisonCard extends StatelessWidget {
  final FeedforwardGains? baselineFf;
  final FeedforwardGains? currentFf;
  final PidResult? baselineVelocityPid;
  final PidResult? currentVelocityPid;
  final PidResult? baselinePositionPid;
  final PidResult? currentPositionPid;
  final VoidCallback onUseCurrentAsBaseline;

  const _PidFfComparisonCard({
    required this.baselineFf,
    required this.currentFf,
    required this.baselineVelocityPid,
    required this.currentVelocityPid,
    required this.baselinePositionPid,
    required this.currentPositionPid,
    required this.onUseCurrentAsBaseline,
  });

  @override
  Widget build(BuildContext context) {
    final hasAny =
        (baselineFf != null && currentFf != null) ||
        (baselineVelocityPid != null && currentVelocityPid != null) ||
        (baselinePositionPid != null && currentPositionPid != null);
    if (!hasAny) return const SizedBox.shrink();

    return Card(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Results vs Validation Gain Changes',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Button(
                onPressed: onUseCurrentAsBaseline,
                child: const Text('Use Current as Baseline'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (baselineVelocityPid != null && currentVelocityPid != null)
            _comparisonSection(
              title: 'Velocity PID',
              rows: [
                _valueRow('kP', baselineVelocityPid!.kP, currentVelocityPid!.kP),
                _valueRow('kI', baselineVelocityPid!.kI, currentVelocityPid!.kI),
                _valueRow('kD', baselineVelocityPid!.kD, currentVelocityPid!.kD),
                _valueRow(
                  'dFilter',
                  baselineVelocityPid!.dFilter,
                  currentVelocityPid!.dFilter,
                ),
                _valueRow(
                  'CL Error',
                  baselineVelocityPid!.allowedClosedLoopError,
                  currentVelocityPid!.allowedClosedLoopError,
                ),
              ],
            ),
          if (baselinePositionPid != null && currentPositionPid != null)
            _comparisonSection(
              title: 'Position PID',
              rows: [
                _valueRow('kP', baselinePositionPid!.kP, currentPositionPid!.kP),
                _valueRow('kI', baselinePositionPid!.kI, currentPositionPid!.kI),
                _valueRow('kD', baselinePositionPid!.kD, currentPositionPid!.kD),
                _valueRow(
                  'dFilter',
                  baselinePositionPid!.dFilter,
                  currentPositionPid!.dFilter,
                ),
                _valueRow(
                  'CL Error',
                  baselinePositionPid!.allowedClosedLoopError,
                  currentPositionPid!.allowedClosedLoopError,
                ),
              ],
            ),
          if (baselineFf != null && currentFf != null)
            _comparisonSection(
              title: 'Feedforward',
              rows: [
                _valueRow('kS', baselineFf!.kS, currentFf!.kS),
                _valueRow('kV', baselineFf!.kV, currentFf!.kV),
                _valueRow('kA', baselineFf!.kA, currentFf!.kA),
                _valueRow('kG', baselineFf!.kG, currentFf!.kG),
              ],
            ),
          const SizedBox(height: 2),
          const Text(
            'Baseline is captured from the current Results-page gains. '
            'Validation retuning currently changes PID values; FF typically remains unchanged.',
            style: TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _comparisonSection({required String title, required List<Widget> rows}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          color: const Color(0x1A808080),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            ...rows,
          ],
        ),
      ),
    );
  }

  Widget _valueRow(String label, double baseline, double current) {
    final delta = current - baseline;
    final changed = delta.abs() > 1e-12;
    final deltaText = changed
        ? '${delta >= 0 ? '+' : ''}${delta.toStringAsExponential(3)}'
        : '0';
    final currentText = current.toStringAsExponential(3);
    final baselineText = baseline.toStringAsExponential(3);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(width: 62, child: Text(label, style: const TextStyle(fontSize: 10))),
          Expanded(
            child: Text(
              '$baselineText  ->  $currentText',
              style: const TextStyle(fontSize: 10, fontFamily: 'Consolas'),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Δ $deltaText',
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'Consolas',
              fontWeight: FontWeight.w600,
              color: changed ? Colors.warningPrimaryColor : null,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Live chart with optional setpoint overlay
// ---------------------------------------------------------------------------

class _ValidationLiveChart extends StatelessWidget {
  final String title;
  final List<DataPoint> data;
  final List<double> setpoints;
  final double Function(DataPoint) yExtractor;
  final bool showSetpoint;
  final String yLabel;

  const _ValidationLiveChart({
    required this.title,
    required this.data,
    required this.setpoints,
    required this.yExtractor,
    required this.showSetpoint,
    required this.yLabel,
  });

  @override
  Widget build(BuildContext context) {
    final measuredSpots = data
        .map((dp) => FlSpot(dp.timestamp, yExtractor(dp)))
        .toList();

    final setpointSpots = <FlSpot>[];
    if (showSetpoint) {
      for (var i = 0; i < data.length && i < setpoints.length; i++) {
        setpointSpots.add(FlSpot(data[i].timestamp, setpoints[i]));
      }
    }

    final lineBars = <LineChartBarData>[
      // Setpoint (dashed green)
      if (setpointSpots.isNotEmpty)
        LineChartBarData(
          spots: setpointSpots,
          isCurved: false,
          color: Colors.successPrimaryColor,
          barWidth: 2,
          dotData: const FlDotData(show: false),
          dashArray: [6, 3],
        ),
      // Measured (solid)
      if (measuredSpots.isNotEmpty)
        LineChartBarData(
          spots: measuredSpots,
          isCurved: false,
          color: Colors.blue,
          barWidth: 1.5,
          dotData: const FlDotData(show: false),
        ),
    ];

    final allSpots = <FlSpot>[...measuredSpots, ...setpointSpots];
    final minX = allSpots.isEmpty
        ? 0.0
        : allSpots.map((s) => s.x).reduce((a, b) => a < b ? a : b);
    var maxX = allSpots.isEmpty
        ? 1.0
        : allSpots.map((s) => s.x).reduce((a, b) => a > b ? a : b);
    if ((maxX - minX).abs() < 1e-6) {
      maxX = minX + 1.0;
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$title ($yLabel)',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (showSetpoint) ...[
                const Spacer(),
                Container(
                  width: 12,
                  height: 2,
                  color: Colors.successPrimaryColor,
                ),
                const SizedBox(width: 3),
                const Text('Setpoint', style: TextStyle(fontSize: 9)),
                const SizedBox(width: 8),
                Container(width: 12, height: 2, color: Colors.blue),
                const SizedBox(width: 3),
                Text('Measured', style: TextStyle(fontSize: 9)),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: lineBars.isEmpty
                ? const Center(child: Text('No data'))
                : LineChart(
                    LineChartData(
                      minX: minX,
                      maxX: maxX,
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipItems: (touchedSpots) {
                            return touchedSpots.map((spot) {
                              final label = (showSetpoint && spot.barIndex == 0)
                                  ? 'Setpoint'
                                  : 'Measured';
                              return LineTooltipItem(
                                '$label: ${spot.y.toStringAsFixed(2)} $yLabel\n'
                                't=${spot.x.toStringAsFixed(1)}s',
                                const TextStyle(fontSize: 10),
                              );
                            }).toList();
                          },
                        ),
                      ),
                      lineBarsData: lineBars,
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        bottomTitles: AxisTitles(
                          axisNameWidget: const Text(
                            'Time (s)',
                            style: TextStyle(fontSize: 10),
                          ),
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
                            getTitlesWidget: (v, _) => Text(
                              v.toStringAsFixed(1),
                              style: const TextStyle(fontSize: 9),
                            ),
                          ),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 44,
                            getTitlesWidget: (v, _) => Text(
                              v.toStringAsFixed(1),
                              style: const TextStyle(fontSize: 9),
                            ),
                          ),
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (v) => FlLine(
                          color: const Color(0x20808080),
                          strokeWidth: 0.5,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
