/// Results screen: display computed feedforward & PID gains, diagnostic
/// plots, and export options.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../data/test_data.dart';
import '../../data/csv_exporter.dart';
import '../../mechanisms/mechanism.dart';
import '../../state/app_state.dart';
import '../../sysid/feedforward_analyzer.dart';
import '../../sysid/pid_autotuner.dart';

class ResultsScreen extends ConsumerStatefulWidget {
  const ResultsScreen({super.key});

  @override
  ConsumerState<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends ConsumerState<ResultsScreen> {
  FeedforwardGains? _ff;
  PidResult? _velPid;
  PidResult? _posPid;
  String? _analysisError;
  bool _analyzed = false;

  @override
  Widget build(BuildContext context) {
    final testRuns = ref.watch(testRunsProvider);
    final config = ref.watch(mechanismConfigProvider);

    final qsRuns = testRuns.where((r) => r.testType.isQuasistatic).toList();
    final dynRuns = testRuns.where((r) => r.testType.isDynamic).toList();
    final canAnalyze = qsRuns.isNotEmpty && dynRuns.isNotEmpty;

    return ScaffoldPage.scrollable(
      header: PageHeader(
        title: const Text('Results'),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            CommandBarButton(
              icon: const Icon(FluentIcons.download),
              label: const Text('Export CSV'),
              onPressed:
                  testRuns.isNotEmpty ? () => _exportCsv(testRuns) : null,
            ),
            CommandBarButton(
              icon: const Icon(FluentIcons.download),
              label: const Text('Export WPILib JSON'),
              onPressed: testRuns.isNotEmpty
                  ? () => _exportWpiLib(testRuns)
                  : null,
            ),
          ],
        ),
      ),
      children: [
        // Analysis button
        Row(
          children: [
            FilledButton(
              onPressed:
                  canAnalyze ? () => _runAnalysis(qsRuns, dynRuns, config) : null,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Text('Compute Feedforward & PID'),
              ),
            ),
            const SizedBox(width: 16),
            if (!canAnalyze && testRuns.isNotEmpty)
              const InfoBar(
                title: Text('Need more data'),
                content: Text(
                  'Run at least one quasistatic and one dynamic test before analysis.',
                ),
                severity: InfoBarSeverity.warning,
              ),
            if (testRuns.isEmpty)
              const InfoBar(
                title: Text('No test data'),
                content: Text('Run tests on the "Run Tests" page first.'),
                severity: InfoBarSeverity.info,
              ),
          ],
        ),

        if (_analysisError != null) ...[
          const SizedBox(height: 12),
          InfoBar(
            title: const Text('Analysis Error'),
            content: Text(_analysisError!),
            severity: InfoBarSeverity.error,
          ),
        ],

        // Results display
        if (_analyzed && _ff != null) ...[
          const SizedBox(height: 24),

          // Feedforward gains
          const Text(
            'Feedforward Constants',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          _GainsTable(ff: _ff!, mechanismType: config.type),

          const SizedBox(height: 24),

          // PID gains
          const Text(
            'PID Gains (Auto-Tuned)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_velPid != null)
                Expanded(child: _PidCard(title: 'Velocity PID', pid: _velPid!)),
              const SizedBox(width: 12),
              if (_posPid != null)
                Expanded(child: _PidCard(title: 'Position PID', pid: _posPid!)),
            ],
          ),

          const SizedBox(height: 16),

          // Write to controller button
          if (ref.read(deviceManagerProvider).leader != null)
            FilledButton(
              onPressed: () => _writePidToController(ref),
              child: const Text('Write Velocity PID to Controller'),
            ),

          const SizedBox(height: 24),

          // Diagnostic plots
          const Text(
            'Diagnostic Plots',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 300,
            child: Row(
              children: [
                Expanded(
                  child: _VoltageVelocityPlot(
                    testRuns: qsRuns,
                    ff: _ff!,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StepResponsePlot(testRuns: dynRuns),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 24),

        // Test run summary table
        if (testRuns.isNotEmpty) ...[
          const Text(
            'Test Runs',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          ...testRuns.map((run) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Card(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${run.testType.displayName} — '
                          '${run.sampleCount} samples, '
                          '${run.durationSeconds.toStringAsFixed(1)}s',
                        ),
                      ),
                      Button(
                        onPressed: () {
                          ref.read(testRunsProvider.notifier).removeRun(run.id);
                        },
                        child: const Icon(FluentIcons.delete, size: 14),
                      ),
                    ],
                  ),
                ),
              )),
        ],
      ],
    );
  }

  void _runAnalysis(
    List<TestRun> qsRuns,
    List<TestRun> dynRuns,
    MechanismConfig config,
  ) {
    try {
      final ff = FeedforwardAnalyzer.analyze(
        quasistaticRuns: qsRuns,
        dynamicRuns: dynRuns,
        mechanismType: config.type,
      );

      final velPid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: config.type,
      );

      final posPid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: config.type,
      );

      setState(() {
        _ff = ff;
        _velPid = velPid;
        _posPid = posPid;
        _analyzed = true;
        _analysisError = null;
      });

      // Store in global state for other screens.
      ref.read(feedforwardGainsProvider.notifier).state = ff;
      ref.read(pidResultProvider.notifier).state = velPid;
    } catch (e) {
      setState(() {
        _analysisError = e.toString();
      });
    }
  }

  Future<void> _writePidToController(WidgetRef ref) async {
    final device = ref.read(deviceManagerProvider).leader;
    if (device == null || _velPid == null) return;

    try {
      await device.parameters.setPidSlot0(
        p: _velPid!.kP,
        i: _velPid!.kI,
        d: _velPid!.kD,
        f: _velPid!.kF,
      );
      await device.parameters.burnFlash();

      if (mounted) {
        await displayInfoBar(context, builder: (ctx, close) {
          return InfoBar(
            title: const Text('Success'),
            content: const Text('PID gains written to controller and saved to flash.'),
            severity: InfoBarSeverity.success,
            action: IconButton(
              icon: const Icon(FluentIcons.clear),
              onPressed: close,
            ),
          );
        });
      }
    } catch (e) {
      if (mounted) {
        await displayInfoBar(context, builder: (ctx, close) {
          return InfoBar(
            title: const Text('Error'),
            content: Text('Failed to write PID: $e'),
            severity: InfoBarSeverity.error,
            action: IconButton(
              icon: const Icon(FluentIcons.clear),
              onPressed: close,
            ),
          );
        });
      }
    }
  }

  Future<void> _exportCsv(List<TestRun> runs) async {
    final path = await CsvExporter.exportAllRuns(runs);
    if (path != null && mounted) {
      await displayInfoBar(context, builder: (ctx, close) {
        return InfoBar(
          title: const Text('Exported'),
          content: Text('Saved to: $path'),
          severity: InfoBarSeverity.success,
          action: IconButton(
            icon: const Icon(FluentIcons.clear),
            onPressed: close,
          ),
        );
      });
    }
  }

  Future<void> _exportWpiLib(List<TestRun> runs) async {
    final path = await CsvExporter.exportWpiLibFormat(runs);
    if (path != null && mounted) {
      await displayInfoBar(context, builder: (ctx, close) {
        return InfoBar(
          title: const Text('Exported'),
          content: Text('WPILib SysId JSON saved to: $path'),
          severity: InfoBarSeverity.success,
          action: IconButton(
            icon: const Icon(FluentIcons.clear),
            onPressed: close,
          ),
        );
      });
    }
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _GainsTable extends StatelessWidget {
  final FeedforwardGains ff;
  final MechanismType mechanismType;

  const _GainsTable({required this.ff, required this.mechanismType});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          _GainRow('kS (Static Friction)', '${ff.kS.toStringAsFixed(5)} V'),
          _GainRow('kV (Velocity)', '${ff.kV.toStringAsFixed(5)} V·s/${mechanismType.positionUnit}'),
          _GainRow('kA (Acceleration)', '${ff.kA.toStringAsFixed(5)} V·s²/${mechanismType.positionUnit}'),
          if (mechanismType.hasGravity)
            _GainRow('kG (Gravity)', '${ff.kG.toStringAsFixed(5)} V'),
          _GainRow('R² (Fit Quality)', ff.rSquared.toStringAsFixed(4),
              highlight: ff.rSquared > 0.9),
        ],
      ),
    );
  }
}

