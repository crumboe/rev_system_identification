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
  String _statusMessage = 'Ready — compute and write gains from the Results '
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

  // Simulated load mass in kg for arm/elevator
  double? _simulatedLoadMassKg;

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
    _velSpCtrl =
        TextEditingController(text: defaults.velocitySetpoint.toString());
    _posSpCtrl =
        TextEditingController(text: defaults.positionSetpoint.toString());

    // Sensible MAXMotion defaults based on mechanism type.
    _mmCruiseCtrl = TextEditingController(
        text: (defaults.velocitySetpoint * 0.5).toStringAsFixed(1));
    _mmAccelCtrl = TextEditingController(
        text: (defaults.velocitySetpoint * 2.0).toStringAsFixed(1));
    _mmJerkCtrl = TextEditingController(text: '0');
    _mmErrorCtrl = TextEditingController(text: '0.05');
    _clErrorCtrl = TextEditingController(text: '0');
    _loadCtrl = TextEditingController(text: '0');

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
    _clErrorCtrl.dispose();
    _loadCtrl.dispose();
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
      rawPos = device.connection.lastStatus5?.absoluteEncoderPosition ??
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
    final dm = ref.watch(deviceManagerProvider);
    final config = ref.watch(mechanismConfigProvider);
    final device = dm.leader;
    final ff = ref.watch(feedforwardGainsProvider);
    final velPid = ref.watch(pidResultProvider);
    final posPid = ref.watch(posPidResultProvider);

    final hasGains = ff != null && velPid != null;
    final hasPositionGains = ff != null && posPid != null;
    final usingStored = _useStoredControllerGains;
    final canRunVelocity = device != null &&
        device.isConnected &&
        !_isRunning &&
      (usingStored || hasGains);
    final canRunPosition = device != null &&
        device.isConnected &&
        !_isRunning &&
      (usingStored || hasPositionGains);
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
              child: TextBox(
                controller: _clErrorCtrl,
                enabled: !_isRunning,
              ),
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
                        : FluentTheme.of(context)
                            .resources
                            .subtleFillColorSecondary,
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
                      ? () => _runTest(ValidationMode.velocity, config, device, ff: ff, velPid: velPid, posPid: posPid)
                      : null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isRunning)
                        const Padding(
                          padding: EdgeInsets.only(right: 6),
                          child:
                              SizedBox(width: 12, height: 12, child: ProgressRing(strokeWidth: 2)),
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
                        ? () =>
                            _runTest(ValidationMode.position, config, device, ff: ff, velPid: velPid, posPid: posPid)
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
                                child: ProgressRing(strokeWidth: 2)),
                          ),
                        const Text('Run Position Test'),
                      ],
                    ),
                  ),
                ],

                if (_isRunning) ...[
                  const SizedBox(width: 16),
                  Button(
                    onPressed: _abort,
                    child: const Text('Abort'),
                  ),
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
                              posPid: posPid)
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
                                  child: ProgressRing(strokeWidth: 2)),
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
                                  placementMode: FlyoutPlacementMode.rightCenter,
                                  barrierDismissible: true,
                                  dismissOnPointerMoveAway: false,
                                  builder: (context) {
                                    return StatefulBuilder(
                                      builder: (context, setFlyoutState) {
                                        return FlyoutContent(
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(maxWidth: 320),
                                            child: Padding(
                                              padding: const EdgeInsets.all(16),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  const Text('MAXMotion Profile',
                                                      style: TextStyle(
                                                          fontWeight: FontWeight.w600,
                                                          fontSize: 14)),
                                                  const SizedBox(height: 12),
                                                  InfoLabel(
                                                    label: 'Cruise velocity ($velUnit)',
                                                    child: TextBox(
                                                      controller: _mmCruiseCtrl,
                                                      placeholder: velUnit,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  InfoLabel(
                                                    label: 'Max acceleration ($velUnit/s)',
                                                    child: TextBox(
                                                      controller: _mmAccelCtrl,
                                                      placeholder: '$velUnit/s',
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  InfoLabel(
                                                    label: 'Max jerk ($velUnit/s\u00b2)',
                                                    child: TextBox(
                                                      controller: _mmJerkCtrl,
                                                      placeholder: '0 = trapezoidal',
                                                    ),
                                                  ),
                                                  const SizedBox(height: 8),
                                                  InfoLabel(
                                                    label: 'Allowed error ($posUnit)',
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
                                                          child: Text('Trapezoidal'),
                                                        ),
                                                        ComboBoxItem(
                                                          value: 1,
                                                          child: Text('S-Curve'),
                                                        ),
                                                      ],
                                                      onChanged: (v) {
                                                        if (v != null) {
                                                          setState(() => _mmPositionMode = v);
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
                      child: NumberBox<double>(
                        value: _simulatedLoadMassKg,
                        onChanged: _isRunning
                            ? null
                            : (v) {
                                setState(() => _simulatedLoadMassKg = v);
                                final conn = device.connection
                                    as SimulatedSparkConnection;
                                conn.physics.loadTorqueVolts =
                                    computeLoadTorqueVolts(
                                  loadMassKg: v ?? 0.0,
                                  config: config,
                                  physics: conn.physics,
                                );
                              },
                        smallChange: 0.1,
                        min: 0,
                        max: 100,
                        clearButton: false,
                        placeholder: '0',
                      ),
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
                            final conn = device.connection
                                as SimulatedSparkConnection;
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
              child: Column(
                children: [
                  Expanded(
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
                                      _result?.mode == ValidationMode.velocity ||
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
                                      _result?.mode == ValidationMode.position ||
                                          _result?.mode ==
                                              ValidationMode.maxMotionPosition ||
                                          (_isRunning &&
                                              (_lastMode ==
                                                      ValidationMode.position ||
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
                              isDraggable: device != null &&
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
                                onPositionChanged: (pos) =>
                                    setState(() => _currentPosition = pos),
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
                              unitLabel:
                                  config.useImperialUnits ? 'in' : 'm',
                              isDraggable: device != null &&
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
                                onPositionChanged: (pos) =>
                                    setState(() => _currentPosition = pos),
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
                              isDraggable: device.isSimulated && !_isRunning,
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

                  // Metrics strip (inside Expanded so it doesn't shrink charts)
                  if (_result != null) ...[
                    const SizedBox(height: 8),
                    _MetricsStrip(
                      result: _result!,
                      onApplyAndRetest: _applyTuningAndRetest,
                    ),
                    const SizedBox(height: 4),
                    // Response diagnostics — fix-it bars
                    if (_diagnostics.isNotEmpty)
                      ..._diagnostics.map((d) => Padding(
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
                          )),
                    const SizedBox(height: 4),

                  ],
                ],
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

  /// Apply the user-entered allowed CL error to a PidResult.
  PidResult? _applyClError(PidResult? pid) {
    if (pid == null) return null;
    final val = double.tryParse(_clErrorCtrl.text) ?? 0.0;
    if (val == pid.allowedClosedLoopError) return pid;
    return pid.copyWith(allowedClosedLoopError: val);
  }

  Future<void> _runTest(
    ValidationMode mode,
    MechanismConfig config,
    SparkDevice device, {
    FeedforwardGains? ff,
    PidResult? velPid,
    PidResult? posPid,
  }) async {
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
            ((physics.nominalVoltage - physics.kS).clamp(0.0, double.infinity)) /
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
        setState(() => _error = 'Invalid MAXMotion cruise velocity or max acceleration.');
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
      velocityPidGains: _applyClError(velPid),
      positionPidGains: _applyClError(posPid),
      useStoredControllerGains: _useStoredControllerGains,
    );

    try {
      late final ValidationResult result;
      if (mode == ValidationMode.velocity) {
        result = await _runner!.runVelocityTest(
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
              currentClosedLoopError:
                  double.tryParse(_clErrorCtrl.text) ?? 0.0,
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
      );
      posPid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: config.type,
        desiredBandwidthHz: tuning.positionBandwidthHz,
        dampingRatio: tuning.dampingRatio,
      );
    }

    // Store the retuned gains.
    ref.read(pidResultProvider.notifier).state = velPid;
    ref.read(posPidResultProvider.notifier).state = posPid;

    // Rerun the same test with updated gains.
    final device = ref.read(deviceManagerProvider).leader;
    if (device == null || !device.isConnected) return;

    final mode = _lastMode;
    if (mode == null) return;

    _runTest(
      mode,
      config,
      device,
      ff: ff,
      velPid: velPid,
      posPid: posPid,
    );
  }

  void _onProgress(ValidationProgress p) {
    if (!mounted) return;
    setState(() {
      _liveData.add(DataPoint(
        timestamp: p.elapsedSeconds,
        voltage: p.voltage,
        velocity: p.velocity,
        position: p.position,
        current: p.current,
      ));
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
}

// ---------------------------------------------------------------------------
// Metrics strip — compact row of key performance indicators with
// hover tooltips and click-to-adjust flyout sliders.
// ---------------------------------------------------------------------------

class _MetricsStrip extends ConsumerStatefulWidget {
  final ValidationResult result;
  final void Function({
    double? velocityTimeConstantMs,
    double? positionBandwidthHz,
    double? dampingRatio,
  }) onApplyAndRetest;

  const _MetricsStrip({
    required this.result,
    required this.onApplyAndRetest,
  });

  @override
  ConsumerState<_MetricsStrip> createState() => _MetricsStripState();
}

class _MetricsStripState extends ConsumerState<_MetricsStrip> {
  final _riseTimeFlyout = FlyoutController();
  final _overshootFlyout = FlyoutController();
  final _ssErrorFlyout = FlyoutController();

  @override
  void dispose() {
    _riseTimeFlyout.dispose();
    _overshootFlyout.dispose();
    _ssErrorFlyout.dispose();
    super.dispose();
  }

  bool get _isVelocity => widget.result.mode == ValidationMode.velocity;

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final modeLabel = switch (result.mode) {
      ValidationMode.velocity => 'Velocity',
      ValidationMode.position => 'Position',
      ValidationMode.maxMotionPosition => 'MAXMotion Position',
    };

    return Card(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '$modeLabel step — '
            '${result.completed ? "Completed" : "Incomplete"}',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 24),
          _plainMetric('Samples', '${result.data.length}'),
          _plainMetric('Duration',
              '${result.durationSeconds.toStringAsFixed(1)}s'),
          if (result.riseTime != null)
            _clickableMetric(
              label: 'Rise Time',
              value: '${(result.riseTime! * 1000).toStringAsFixed(0)} ms',
              tooltip: _isVelocity
                  ? 'Lower the time constant (\u03c4) for faster rise'
                  : 'Increase bandwidth (BW) for faster settling',
              controller: _riseTimeFlyout,
              flyoutBuilder: _buildRiseTimeFlyout,
            ),
          if (result.overshootPercent != null)
            _clickableMetric(
              label: 'Overshoot',
              value: '${result.overshootPercent!.toStringAsFixed(1)}%',
              warn: result.overshootPercent! > 20,
              tooltip: _isVelocity
                  ? 'Increase time constant (\u03c4) to slow the response'
                  : 'Increase damping ratio (\u03b6) to reduce overshoot',
              controller: _overshootFlyout,
              flyoutBuilder: _buildOvershootFlyout,
            ),
          if (result.steadyStateError != null)
            _clickableMetric(
              label: 'SS Error',
              value: result.steadyStateError!.toStringAsFixed(3),
              tooltip: _isVelocity
                  ? 'Check FF accuracy; increase \u03c4 if tracking lags'
                  : 'Reduce bandwidth (BW) or increase allowed CL error',
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
                      Icon(FluentIcons.chevron_up_small, size: 8,
                          color: FluentTheme.of(context).typography.body?.color
                              ?.withValues(alpha: 0.5)),
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
    return StatefulBuilder(builder: (context, setFlyoutState) {
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
                  _isVelocity ? 'Velocity Time Constant (\u03c4)' : 'Position Bandwidth',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  _isVelocity
                      ? 'Lower \u03c4 = faster rise but less stability margin'
                      : 'Higher BW = faster rise but more noise-sensitive',
                  style: const TextStyle(fontSize: 11),
                ),
                const SizedBox(height: 12),
                if (_isVelocity) ...[
                  _TuningSlider(
                    label: '\u03c4',
                    unit: 'ms',
                    value: currentTuning.velocityTimeConstantMs,
                    min: 20, max: 500,
                    onChanged: (v) {
                      ref.read(pidTuningParamsProvider.notifier)
                          .setVelocityTimeConstant(v);
                      setFlyoutState(() {});
                    },
                  ),
                ] else ...[
                  _TuningSlider(
                    label: 'BW',
                    unit: 'Hz',
                    value: currentTuning.positionBandwidthHz,
                    min: 1, max: 20,
                    onChanged: (v) {
                      ref.read(pidTuningParamsProvider.notifier)
                          .setPositionBandwidth(v);
                      setFlyoutState(() {});
                    },
                  ),
                ],
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
                        velocityTimeConstantMs: _isVelocity ? t.velocityTimeConstantMs : null,
                        positionBandwidthHz: _isVelocity ? null : t.positionBandwidthHz,
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
    });
  }

  Widget _buildOvershootFlyout() {
    return StatefulBuilder(builder: (context, setFlyoutState) {
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
                  _isVelocity ? 'Velocity Time Constant (\u03c4)' : 'Damping Ratio (\u03b6)',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  _isVelocity
                      ? 'Increase \u03c4 to slow the response and reduce overshoot'
                      : '\u03b6 > 1 = overdamped (no overshoot), \u03b6 < 1 = underdamped',
                  style: const TextStyle(fontSize: 11),
                ),
                const SizedBox(height: 12),
                if (_isVelocity) ...[
                  _TuningSlider(
                    label: '\u03c4',
                    unit: 'ms',
                    value: currentTuning.velocityTimeConstantMs,
                    min: 20, max: 500,
                    onChanged: (v) {
                      ref.read(pidTuningParamsProvider.notifier)
                          .setVelocityTimeConstant(v);
                      setFlyoutState(() {});
                    },
                  ),
                ] else ...[
                  _TuningSlider(
                    label: '\u03b6',
                    unit: '',
                    value: currentTuning.dampingRatio,
                    min: 0.3, max: 2.0,
                    divisions: 17,
                    onChanged: (v) {
                      ref.read(pidTuningParamsProvider.notifier)
                          .setDampingRatio(v);
                      setFlyoutState(() {});
                    },
                  ),
                ],
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
                        velocityTimeConstantMs: _isVelocity ? t.velocityTimeConstantMs : null,
                        dampingRatio: _isVelocity ? null : t.dampingRatio,
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
    });
  }

  Widget _buildSsErrorFlyout() {
    return StatefulBuilder(builder: (context, setFlyoutState) {
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
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  _isVelocity
                      ? 'Increase \u03c4 if tracking lags; also check FF accuracy'
                      : 'Reduce BW or increase allowed CL error to improve tracking',
                  style: const TextStyle(fontSize: 11),
                ),
                const SizedBox(height: 12),
                if (_isVelocity) ...[
                  _TuningSlider(
                    label: '\u03c4',
                    unit: 'ms',
                    value: currentTuning.velocityTimeConstantMs,
                    min: 20, max: 500,
                    onChanged: (v) {
                      ref.read(pidTuningParamsProvider.notifier)
                          .setVelocityTimeConstant(v);
                      setFlyoutState(() {});
                    },
                  ),
                ] else ...[
                  _TuningSlider(
                    label: 'BW',
                    unit: 'Hz',
                    value: currentTuning.positionBandwidthHz,
                    min: 1, max: 20,
                    onChanged: (v) {
                      ref.read(pidTuningParamsProvider.notifier)
                          .setPositionBandwidth(v);
                      setFlyoutState(() {});
                    },
                  ),
                ],
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
                        velocityTimeConstantMs: _isVelocity ? t.velocityTimeConstantMs : null,
                        positionBandwidthHz: _isVelocity ? null : t.positionBandwidthHz,
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
    });
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
        : value.toStringAsFixed(2);
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
          divisions: divisions ?? ((max - min) / (unit == 'ms' ? 10 : 0.5)).round().clamp(10, 100),
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

    final PidResult preview;
    if (isVelocity) {
      preview = ffLoaded != null
          ? PidAutoTuner.tuneRobustVelocity(
              ffUnloaded: ff, ffLoaded: ffLoaded,
              mechanismType: config.type,
              desiredTimeConstantMs: tuning.velocityTimeConstantMs)
          : PidAutoTuner.tuneVelocity(
              ff: ff, mechanismType: config.type,
              desiredTimeConstantMs: tuning.velocityTimeConstantMs);
    } else {
      preview = ffLoaded != null
          ? PidAutoTuner.tuneRobustPosition(
              ffUnloaded: ff, ffLoaded: ffLoaded,
              mechanismType: config.type,
              desiredBandwidthHz: tuning.positionBandwidthHz,
              dampingRatio: tuning.dampingRatio)
          : PidAutoTuner.tunePosition(
              ff: ff, mechanismType: config.type,
              desiredBandwidthHz: tuning.positionBandwidthHz,
              dampingRatio: tuning.dampingRatio);
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: FluentTheme.of(context).micaBackgroundColor.withValues(alpha: 0.5),
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

    final allSpots = <FlSpot>[
      ...measuredSpots,
      ...setpointSpots,
    ];
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
                Container(width: 12, height: 2, color: Colors.successPrimaryColor),
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
                          axisNameWidget: const Text('Time (s)',
                              style: TextStyle(fontSize: 10)),
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
