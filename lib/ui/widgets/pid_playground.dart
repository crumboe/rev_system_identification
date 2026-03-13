/// "What If" PID Gain Playground — simulate a step response with adjustable
/// feedforward (kS, kV, kA, kG) and PID (kP, kI, kD) gains. See rise time,
/// overshoot, and steady-state error in real-time.
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../data/test_data.dart';
import '../../mechanisms/mechanism.dart';
import 'simulated_validation_dialog.dart';

class PidPlayground extends StatefulWidget {
  final FeedforwardGains ff;
  final PidResult? initialPid;

  /// Position-loop PID gains (used when [isPositionMode] is true).
  final PidResult? initialPosPid;

  /// Called whenever the user adjusts velocity PID gains.
  final ValueChanged<PidResult>? onPidChanged;

  /// Called whenever the user adjusts position PID gains.
  final ValueChanged<PidResult>? onPosPidChanged;

  /// When true, show position step response instead of velocity.
  final bool isPositionMode;

  /// Called when the user toggles the mode selector.
  final ValueChanged<bool>? onModeChanged;

  /// Mechanism configuration used to open the Simulate PID dialog.
  ///
  /// When non-null the "Simulate PID" button becomes available, allowing
  /// the user to run a closed-loop validation test on a simulated mechanism
  /// grounded in the identified feedforward gains.
  final MechanismConfig? mechanismConfig;

  const PidPlayground({
    super.key,
    required this.ff,
    this.initialPid,
    this.initialPosPid,
    this.onPidChanged,
    this.onPosPidChanged,
    this.isPositionMode = false,
    this.onModeChanged,
    this.mechanismConfig,
  });

  @override
  State<PidPlayground> createState() => _PidPlaygroundState();
}

