/// "What If" PID Gain Playground — simulate a step response with adjustable
/// kP, kI, kD and see rise time, overshoot, and steady-state error in
/// real-time.
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../data/test_data.dart';

class PidPlayground extends StatefulWidget {
  final FeedforwardGains ff;
  final PidResult? initialPid;

  const PidPlayground({super.key, required this.ff, this.initialPid});

  @override
  State<PidPlayground> createState() => _PidPlaygroundState();
}

class _PidPlaygroundState extends State<PidPlayground> {
  late double _kP;
  late double _kI;
  late double _kD;

  // Slider upper bounds — 5× the auto-tuned value or a sensible minimum.
  late double _kPMax;
  late double _kIMax;
  late double _kDMax;

  List<FlSpot> _actualSpots = const [];
  List<FlSpot> _setpointSpots = const [];

  double? _riseTime;
  double _overshoot = 0;
  double _steadyStateError = 0;

  @override
  void initState() {
    super.initState();
    _kP = widget.initialPid?.kP ?? 1.0;
    _kI = widget.initialPid?.kI ?? 0.0;
    _kD = widget.initialPid?.kD ?? 0.0;

    _kPMax = _kP > 0 ? math.max(_kP * 5, 0.01) : 5.0;
    _kIMax = _kI > 0 ? math.max(_kI * 5, 0.01) : 1.0;
    _kDMax = _kD > 0 ? math.max(_kD * 5, 0.01) : 1.0;

    _runSimulation();
  }

  void _runSimulation() {
    final ff = widget.ff;
    if (ff.kA <= 0) {
      setState(() {
        _actualSpots = const [];
        _setpointSpots = const [];
      });
      return;
    }

    const dt = 0.001; // 1 ms time step
    const steps = 2000; // 2 s total
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

      final velSign = velocity >= 0 ? 1.0 : -1.0;
      final ffOutput = ff.kS * velSign + ff.kV * velocity;
      final voltage =
          (pidOutput + ffOutput).clamp(-nominalVoltage, nominalVoltage);

      final acceleration =
          (voltage - ff.kS * velSign - ff.kV * velocity) / ff.kA;
      velocity = (velocity + acceleration * dt).clamp(-10.0, 10.0);
      prevError = error;

      // Downsample to every 10 ms to keep the chart efficient.
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
  }

  void _resetToAutoTuned() {
    setState(() {
      _kP = widget.initialPid?.kP ?? 1.0;
      _kI = widget.initialPid?.kI ?? 0.0;
      _kD = widget.initialPid?.kD ?? 0.0;
    });
    _runSimulation();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final subtleColor =
        theme.typography.body?.color?.withValues(alpha: 0.6);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Sliders ────────────────────────────────────────────────────
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

          Button(
            onPressed: widget.initialPid != null ? _resetToAutoTuned : null,
            child: const Text('Reset to Auto-Tuned'),
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
                          axisNameWidget: const Text('Velocity (norm.)',
                              style: TextStyle(fontSize: 10)),
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
