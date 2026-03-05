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
import '../../simulation/simulated_device.dart';
import '../../state/app_state.dart';
import '../../sysid/validation_runner.dart';
import '../../can/spark_protocol.dart';
import '../widgets/arm_visual.dart';
import '../widgets/elevator_visual.dart';
import '../widgets/jog_panel.dart';

class ValidationScreen extends ConsumerStatefulWidget {
  const ValidationScreen({super.key});

  @override
  ConsumerState<ValidationScreen> createState() => _ValidationScreenState();
}

class _ValidationScreenState extends ConsumerState<ValidationScreen> {
  ValidationRunner? _runner;
  bool _isRunning = false;
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

  // Setpoint editing controllers
  late TextEditingController _velSpCtrl;
  late TextEditingController _posSpCtrl;

  // MAXMotion configuration controllers
  late TextEditingController _mmCruiseCtrl;
  late TextEditingController _mmAccelCtrl;
  late TextEditingController _mmJerkCtrl;
  late TextEditingController _mmErrorCtrl;
  int _mmPositionMode = kMAXMotionPositionModeTrapezoidal;
  bool _mmExpanded = false;

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
    super.dispose();
  }

  void _pollPosition() {
    if (_isRunning) return;
    final device = ref.read(deviceManagerProvider).leader;
    if (device == null || !device.isConnected) return;
    final status2 = device.connection.lastStatus2;
    if (status2 == null) return;
    final config = ref.read(mechanismConfigProvider);
    final userPos = status2.positionRotations * config.positionConversionFactor;
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
    final canRunVelocity = device != null &&
        device.isConnected &&
        !_isRunning &&
        hasGains;
    final canRunPosition = device != null &&
        device.isConnected &&
        !_isRunning &&
        hasPositionGains;
    final canRunMAXMotion = canRunPosition;

    // Unit labels
    final velUnit = config.velocityUnit;
    final posUnit = config.positionUnit;

    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Validation'),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            CommandBarButton(
              icon: const Icon(FluentIcons.stop,
                  color: Colors.warningPrimaryColor),
              label: const Text('EMERGENCY STOP'),
              onPressed: _isRunning ? _emergencyStop : null,
            ),
          ],
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status bar
            InfoBar(
              title: Text(_isRunning ? 'Running validation' : 'Status'),
              content: Text(_statusMessage),
              severity: _isRunning
                  ? InfoBarSeverity.warning
                  : _error != null
                      ? InfoBarSeverity.error
                      : InfoBarSeverity.info,
            ),
            const SizedBox(height: 12),

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

                if (!hasGains) ...[
                  const SizedBox(width: 16),
                  const InfoBar(
                    title: Text('No gains'),
                    content: Text(
                      'Compute and write gains from the Results page first.',
                    ),
                    severity: InfoBarSeverity.info,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),

            // MAXMotion configuration panel
            Expander(
              header: Row(
                children: [
                  const Icon(FluentIcons.rocket, size: 14),
                  const SizedBox(width: 8),
                  const Text('MAXMotion Profile',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 12),
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
                ],
              ),
              initiallyExpanded: _mmExpanded,
              onStateChanged: (open) {
                setState(() => _mmExpanded = open);
              },
              content: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 140,
                      child: InfoLabel(
                        label: 'Cruise vel ($velUnit)',
                        child: TextBox(
                          controller: _mmCruiseCtrl,
                          enabled: !_isRunning,
                          placeholder: velUnit,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 140,
                      child: InfoLabel(
                        label: 'Max accel ($velUnit/s)',
                        child: TextBox(
                          controller: _mmAccelCtrl,
                          enabled: !_isRunning,
                          placeholder: '$velUnit/s',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 140,
                      child: InfoLabel(
                        label: 'Max jerk ($velUnit/s\u00b2)',
                        child: TextBox(
                          controller: _mmJerkCtrl,
                          enabled: !_isRunning,
                          placeholder: '0 = trapezoidal',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 120,
                      child: InfoLabel(
                        label: 'Allowed error ($posUnit)',
                        child: TextBox(
                          controller: _mmErrorCtrl,
                          enabled: !_isRunning,
                          placeholder: posUnit,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 140,
                      child: InfoLabel(
                        label: 'Profile mode',
                        child: ComboBox<int>(
                          value: _mmPositionMode,
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
                          onChanged: _isRunning
                              ? null
                              : (v) {
                                  if (v != null) {
                                    setState(
                                        () => _mmPositionMode = v);
                                  }
                                },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Live charts + mechanism visual
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
                  if (config.type == MechanismType.flywheel &&
                      device != null &&
                      device.isConnected) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 260,
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

            // Metrics strip
            if (_result != null) ...[
              const SizedBox(height: 8),
              _MetricsStrip(result: _result!),
              const SizedBox(height: 16),
              _ComparisonPanel(result: _result!),
            ],
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Test execution
  // -----------------------------------------------------------------------

  ValidationMode? _lastMode;

  Future<void> _runTest(
    ValidationMode mode,
    MechanismConfig config,
    SparkDevice device, {
    FeedforwardGains? ff,
    PidResult? velPid,
    PidResult? posPid,
  }) async {
    final velSp = double.tryParse(_velSpCtrl.text);
    final posSp = double.tryParse(_posSpCtrl.text);

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
      _statusMessage = mode == ValidationMode.velocity
          ? 'Running velocity step test — setpoint: '
              '${velSp?.toStringAsFixed(1)} ${config.velocityUnit} ...'
          : mode == ValidationMode.maxMotionPosition
              ? 'Running MAXMotion position test — target: '
                  '${posSp?.toStringAsFixed(2)} ${config.positionUnit} ...'
              : 'Running position step test — setpoint: '
                  '${posSp?.toStringAsFixed(2)} ${config.positionUnit} ...';
    });

    _runner = ValidationRunner(
      device: device,
      mechanismConfig: config,
      feedforwardGains: ff,
      velocityPidGains: velPid,
      positionPidGains: posPid,
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
        setState(() {
          _result = result;
          _error = result.error;
          _isRunning = false;
          _runner = null;
          _statusMessage = result.completed
              ? 'Validation ${mode.name} test completed — '
                  '${result.data.length} samples.'
              : 'Test stopped: ${result.error ?? "aborted"}';
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
      final isPositionMode = _lastMode == ValidationMode.position ||
          _lastMode == ValidationMode.maxMotionPosition;
      _currentPosition =
          isPositionMode ? p.position : _currentPosition;
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
// Metrics strip — compact row of key performance indicators
// ---------------------------------------------------------------------------

class _MetricsStrip extends StatelessWidget {
  final ValidationResult result;

  const _MetricsStrip({required this.result});

  @override
  Widget build(BuildContext context) {
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
          _metric('Samples', '${result.data.length}'),
          _metric('Duration',
              '${result.durationSeconds.toStringAsFixed(1)}s'),
          if (result.riseTime != null)
            _metric('Rise Time',
                '${(result.riseTime! * 1000).toStringAsFixed(0)} ms'),
          if (result.overshootPercent != null)
            _metric(
              'Overshoot',
              '${result.overshootPercent!.toStringAsFixed(1)}%',
              warn: result.overshootPercent! > 20,
            ),
          if (result.steadyStateError != null)
            _metric('SS Error',
                result.steadyStateError!.toStringAsFixed(3)),
        ],
      ),
    );
  }

  Widget _metric(String label, String value, {bool warn = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 10)),
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
    );
  }
}

// ---------------------------------------------------------------------------
// Before / After comparison panel
// ---------------------------------------------------------------------------

class _ComparisonPanel extends StatelessWidget {
  final ValidationResult result;

  const _ComparisonPanel({required this.result});

  @override
  Widget build(BuildContext context) {
    final rt = result.riseTime;
    final os = result.overshootPercent;
    final sse = result.steadyStateError;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Before / After: Feedforward Only vs FF + PID',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _ComparisonCard(
                title: 'Feedforward Only (estimated)',
                icon: FluentIcons.settings,
                color: const Color(0xFF607D8B),
                metrics: [
                  _ComparisonMetric(
                    label: 'Steady-State Error',
                    value: 'May be non-zero',
                    note: 'FF alone cannot reject disturbances',
                    isWarning: true,
                  ),
                  const _ComparisonMetric(
                    label: 'Overshoot',
                    value: '≈ 0%',
                    note: 'No integral or derivative action',
                  ),
                  const _ComparisonMetric(
                    label: 'Rise Time',
                    value: 'Slower',
                    note: 'Limited by kV and available voltage',
                  ),
                  const _ComparisonMetric(
                    label: 'Disturbance Rejection',
                    value: 'None',
                    isWarning: true,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ComparisonCard(
                title: 'FF + PID (measured)',
                icon: FluentIcons.check_mark,
                color: Colors.successPrimaryColor,
                metrics: [
                  _ComparisonMetric(
                    label: 'Steady-State Error',
                    value: sse != null ? sse.toStringAsFixed(4) : 'N/A',
                    isWarning: sse != null && sse.abs() > 0.1,
                  ),
                  _ComparisonMetric(
                    label: 'Overshoot',
                    value: os != null ? '${os.toStringAsFixed(1)}%' : 'N/A',
                    isWarning: os != null && os > 20,
                    note: os != null && os > 20 ? 'Consider reducing kP' : null,
                  ),
                  _ComparisonMetric(
                    label: 'Rise Time',
                    value: rt != null
                        ? '${(rt * 1000).toStringAsFixed(0)} ms'
                        : 'N/A',
                  ),
                  const _ComparisonMetric(
                    label: 'Disturbance Rejection',
                    value: 'Active via kP/kI/kD',
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ComparisonMetric {
  final String label;
  final String value;
  final String? note;
  final bool isWarning;

  const _ComparisonMetric({
    required this.label,
    required this.value,
    this.note,
    this.isWarning = false,
  });
}

class _ComparisonCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;
  final List<_ComparisonMetric> metrics;

  const _ComparisonCard({
    required this.title,
    required this.icon,
    required this.color,
    required this.metrics,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: color,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...metrics.map((m) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 130,
                      child: Text(
                        m.label,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.value,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'Consolas',
                              color: m.isWarning
                                  ? Colors.warningPrimaryColor
                                  : null,
                            ),
                          ),
                          if (m.note != null)
                            Text(
                              m.note!,
                              style: const TextStyle(fontSize: 10),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              )),
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
                      minX: 0,
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