class _PidPlaygroundState extends State<PidPlayground>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // --- Velocity PID gains (stored when switching modes) ---
  late double _velKP;
  late double _velKI;
  late double _velKD;

  // --- Position PID gains (stored when switching modes) ---
  late double _posKP;
  late double _posKI;
  late double _posKD;

  // Active PID gains (pointers into vel or pos depending on mode)
  double get _kP => widget.isPositionMode ? _posKP : _velKP;
  set _kP(double v) {
    if (widget.isPositionMode) { _posKP = v; } else { _velKP = v; }
  }
  double get _kI => widget.isPositionMode ? _posKI : _velKI;
  set _kI(double v) {
    if (widget.isPositionMode) { _posKI = v; } else { _velKI = v; }
  }
  double get _kD => widget.isPositionMode ? _posKD : _velKD;
  set _kD(double v) {
    if (widget.isPositionMode) { _posKD = v; } else { _velKD = v; }
  }

  // Feedforward gains (controller) — applied to the setpoint, like SPARK MAX.
  late double _kS;
  late double _kV;
  late double _kA;
  late double _kG;

  // Slider upper bounds — 5× the identified value or a sensible minimum.
  late double _kPMax;
  late double _kIMax;
  late double _kDMax;
  late double _kSMax;
  late double _kVMax;
  late double _kAMax;
  late double _kGMax;

  List<FlSpot> _actualSpots = const [];
  List<FlSpot> _setpointSpots = const [];

  double? _riseTime;
  double _overshoot = 0;
  double _steadyStateError = 0;

  bool _prevIsPositionMode = false;

  @override
  void initState() {
    super.initState();
    _velKP = widget.initialPid?.kP ?? 1.0;
    _velKI = widget.initialPid?.kI ?? 0.0;
    _velKD = widget.initialPid?.kD ?? 0.0;

    _posKP = widget.initialPosPid?.kP ?? 1.0;
    _posKI = widget.initialPosPid?.kI ?? 0.0;
    _posKD = widget.initialPosPid?.kD ?? 0.0;

    _kS = widget.ff.kS;
    _kV = widget.ff.kV;
    _kA = widget.ff.kA;
    _kG = widget.ff.kG;

    _prevIsPositionMode = widget.isPositionMode;
    _updateSliderBounds();
    _runSimulation();
  }

  @override
  void didUpdateWidget(covariant PidPlayground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPositionMode != _prevIsPositionMode) {
      _prevIsPositionMode = widget.isPositionMode;
      _updateSliderBounds();
      _runSimulation();
    }
  }

  void _updateSliderBounds() {
    _kPMax = _kP > 0 ? math.max(_kP * 5, 0.01) : 5.0;
    _kIMax = _kI > 0 ? math.max(_kI * 5, 0.01) : 1.0;
    _kDMax = _kD > 0 ? math.max(_kD * 5, 0.01) : 1.0;
    _kSMax = _kS > 0 ? math.max(_kS * 3, 0.5) : 2.0;
    _kVMax = _kV > 0 ? math.max(_kV * 3, 0.5) : 5.0;
    _kAMax = _kA > 0 ? math.max(_kA * 3, 0.5) : 2.0;
    _kGMax = _kG.abs() > 0 ? math.max(_kG.abs() * 3, 0.5) : 2.0;
  }

  void _runSimulation() {
    if (widget.isPositionMode) {
      _runPositionSimulation();
    } else {
      _runVelocitySimulation();
    }
  }

  void _runVelocitySimulation() {
    final plant = widget.ff;
    if (plant.kA <= 0) {
      setState(() {
        _actualSpots = const [];
        _setpointSpots = const [];
      });
      return;
    }

    const dt = 0.001;
    const steps = 2000; // 2 s
    const setpoint = 1.0;
    const nominalVoltage = 12.0;

    double integral = 0;
    double prevError = setpoint;
    double velocity = 0;

    final actual = <FlSpot>[];
    final reference = <FlSpot>[];

    actual.add(const FlSpot(0, 0));
    reference.add(const FlSpot(0, setpoint));

    double maxVel = 0;
    double? riseTime10;
    double? riseTime90;

    for (int i = 1; i <= steps; i++) {
      final t = i * dt;
      final error = setpoint - velocity;
      integral += error * dt;
      final derivative = (error - prevError) / dt;
      final pidOutput = _kP * error + _kI * integral + _kD * derivative;

      final setpointSign = setpoint >= 0 ? 1.0 : -1.0;
      final ffOutput = _kS * setpointSign + _kV * setpoint + _kG;
      final voltage =
          (pidOutput + ffOutput).clamp(-nominalVoltage, nominalVoltage);

      final velSign = velocity >= 0 ? 1.0 : -1.0;
      final acceleration =
          (voltage - plant.kS * velSign - plant.kV * velocity - plant.kG) /
              plant.kA;
      velocity += acceleration * dt;
      prevError = error;

      if (i % 10 == 0) {
        actual.add(FlSpot(t, velocity));
        reference.add(FlSpot(t, setpoint));
      }

      if (velocity > maxVel) maxVel = velocity;
      if (riseTime10 == null && velocity >= 0.1 * setpoint) riseTime10 = t;
      if (riseTime90 == null && velocity >= 0.9 * setpoint) riseTime90 = t;
    }

    final riseTime = (riseTime10 != null && riseTime90 != null)
        ? riseTime90! - riseTime10!
        : null;

    setState(() {
      _actualSpots = actual;
      _setpointSpots = reference;
      _riseTime = riseTime;
      _overshoot =
          maxVel > setpoint ? (maxVel - setpoint) / setpoint * 100.0 : 0.0;
      _steadyStateError = (setpoint - velocity).abs();
    });

    widget.onPidChanged?.call(PidResult(kP: _velKP, kI: _velKI, kD: _velKD));
  }

  void _runPositionSimulation() {
    final plant = widget.ff;
    if (plant.kA <= 0) {
      setState(() {
        _actualSpots = const [];
        _setpointSpots = const [];
      });
      return;
    }

    const dt = 0.001;
    const steps = 4000; // 4 s (position response is slower)
    const setpoint = 1.0;
    const nominalVoltage = 12.0;

    double integral = 0;
    double prevError = setpoint;
    double velocity = 0;
    double position = 0;

    final actual = <FlSpot>[];
    final reference = <FlSpot>[];

    actual.add(const FlSpot(0, 0));
    reference.add(const FlSpot(0, setpoint));

    double maxPos = 0;
    double? riseTime10;
    double? riseTime90;

    for (int i = 1; i <= steps; i++) {
      final t = i * dt;
      final error = setpoint - position;
      integral += error * dt;
      // Position PID D-term uses negative measured velocity (like SPARK).
      final derivative = _firstPositionTick ? 0.0 : -velocity;
      _firstPositionTick = false;
      final pidOutput = _kP * error + _kI * integral + _kD * derivative;

      // Position FF: kS·sign(error) + kG (no kV in position mode per REV).
      final ffOutput = _kS * (error > 0 ? 1.0 : (error < 0 ? -1.0 : 0.0))
          + _kG;
      final voltage =
          (pidOutput + ffOutput).clamp(-nominalVoltage, nominalVoltage);

      // Plant dynamics (velocity domain).
      final velSign = velocity >= 0 ? 1.0 : -1.0;
      final acceleration =
          (voltage - plant.kS * velSign - plant.kV * velocity - plant.kG) /
              plant.kA;
      velocity += acceleration * dt;
      position += velocity * dt;
      prevError = error;

      if (i % 10 == 0) {
        actual.add(FlSpot(t, position));
        reference.add(FlSpot(t, setpoint));
      }

      if (position > maxPos) maxPos = position;
      if (riseTime10 == null && position >= 0.1 * setpoint) riseTime10 = t;
      if (riseTime90 == null && position >= 0.9 * setpoint) riseTime90 = t;
    }

    final riseTime = (riseTime10 != null && riseTime90 != null)
        ? riseTime90! - riseTime10!
        : null;

    setState(() {
      _actualSpots = actual;
      _setpointSpots = reference;
      _riseTime = riseTime;
      _overshoot =
          maxPos > setpoint ? (maxPos - setpoint) / setpoint * 100.0 : 0.0;
      _steadyStateError = (setpoint - position).abs();
    });

    widget.onPosPidChanged?.call(PidResult(kP: _posKP, kI: _posKI, kD: _posKD));
  }

  bool _firstPositionTick = true;

  void _resetToAutoTuned() {
    setState(() {
      if (widget.isPositionMode) {
        _posKP = widget.initialPosPid?.kP ?? 1.0;
        _posKI = widget.initialPosPid?.kI ?? 0.0;
        _posKD = widget.initialPosPid?.kD ?? 0.0;
      } else {
        _velKP = widget.initialPid?.kP ?? 1.0;
        _velKI = widget.initialPid?.kI ?? 0.0;
        _velKD = widget.initialPid?.kD ?? 0.0;
      }
      _kS = widget.ff.kS;
      _kV = widget.ff.kV;
      _kA = widget.ff.kA;
      _kG = widget.ff.kG;
      // Update slider bounds atomically with the value changes so that
      // value <= max always holds after the rebuild.
      _updateSliderBounds();
    });
    _runSimulation();
  }

  void _openSimulateDialog(BuildContext context) {
    final config = widget.mechanismConfig;
    if (config == null) return;

    // Build controller gains from current slider values.
    final controllerGains = FeedforwardGains(
      kS: _kS,
      kV: _kV,
      kA: _kA,
      kG: _kG,
    );

    final pidGains = widget.isPositionMode
        ? PidResult(kP: _posKP, kI: _posKI, kD: _posKD)
        : PidResult(kP: _velKP, kI: _velKI, kD: _velKD);

    showSimulatedValidationDialog(
      context,
      identifiedGains: widget.ff,
      controllerGains: controllerGains,
      pidGains: pidGains,
      isPositionMode: widget.isPositionMode,
      mechanismConfig: config,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = FluentTheme.of(context);
    final subtleColor =
        theme.typography.body?.color?.withValues(alpha: 0.6);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Mode selector ──────────────────────────────────────────────
          Row(
            children: [
              Text(
                widget.isPositionMode ? 'Position Loop' : 'Velocity Loop',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              ComboBox<bool>(
                value: widget.isPositionMode,
                items: const [
                  ComboBoxItem<bool>(
                    value: false,
                    child: Text('Velocity Loop'),
                  ),
                  ComboBoxItem<bool>(
                    value: true,
                    child: Text('Position Loop'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) widget.onModeChanged?.call(v);
                },
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ── Feedforward sliders ────────────────────────────────────────
          Text(
            'Feedforward (applied to setpoint, like SPARK MAX)',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: subtleColor,
            ),
          ),
          const SizedBox(height: 6),
          _SliderRow(
            label: 'kS',
            value: _kS,
            min: 0,
            max: _kSMax,
            onChanged: (v) {
              setState(() => _kS = v);
              _runSimulation();
            },
          ),
          const SizedBox(height: 8),
          _SliderRow(
            label: 'kV',
            value: _kV,
            min: 0,
            max: _kVMax,
            onChanged: (v) {
              setState(() => _kV = v);
              _runSimulation();
            },
          ),
          const SizedBox(height: 8),
          _SliderRow(
            label: 'kA',
            value: _kA,
            min: 0,
            max: _kAMax,
            onChanged: (v) {
              setState(() => _kA = v);
              _runSimulation();
            },
          ),
          const SizedBox(height: 8),
          _SliderRow(
            label: 'kG',
            value: _kG,
            min: 0,
            max: _kGMax,
            onChanged: (v) {
              setState(() => _kG = v);
              _runSimulation();
            },
          ),
          const SizedBox(height: 14),

          // ── PID sliders ────────────────────────────────────────────────
          Text(
            'PID (error correction)',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: subtleColor,
            ),
          ),
          const SizedBox(height: 6),
          _SliderRow(
            label: 'kP',
            value: _kP,
            min: 0,
            max: _kPMax,
            onChanged: (v) {
              setState(() => _kP = v);
              _runSimulation();
            },
          ),
          const SizedBox(height: 8),
          _SliderRow(
            label: 'kI',
            value: _kI,
            min: 0,
            max: _kIMax,
            onChanged: (v) {
              setState(() => _kI = v);
              _runSimulation();
            },
          ),
          const SizedBox(height: 8),
          _SliderRow(
            label: 'kD',
            value: _kD,
            min: 0,
            max: _kDMax,
            onChanged: (v) {
              setState(() => _kD = v);
              _runSimulation();
            },
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              Button(
                onPressed: _resetToAutoTuned,
                child: const Text('Reset to Identified Values'),
              ),
              if (widget.mechanismConfig != null) ...[
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () => _openSimulateDialog(context),
                  child: const Text('Simulate PID'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),

          // ── Chart legend ───────────────────────────────────────────────
          Row(
            children: [
              Container(
                width: 16,
                height: 2,
                color: Colors.successPrimaryColor,
              ),
              const SizedBox(width: 4),
              Text(
                'Setpoint',
                style: TextStyle(fontSize: 10, color: subtleColor),
              ),
              const SizedBox(width: 14),
              Container(width: 16, height: 2, color: theme.accentColor),
              const SizedBox(width: 4),
              Text(
                'Response',
                style: TextStyle(fontSize: 10, color: subtleColor),
              ),
            ],
          ),
          const SizedBox(height: 4),

          // ── Step response chart ────────────────────────────────────────
          SizedBox(
            height: 220,
            child: _actualSpots.isEmpty
                ? Center(
                    child: Text(
                      'kA must be > 0 to simulate',
                      style: TextStyle(color: subtleColor),
                    ),
                  )
                : LineChart(
                    LineChartData(
                      clipData: FlClipData.all(),
                      lineBarsData: [
                        // Setpoint reference (dashed green)
                        LineChartBarData(
                          spots: _setpointSpots,
                          isCurved: false,
                          color: Colors.successPrimaryColor
                              .withValues(alpha: 0.7),
                          barWidth: 1.5,
                          dotData: const FlDotData(show: false),
                          dashArray: [6, 3],
                        ),
                        // Simulated velocity response
                        LineChartBarData(
                          spots: _actualSpots,
                          isCurved: false,
                          color: theme.accentColor,
                          barWidth: 2,
                          dotData: const FlDotData(show: false),
                        ),
                      ],
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
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
                          axisNameWidget: Text(
                              widget.isPositionMode
                                  ? 'Position (norm.)'
                                  : 'Velocity (norm.)',
                              style: const TextStyle(fontSize: 10)),
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 42,
                            getTitlesWidget: (v, _) => Text(
                              v.toStringAsFixed(1),
                              style: const TextStyle(fontSize: 9),
                            ),
                          ),
                        ),
                      ),
                      gridData: const FlGridData(
                          show: true, drawVerticalLine: false),
                      borderData: FlBorderData(show: false),
                    ),
                  ),
          ),
          const SizedBox(height: 14),

          // ── Metrics row ────────────────────────────────────────────────
          Row(
            children: [
              _MetricTile(
                label: 'Rise Time (10%–90%)',
                value: _riseTime != null
                    ? '${(_riseTime! * 1000).toStringAsFixed(0)} ms'
                    : '—',
              ),
              const SizedBox(width: 28),
              _MetricTile(
                label: 'Overshoot',
                value: '${_overshoot.toStringAsFixed(1)}%',
                alert: _overshoot > 20,
              ),
              const SizedBox(width: 28),
              _MetricTile(
                label: 'SS Error',
                value: _steadyStateError.toStringAsFixed(4),
                alert: _steadyStateError > 0.05,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Helper widgets ──────────────────────────────────────────────────────────

class _SliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 30,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 84,
          child: Text(
            value.toStringAsFixed(6),
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 11),
          ),
        ),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final bool alert;

  const _MetricTile({
    required this.label,
    required this.value,
    this.alert = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11)),
        Text(
          value,
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: alert
                ? Colors.warningPrimaryColor
                : theme.typography.body?.color,
          ),
        ),
      ],
    );
  }
}
