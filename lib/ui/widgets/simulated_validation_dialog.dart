/// Dialog for running a closed-loop PID validation test entirely in
/// simulation — no real hardware required.
///
/// The dialog creates a standalone [SparkDevice] (via
/// [createStandaloneSimulatedDevice]) whose plant physics are grounded in the
/// [identifiedGains] from the most recent system-identification run.  The
/// controller tuning comes from the current [PidPlayground] slider values
/// ([controllerGains] and [pidGains]), allowing the user to see how their
/// chosen PID+FF gains perform on a realistic simulated model before writing
/// them to hardware.
///
/// Only velocity or position tests are supported (no MAXMotion), matching
/// the playground mode.
library;

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../can/spark_protocol.dart';
import '../../data/test_data.dart';
import '../../devices/device_manager.dart';
import '../../mechanisms/mechanism.dart';
import '../../simulation/standalone_sim.dart';
import '../../simulation/simulated_device.dart';
import '../../sysid/validation_runner.dart';
import 'arm_visual.dart';
import 'elevator_visual.dart';
import 'jog_panel.dart';

/// Shows [SimulatedValidationDialog] as a modal overlay.
Future<void> showSimulatedValidationDialog(
  BuildContext context, {
  required FeedforwardGains identifiedGains,
  required FeedforwardGains controllerGains,
  required PidResult pidGains,
  required bool isPositionMode,
  required MechanismConfig mechanismConfig,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => SimulatedValidationDialog(
      identifiedGains: identifiedGains,
      controllerGains: controllerGains,
      pidGains: pidGains,
      isPositionMode: isPositionMode,
      mechanismConfig: mechanismConfig,
    ),
  );
}

/// A self-contained dialog that runs a simulated closed-loop step response.
///
/// **Plant** is the simulated mechanism (driven by [identifiedGains]).
/// **Controller** uses [controllerGains] + [pidGains] (from playground
/// sliders) so the user sees the effect of their chosen tuning.
class SimulatedValidationDialog extends StatefulWidget {
  /// Feedforward gains used to build the simulated plant physics.
  final FeedforwardGains identifiedGains;

  /// Feedforward gains to write to the simulated controller (from sliders).
  final FeedforwardGains controllerGains;

  /// PID gains to write to the simulated controller (from sliders).
  final PidResult pidGains;

  /// When true the dialog runs a position step; otherwise a velocity step.
  final bool isPositionMode;

  /// Mechanism configuration (type, conversion factors, soft limits).
  final MechanismConfig mechanismConfig;

  const SimulatedValidationDialog({
    super.key,
    required this.identifiedGains,
    required this.controllerGains,
    required this.pidGains,
    required this.isPositionMode,
    required this.mechanismConfig,
  });

  @override
  State<SimulatedValidationDialog> createState() =>
      _SimulatedValidationDialogState();
}

