/// Three-curve comparison chart: visualizes the step-response difference
/// between PID-only, Feedforward-only, and FF+PID control strategies.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../data/test_data.dart';

/// Simulated step-response data for a single control strategy.
class _SimResult {
  final List<FlSpot> spots;
  final double? riseTime;
  final double overshootPercent;
  final double steadyStateError;

  const _SimResult({
    required this.spots,
    this.riseTime,
    required this.overshootPercent,
    required this.steadyStateError,
  });
}

class ThreeCurveComparison extends StatelessWidget {
  final FeedforwardGains ff;
  final PidResult pid;

  const ThreeCurveComparison({
    super.key,
    required this.ff,
    required this.pid,
  });

  @override
  Widget build(BuildContext context) {
    if (ff.kA <= 0) {
      return const Center(child: Text('Need valid plant model (kA > 0)'));
    }

    final pidOnly = _simulate(ff, pid, useFf: false, usePid: true);
    final ffOnly = _simulate(ff, pid, useFf: true, usePid: false);
    final ffPid = _simulate(ff, pid, useFf: true, usePid: true);

    final theme = FluentTheme.of(context);
    final subtle = theme.typography.body?.color?.withValues(alpha: 0.5);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FluentIcons.chart_series, size: 16),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Control Strategy Comparison',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Simulated step response (setpoint = 1.0) using your identified '
            'plant model and tuned gains. Compares three strategies.',
            style: TextStyle(fontSize: 10, color: subtle),
          ),
          const SizedBox(height: 8),

          // Legend
          _buildLegend(),
          const SizedBox(height: 8),

          // Chart
          Expanded(child: _buildChart(ffPid, ffOnly, pidOnly, theme)),

          const SizedBox(height: 8),

          // Metrics table
          _buildMetricsTable(ffPid, ffOnly, pidOnly, theme),
        ],
      ),
    );
  }

  Widget _buildLegend() {
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        _legendItem(const Color(0xFF888888), 'Setpoint', dashed: true),
        _legendItem(const Color(0xFF22BB22), 'FF + PID'),
        _legendItem(const Color(0xFF4488DD), 'FF Only'),
        _legendItem(const Color(0xFFDD8833), 'PID Only'),
      ],
    );
  }

  Widget _legendItem(Color color, String label, {bool dashed = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 3,
          decoration: BoxDecoration(
            color: dashed ? null : color,
            border: dashed
                ? Border(
                    bottom: BorderSide(
                      color: color,
                      width: 2,
                      style: BorderStyle.solid,
                    ),
                  )
                : null,
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    );
  }

  Widget _buildChart(
    _SimResult ffPid,
    _SimResult ffOnly,
    _SimResult pidOnly,
    FluentThemeData theme,
  ) {
    const setpoint = 1.0;

    // Determine Y range
    double maxY = setpoint * 1.1;
    for (final sim in [ffPid, ffOnly, pidOnly]) {
      for (final s in sim.spots) {
        if (s.y > maxY) maxY = s.y;
      }
    }
    maxY = (maxY * 1.15).clamp(setpoint * 1.1, setpoint * 3.0);

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: 2.0,
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          horizontalInterval: maxY / 5,
          verticalInterval: 0.5,
          getDrawingHorizontalLine: (v) => FlLine(
            color: theme.typography.body?.color?.withValues(alpha: 0.08) ??
                const Color(0x14FFFFFF),
            strokeWidth: 0.5,
          ),
          getDrawingVerticalLine: (v) => FlLine(
            color: theme.typography.body?.color?.withValues(alpha: 0.08) ??
                const Color(0x14FFFFFF),
            strokeWidth: 0.5,
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            axisNameWidget: const Text('Velocity',
                style: TextStyle(fontSize: 10)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 9,
                  color: theme.typography.body?.color?.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            axisNameWidget: const Text('Time (s)',
                style: TextStyle(fontSize: 10)),
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: 0.5,
              getTitlesWidget: (v, _) => Text(
                v.toStringAsFixed(1),
                style: TextStyle(
                  fontSize: 9,
                  color: theme.typography.body?.color?.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        borderData: FlBorderData(
          border: Border.all(
            color: theme.typography.body?.color?.withValues(alpha: 0.15) ??
                const Color(0x26FFFFFF),
          ),
        ),
        lineBarsData: [
          // Setpoint reference
          LineChartBarData(
            spots: const [FlSpot(0, setpoint), FlSpot(2, setpoint)],
            isCurved: false,
            color: const Color(0xFF888888),
            barWidth: 1.5,
            dashArray: [6, 4],
            dotData: const FlDotData(show: false),
          ),
          // FF + PID
          LineChartBarData(
            spots: ffPid.spots,
            isCurved: true,
            curveSmoothness: 0.15,
            color: const Color(0xFF22BB22),
            barWidth: 2.5,
            dotData: const FlDotData(show: false),
          ),
          // FF Only
          LineChartBarData(
            spots: ffOnly.spots,
            isCurved: true,
            curveSmoothness: 0.15,
            color: const Color(0xFF4488DD),
            barWidth: 2.0,
            dotData: const FlDotData(show: false),
          ),
          // PID Only
          LineChartBarData(
            spots: pidOnly.spots,
            isCurved: true,
            curveSmoothness: 0.15,
            color: const Color(0xFFDD8833),
            barWidth: 2.0,
            dotData: const FlDotData(show: false),
          ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => spots.map((s) {
              final labels = ['Setpoint', 'FF+PID', 'FF Only', 'PID Only'];
              final colors = [
                const Color(0xFF888888),
                const Color(0xFF22BB22),
                const Color(0xFF4488DD),
                const Color(0xFFDD8833),
              ];
              final idx = s.barIndex.clamp(0, labels.length - 1);
              return LineTooltipItem(
                '${labels[idx]}: ${s.y.toStringAsFixed(3)}',
                TextStyle(color: colors[idx], fontSize: 11),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildMetricsTable(
    _SimResult ffPid,
    _SimResult ffOnly,
    _SimResult pidOnly,
    FluentThemeData theme,
  ) {
    Widget cell(String text, {bool header = false, Color? color}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: header ? FontWeight.w600 : FontWeight.normal,
            fontFamily: header ? null : 'Consolas',
            color: color,
          ),
        ),
      );
    }

    String fmtRise(double? rt) =>
        rt != null ? '${(rt * 1000).toStringAsFixed(0)} ms' : '—';
    String fmtOs(double os) => '${os.toStringAsFixed(1)}%';
    String fmtSse(double sse) => sse.toStringAsFixed(4);

    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1.5),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1),
        3: FlexColumnWidth(1),
      },
      children: [
        TableRow(children: [
          cell('Metric', header: true),
          cell('FF + PID', header: true, color: const Color(0xFF22BB22)),
          cell('FF Only', header: true, color: const Color(0xFF4488DD)),
          cell('PID Only', header: true, color: const Color(0xFFDD8833)),
        ]),
        TableRow(children: [
          cell('Rise Time', header: true),
          cell(fmtRise(ffPid.riseTime)),
          cell(fmtRise(ffOnly.riseTime)),
          cell(fmtRise(pidOnly.riseTime)),
        ]),
        TableRow(children: [
          cell('Overshoot', header: true),
          cell(fmtOs(ffPid.overshootPercent)),
          cell(fmtOs(ffOnly.overshootPercent)),
          cell(fmtOs(pidOnly.overshootPercent)),
        ]),
        TableRow(children: [
          cell('SS Error', header: true),
          cell(fmtSse(ffPid.steadyStateError)),
          cell(fmtSse(ffOnly.steadyStateError)),
          cell(fmtSse(pidOnly.steadyStateError)),
        ]),
      ],
    );
  }

  // ── Simulation ──────────────────────────────────────────────────────

  static _SimResult _simulate(
    FeedforwardGains plant,
    PidResult pid, {
    required bool useFf,
    required bool usePid,
  }) {
    const dt = 0.001;
    const steps = 2000; // 2 s
    const setpoint = 1.0;
    const nominalVoltage = 12.0;

    double integral = 0;
    double prevError = setpoint;
    double velocity = 0;
    double maxVel = 0;
    double? riseTime10;
    double? riseTime90;

    final spots = <FlSpot>[const FlSpot(0, 0)];

    final kP = pid.kP;
    final kI = pid.kI;
    final kD = pid.kD;
    final ffKs = plant.kS;
    final ffKv = plant.kV;
    final ffKg = plant.kG;

    for (int i = 1; i <= steps; i++) {
      final t = i * dt;
      final error = setpoint - velocity;
      integral += error * dt;
      final derivative = (error - prevError) / dt;

      double voltage = 0;

      if (usePid) {
        voltage += kP * error + kI * integral + kD * derivative;
      }
      if (useFf) {
        final spSign = setpoint >= 0 ? 1.0 : -1.0;
        voltage += ffKs * spSign + ffKv * setpoint + ffKg;
      }

      voltage = voltage.clamp(-nominalVoltage, nominalVoltage);

      final velSign = velocity >= 0 ? 1.0 : -1.0;
      final acceleration =
          (voltage - plant.kS * velSign - plant.kV * velocity - plant.kG) /
              plant.kA;
      velocity += acceleration * dt;
      prevError = error;

      if (i % 10 == 0) {
        spots.add(FlSpot(t, velocity));
      }

      if (velocity > maxVel) maxVel = velocity;
      if (riseTime10 == null && velocity >= 0.1 * setpoint) riseTime10 = t;
      if (riseTime90 == null && velocity >= 0.9 * setpoint) riseTime90 = t;
    }

    final riseTime = (riseTime10 != null && riseTime90 != null)
        ? riseTime90 - riseTime10
        : null;

    return _SimResult(
      spots: spots,
      riseTime: riseTime,
      overshootPercent:
          maxVel > setpoint ? (maxVel - setpoint) / setpoint * 100.0 : 0.0,
      steadyStateError: (setpoint - velocity).abs(),
    );
  }
}