class _GainRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;

  const _GainRow(this.label, this.value, {this.highlight = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(width: 250, child: Text(label)),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontFamily: 'Consolas',
              color: highlight ? Colors.successPrimaryColor : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _PidCard extends StatelessWidget {
  final String title;
  final PidResult pid;

  const _PidCard({required this.title, required this.pid});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          _GainRow('kP', pid.kP.toStringAsFixed(6)),
          _GainRow('kI', pid.kI.toStringAsFixed(6)),
          _GainRow('kD', pid.kD.toStringAsFixed(6)),
          _GainRow('kF', pid.kF.toStringAsFixed(6)),
        ],
      ),
    );
  }
}

class _VoltageVelocityPlot extends StatelessWidget {
  final List<TestRun> testRuns;
  final FeedforwardGains ff;

  const _VoltageVelocityPlot({required this.testRuns, required this.ff});

  @override
  Widget build(BuildContext context) {
    // Scatter plot: voltage vs velocity from quasistatic data
    final spots = <FlSpot>[];
    for (final run in testRuns) {
      for (final dp in run.data) {
        if (dp.velocity.abs() > 0.01) {
          spots.add(FlSpot(dp.velocity, dp.voltage));
        }
      }
    }

    if (spots.isEmpty) {
      return const Card(child: Center(child: Text('No data')));
    }

    // Regression line: V = kS + kV * velocity
    final minVel = spots.map((s) => s.x).reduce((a, b) => a < b ? a : b);
    final maxVel = spots.map((s) => s.x).reduce((a, b) => a > b ? a : b);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Voltage vs Velocity (Quasistatic)',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Expanded(
            child: LineChart(
              LineChartData(
                lineBarsData: [
                  // Scatter data
                  LineChartBarData(
                    spots: spots,
                    isCurved: false,
                    color: Colors.blue.withValues(alpha: 0.3),
                    barWidth: 0,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, data, barData, index) =>
                          FlDotCirclePainter(
                        radius: 2,
                        color: Colors.blue,
                        strokeWidth: 0,
                      ),
                    ),
                  ),
                  // Regression line
                  LineChartBarData(
                    spots: [
                      FlSpot(minVel, ff.kS * minVel.sign + ff.kV * minVel),
                      FlSpot(maxVel, ff.kS * maxVel.sign + ff.kV * maxVel),
                    ],
                    isCurved: false,
                    color: Colors.red,
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                  ),
                ],
                titlesData: FlTitlesData(
                  topTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    axisNameWidget: const Text('Velocity',
                        style: TextStyle(fontSize: 10)),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      getTitlesWidget: (v, _) => Text(
                        v.toStringAsFixed(0),
                        style: const TextStyle(fontSize: 9),
                      ),
                    ),
                  ),
                  leftTitles: AxisTitles(
                    axisNameWidget: const Text('Voltage (V)',
                        style: TextStyle(fontSize: 10)),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 40,
                      getTitlesWidget: (v, _) => Text(
                        v.toStringAsFixed(1),
                        style: const TextStyle(fontSize: 9),
                      ),
                    ),
                  ),
                ),
                gridData: const FlGridData(show: true, drawVerticalLine: false),
                borderData: FlBorderData(show: false),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepResponsePlot extends StatelessWidget {
  final List<TestRun> testRuns;

  const _StepResponsePlot({required this.testRuns});

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    for (final run in testRuns) {
      for (final dp in run.data) {
        spots.add(FlSpot(dp.timestamp, dp.velocity));
      }
    }

    if (spots.isEmpty) {
      return const Card(child: Center(child: Text('No data')));
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Step Response (Dynamic)',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Expanded(
            child: LineChart(
              LineChartData(
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: false,
                    color: Colors.orange,
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                  ),
                ],
                titlesData: FlTitlesData(
                  topTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
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
                    axisNameWidget: const Text('Velocity',
                        style: TextStyle(fontSize: 10)),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      getTitlesWidget: (v, _) => Text(
                        v.toStringAsFixed(0),
                        style: const TextStyle(fontSize: 9),
                      ),
                    ),
                  ),
                ),
                gridData: const FlGridData(show: true, drawVerticalLine: false),
                borderData: FlBorderData(show: false),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