class _SimulatedValidationDialogState
    extends State<SimulatedValidationDialog> {
  SparkDevice? _device;
  ValidationRunner? _runner;

  bool _isRunning = false;
  bool _runTriggered = false; // debounce: ignore rapid re-taps while running
  String _statusMessage = 'Ready — press Run to start the simulation.';

  final List<DataPoint> _liveData = [];
  final List<double> _liveSetpoints = [];
  ValidationResult? _result;

  double _currentPosition = 0.0;
  Timer? _positionPollTimer;
  late TextEditingController _setpointCtrl;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    // Pre-populate the setpoint field with mechanism-appropriate defaults.
    final defaults = ValidationParams.forMechanism(
      widget.mechanismConfig.type,
      imperial: widget.mechanismConfig.useImperialUnits,
    );
    final defaultSetpoint = widget.isPositionMode
        ? defaults.positionSetpoint
        : defaults.velocitySetpoint;
    _setpointCtrl =
        TextEditingController(text: defaultSetpoint.toString());
    _initDevice();
  }

  Future<void> _initDevice() async {
    try {
      final device = await createStandaloneSimulatedDevice(
        type: widget.mechanismConfig.type,
        identifiedGains: widget.identifiedGains,
        config: widget.mechanismConfig,
      );
      if (!mounted) {
        device.dispose();
        return;
      }
      setState(() => _device = device);

      // Write the controller tuning (from playground sliders) into params.
      await _writeControllerGains(device);

      // Poll position for the mechanism visual.
      _positionPollTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _pollPosition(),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = 'Init error: $e');
      }
    }
  }

  /// Write [widget.pidGains] and [widget.controllerGains] to the simulated
  /// parameter store so the controller uses the playground-slider values.
  Future<void> _writeControllerGains(SparkDevice device) async {
    final pid = widget.pidGains;
    final ff = widget.controllerGains;
    final config = widget.mechanismConfig;

    // PID
    device.parameters.setParameter(kParamSlot0P, pid.kP);
    device.parameters.setParameter(kParamSlot0I, pid.kI);
    device.parameters.setParameter(kParamSlot0D, pid.kD);

    // Feedforward
    device.parameters.setParameter(kParamSlot0FfKs, ff.kS);
    device.parameters.setParameter(kParamSlot0FfKv, ff.kV);
    device.parameters.setParameter(kParamSlot0FfKa, ff.kA);

    if (config.type == MechanismType.elevator) {
      device.parameters.setParameter(kParamSlot0FfKg, ff.kG);
    } else if (config.type == MechanismType.arm) {
      device.parameters.setParameter(kParamSlot0FfKcos, ff.kG);
      // kCosRatio converts position in degrees to a fraction of a full
      // rotation for the cos() computation: cos(pos * kCosRatio * 2π).
      device.parameters.setParameter(
          kParamSlot0FfKcosRatio, 1.0 / 360.0);
    }

    // Conversion factors (already set in factory, but re-apply for safety).
    device.parameters.setParameter(
        kParamPositionConvFactor, config.positionConversionFactor);
    device.parameters.setParameter(
        kParamVelocityConvFactor, config.velocityConversionFactor);
  }

  void _pollPosition() {
    if (_isRunning || _device == null) return;
    final raw =
        _device!.connection.lastStatus2?.positionRotations ?? 0.0;
    if ((raw - _currentPosition).abs() > 0.005) {
      setState(() => _currentPosition = raw);
    }
  }

  @override
  void dispose() {
    _positionPollTimer?.cancel();
    _runner?.abort();
    // Close the simulated connection to stop its internal timer.
    _device?.connection.close();
    _setpointCtrl.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Test execution
  // -------------------------------------------------------------------------

  Future<void> _runTest() async {
    final device = _device;
    if (device == null || _isRunning || _runTriggered) return;

    setState(() {
      _runTriggered = true;
      _isRunning = true;
      _liveData.clear();
      _liveSetpoints.clear();
      _result = null;
      _statusMessage = 'Running simulation…';
    });

    try {
      // Re-apply slider gains in case the user re-opened the dialog.
      await _writeControllerGains(device);

      // Build a ValidationRunner using stored controller gains (they have
      // already been written into the simulated parameter store above, so
      // no further overwrites are needed).
      final runner = ValidationRunner(
        device: device,
        mechanismConfig: widget.mechanismConfig,
        // The controller gains were already written directly into the
        // simulated parameter store; tell the runner to skip re-writing.
        useStoredControllerGains: true,
      );
      _runner = runner;

      final defaults = ValidationParams.forMechanism(
        widget.mechanismConfig.type,
        imperial: widget.mechanismConfig.useImperialUnits,
      );
      final userSetpoint =
          double.tryParse(_setpointCtrl.text.trim()) ??
              (widget.isPositionMode
                  ? defaults.positionSetpoint
                  : defaults.velocitySetpoint);
      final params = widget.isPositionMode
          ? defaults.copyWith(positionSetpoint: userSetpoint)
          : defaults.copyWith(velocitySetpoint: userSetpoint);

      final ValidationResult result;
      if (widget.isPositionMode) {
        result = await runner.runPositionTest(
          params: params,
          onProgress: _onProgress,
        );
      } else {
        result = await runner.runVelocityTest(
          params: params,
          onProgress: _onProgress,
        );
      }

      if (mounted) {
        setState(() {
          _result = result;
          _isRunning = false;
          _runTriggered = false;
          _runner = null;
          _statusMessage = result.completed
              ? 'Simulation complete — ${result.data.length} samples.'
              : 'Stopped: ${result.error ?? "aborted"}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isRunning = false;
          _runTriggered = false;
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
      _currentPosition = p.position;
    });
  }

  void _emergencyStop() {
    _runner?.emergencyStop();
    if (mounted) {
      setState(() {
        _isRunning = false;
        _runTriggered = false;
        _runner = null;
        _statusMessage = 'EMERGENCY STOP — simulation halted.';
      });
    }
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final config = widget.mechanismConfig;
    final modeLabel = widget.isPositionMode ? 'Position' : 'Velocity';
    final velUnit = config.velocityUnit;
    final posUnit = config.positionUnit;

    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 700),
      title: Row(
        children: [
          const Icon(FluentIcons.test_plan, size: 18),
          const SizedBox(width: 8),
          Text('Simulate PID — $modeLabel Mode (${config.type.displayName})'),
          const Spacer(),
          IconButton(
            icon: const Icon(FluentIcons.chrome_close, size: 12),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // --- Status bar + controls ---
          _buildControlsRow(context),
          const SizedBox(height: 8),

          // --- Status info bar ---
          InfoBar(
            title: Text(_isRunning ? 'Simulation running' : 'Status'),
            content: Text(_statusMessage),
            severity: _isRunning
                ? InfoBarSeverity.warning
                : (_result?.completed == true
                    ? InfoBarSeverity.success
                    : InfoBarSeverity.info),
          ),
          const SizedBox(height: 8),

          // --- Main content: charts + mechanism visual ---
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Charts (2×2 grid)
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: _LiveChart(
                                title: 'Velocity',
                                yLabel: velUnit,
                                data: _liveData,
                                setpoints: _liveSetpoints,
                                yExtractor: (dp) => dp.velocity,
                                showSetpoint: !widget.isPositionMode,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _LiveChart(
                                title: 'Voltage',
                                yLabel: 'V',
                                data: _liveData,
                                setpoints: const [],
                                yExtractor: (dp) => dp.voltage,
                                showSetpoint: false,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Expanded(
                        child: Row(
                          children: [
                            Expanded(
                              child: _LiveChart(
                                title: 'Position',
                                yLabel: posUnit,
                                data: _liveData,
                                setpoints: _liveSetpoints,
                                yExtractor: (dp) => dp.position,
                                showSetpoint: widget.isPositionMode,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: _LiveChart(
                                title: 'Current',
                                yLabel: 'A',
                                data: _liveData,
                                setpoints: const [],
                                yExtractor: (dp) => dp.current,
                                showSetpoint: false,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                // Mechanism visual area
                SizedBox(
                  width: 220,
                  child: _buildMechanismVisual(config),
                ),
              ],
            ),
          ),

          // --- Metrics strip ---
          if (_result != null) ...[
            const SizedBox(height: 6),
            _MetricsStrip(result: _result!),
          ],
        ],
      ),
      actions: const [],
    );
  }

  Widget _buildControlsRow(BuildContext context) {
    final config = widget.mechanismConfig;
    final setpointUnit =
        widget.isPositionMode ? config.positionUnit : config.velocityUnit;
    final canRun = _device != null && !_isRunning;
    return Row(
      children: [
        // Setpoint input
        SizedBox(
          width: 160,
          child: InfoLabel(
            label: 'Setpoint ($setpointUnit)',
            child: TextBox(
              controller: _setpointCtrl,
              enabled: !_isRunning,
              placeholder: setpointUnit,
            ),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: canRun ? _runTest : null,
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
              const Text('Run'),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Button(
          onPressed: _isRunning ? _emergencyStop : null,
          style: ButtonStyle(
            backgroundColor: WidgetStatePropertyAll(
                _isRunning ? Colors.warningPrimaryColor : null),
          ),
          child: const Text('Emergency Stop'),
        ),
        if (_device == null) ...[
          const SizedBox(width: 12),
          const SizedBox(
            width: 14,
            height: 14,
            child: ProgressRing(strokeWidth: 2),
          ),
          const SizedBox(width: 6),
          const Text('Initialising simulation…',
              style: TextStyle(fontSize: 12)),
        ],
      ],
    );
  }

  Widget _buildMechanismVisual(MechanismConfig config) {
    final device = _device;
    switch (config.type) {
      case MechanismType.arm:
        return Column(
          children: [
            Expanded(
              child: ArmVisual(
                currentAngleDeg: _currentPosition,
                forwardLimitDeg: config.forwardSoftLimit,
                reverseLimitDeg: config.reverseSoftLimit,
                isDraggable: device != null && !_isRunning,
                onAngleChanged:
                    device != null ? (deg) => _dragPosition(device, deg) : null,
              ),
            ),
            if (device != null) ...[
              const SizedBox(height: 4),
              SizedBox(
                height: 160,
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
        );

      case MechanismType.elevator:
        return Column(
          children: [
            Expanded(
              child: ElevatorVisual(
                currentPosition: _currentPosition,
                forwardLimit: config.forwardSoftLimit,
                reverseLimit: config.reverseSoftLimit,
                unitLabel: config.useImperialUnits ? 'in' : 'm',
                isDraggable: device != null && !_isRunning,
                onPositionChanged: device != null
                    ? (pos) => _dragPosition(device, pos)
                    : null,
              ),
            ),
            if (device != null) ...[
              const SizedBox(height: 4),
              SizedBox(
                height: 160,
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
        );

      case MechanismType.flywheel:
      case MechanismType.simple:
        if (device == null) return const SizedBox.shrink();
        return JogPanel(
          device: device,
          config: config,
          enabled: !_isRunning,
          onPositionChanged: (pos) =>
              setState(() => _currentPosition = pos),
        );
    }
  }

  void _dragPosition(SparkDevice device, double userUnits) {
    final conn = device.connection;
    if (conn is SimulatedSparkConnection) {
      final cf = widget.mechanismConfig.positionConversionFactor;
      final rotations = cf != 0 ? userUnits / cf : 0.0;
      conn.physics.setPositionRotations(rotations);
      setState(() => _currentPosition = userUnits);
    }
  }
}

// ---------------------------------------------------------------------------
// Live chart
// ---------------------------------------------------------------------------

class _LiveChart extends StatelessWidget {
  final String title;
  final String yLabel;
  final List<DataPoint> data;
  final List<double> setpoints;
  final double Function(DataPoint) yExtractor;
  final bool showSetpoint;

  const _LiveChart({
    required this.title,
    required this.yLabel,
    required this.data,
    required this.setpoints,
    required this.yExtractor,
    required this.showSetpoint,
  });

  @override
  Widget build(BuildContext context) {
    final measuredSpots =
        data.map((dp) => FlSpot(dp.timestamp, yExtractor(dp))).toList();

    final setpointSpots = <FlSpot>[];
    if (showSetpoint) {
      for (var i = 0; i < data.length && i < setpoints.length; i++) {
        setpointSpots.add(FlSpot(data[i].timestamp, setpoints[i]));
      }
    }

    final lineBars = <LineChartBarData>[
      if (setpointSpots.isNotEmpty)
        LineChartBarData(
          spots: setpointSpots,
          isCurved: false,
          color: Colors.successPrimaryColor,
          barWidth: 2,
          dotData: const FlDotData(show: false),
          dashArray: [6, 3],
        ),
      if (measuredSpots.isNotEmpty)
        LineChartBarData(
          spots: measuredSpots,
          isCurved: false,
          color: Colors.blue,
          barWidth: 1.5,
          dotData: const FlDotData(show: false),
        ),
    ];

    final allSpots = [...measuredSpots, ...setpointSpots];
    final minX = allSpots.isEmpty
        ? 0.0
        : allSpots.map((s) => s.x).reduce((a, b) => a < b ? a : b);
    var maxX = allSpots.isEmpty
        ? 1.0
        : allSpots.map((s) => s.x).reduce((a, b) => a > b ? a : b);
    if ((maxX - minX).abs() < 1e-6) maxX = minX + 1.0;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$title ($yLabel)',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600),
              ),
              if (showSetpoint) ...[
                const Spacer(),
                Container(
                    width: 10, height: 2,
                    color: Colors.successPrimaryColor),
                const SizedBox(width: 3),
                const Text('SP', style: TextStyle(fontSize: 9)),
                const SizedBox(width: 6),
                Container(width: 10, height: 2, color: Colors.blue),
                const SizedBox(width: 3),
                const Text('Meas', style: TextStyle(fontSize: 9)),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: lineBars.isEmpty
                ? const Center(
                    child: Text('No data',
                        style: TextStyle(fontSize: 11)))
                : LineChart(
                    LineChartData(
                      minX: minX,
                      maxX: maxX,
                      lineTouchData: const LineTouchData(enabled: false),
                      gridData: const FlGridData(show: true),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 40,
                            getTitlesWidget: (v, _) => Text(
                              v.toStringAsFixed(1),
                              style: const TextStyle(fontSize: 9),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 18,
                            getTitlesWidget: (v, _) => Text(
                              '${v.toStringAsFixed(1)}s',
                              style: const TextStyle(fontSize: 9),
                            ),
                          ),
                        ),
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                      ),
                      lineBarsData: lineBars,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Metrics strip
// ---------------------------------------------------------------------------

class _MetricsStrip extends StatelessWidget {
  final ValidationResult result;
  const _MetricsStrip({required this.result});

  @override
  Widget build(BuildContext context) {
    final modeLabel = switch (result.mode) {
      ValidationMode.velocity => 'Velocity',
      ValidationMode.position => 'Position',
      ValidationMode.maxMotionPosition => 'MAXMotion',
    };

    return Card(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Text(
            '$modeLabel — ${result.completed ? "Complete" : "Incomplete"}',
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 20),
          _metric('Samples', '${result.data.length}'),
          _metric(
              'Duration', '${result.durationSeconds.toStringAsFixed(1)}s'),
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
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 9)),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
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
