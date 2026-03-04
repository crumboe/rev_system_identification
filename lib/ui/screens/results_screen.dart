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
import '../widgets/chart_walkthrough.dart';
import '../widgets/chart_annotations.dart';

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
                Expanded(child: _PidCard(
                  title: 'Velocity PID',
                  pid: _velPid!,
                  ff: _ff,
                  mode: _PidMode.velocity,
                )),
              const SizedBox(width: 12),
              if (_posPid != null)
                Expanded(child: _PidCard(
                  title: 'Position PID',
                  pid: _posPid!,
                  ff: _ff,
                  mode: _PidMode.position,
                )),
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

  String get _modelEquation {
    if (mechanismType == MechanismType.arm) {
      return 'V = kS·sign(ω) + kV·ω + kA·α + kG·cos(θ)';
    } else if (mechanismType == MechanismType.elevator) {
      return 'V = kS·sign(ω) + kV·ω + kA·α + kG';
    }
    return 'V = kS·sign(ω) + kV·ω + kA·α';
  }

  @override
  Widget build(BuildContext context) {
    final posUnit = mechanismType.positionUnit;
    final velUnit = mechanismType.velocityUnit;

    return Card(
      child: Column(
        children: [
          _GainRow(
            'kS (Static Friction)',
            '${ff.kS.toStringAsFixed(5)} V',
            tooltip:
                'kS — Static Friction Voltage\n\n'
                'The minimum voltage needed to overcome static friction '
                'and start the mechanism moving.\n\n'
                'Calculated as the sign(ω) coefficient in the OLS '
                'regression of the model:\n'
                '  $_modelEquation\n\n'
                'Extracted primarily from quasistatic test data where '
                'velocity is slowly increasing. kS is the Y-intercept '
                'of the Voltage vs. Velocity plot.',
          ),
          _GainRow(
            'kV (Velocity)',
            '${ff.kV.toStringAsFixed(5)} V·s/$posUnit',
            tooltip:
                'kV — Velocity Constant\n\n'
                'The voltage required per unit of velocity ($velUnit) '
                'to maintain constant speed against back-EMF.\n\n'
                'Calculated as the ω coefficient in the OLS '
                'regression of the model:\n'
                '  $_modelEquation\n\n'
                'This is the slope of the Voltage vs. Velocity line '
                'from quasistatic data. A larger kV means the motor '
                'requires more voltage per unit of speed.',
          ),
          _GainRow(
            'kA (Acceleration)',
            '${ff.kA.toStringAsFixed(5)} V·s²/$posUnit',
            tooltip:
                'kA — Acceleration Constant\n\n'
                'The voltage required per unit of acceleration to '
                'overcome the mechanism\'s inertia.\n\n'
                'Calculated as the α coefficient in the OLS '
                'regression of the model:\n'
                '  $_modelEquation\n\n'
                'Extracted primarily from dynamic (step-voltage) test '
                'data where significant acceleration occurs. '
                'A larger kA means more inertia / heavier mechanism.',
          ),
          if (mechanismType == MechanismType.arm)
            _GainRow(
              'kG (Gravity)',
              '${ff.kG.toStringAsFixed(5)} V',
              tooltip:
                  'kG — Gravity Compensation (Arm)\n\n'
                  'The voltage needed to hold the arm against gravity '
                  'when it is horizontal (θ = 0°).\n\n'
                  'The gravity term is cos(θ), so the actual '
                  'compensation at any angle is kG·cos(θ).\n\n'
                  'Calculated as the cos(θ) coefficient in the OLS '
                  'regression of the model:\n'
                  '  $_modelEquation\n\n'
                  'At 0° (horizontal) the full kG is applied; '
                  'at ±90° (vertical) the gravity term is zero.',
            ),
          if (mechanismType == MechanismType.elevator)
            _GainRow(
              'kG (Gravity)',
              '${ff.kG.toStringAsFixed(5)} V',
              tooltip:
                  'kG — Gravity Compensation (Elevator)\n\n'
                  'The constant voltage needed to hold the elevator '
                  'against gravity at any position.\n\n'
                  'Unlike an arm, gravity on an elevator is '
                  'position-independent, so kG is a flat offset '
                  'added to the feedforward output.\n\n'
                  'Calculated as the constant gravity-term '
                  'coefficient in the OLS regression of the model:\n'
                  '  $_modelEquation',
            ),
          _GainRow(
            'R² (Fit Quality)',
            ff.rSquared.toStringAsFixed(4),
            highlight: ff.rSquared > 0.9,
            tooltip:
                'R² — Coefficient of Determination\n\n'
                'Measures how well the model fits the collected data.\n\n'
                'R² = 1 − (SS_res / SS_tot)\n\n'
                'SS_res = Σ(V_actual − V_predicted)² (residual)\n'
                'SS_tot = Σ(V_actual − V̄)²  (total variance)\n\n'
                'Values close to 1.0 mean the model explains nearly '
                'all of the variance in the data. Values above 0.9 '
                'are highlighted green. Below 0.8 suggests noisy '
                'data or a poor test run.',
          ),
        ],
      ),
    );
  }
}

class _GainRow extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;
  final String? tooltip;

  const _GainRow(this.label, this.value, {this.highlight = false, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 250,
            child: Row(
              children: [
                Text(label),
                if (tooltip != null) ...[
                  const SizedBox(width: 4),
                  const Icon(FluentIcons.info, size: 12),
                ],
              ],
            ),
          ),
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

    if (tooltip != null) {
      return Tooltip(
        message: tooltip!,
        style: const TooltipThemeData(
          waitDuration: Duration(milliseconds: 300),
        ),
        child: MouseRegion(
          cursor: SystemMouseCursors.help,
          child: row,
        ),
      );
    }

    return row;
  }
}

enum _PidMode { velocity, position }

class _PidCard extends StatefulWidget {
  final String title;
  final PidResult pid;
  final FeedforwardGains? ff;
  final _PidMode mode;

  const _PidCard({
    required this.title,
    required this.pid,
    this.ff,
    this.mode = _PidMode.velocity,
  });

  @override
  State<_PidCard> createState() => _PidCardState();
}

class _PidCardState extends State<_PidCard> {
  bool _showExplanation = false;

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(widget.title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              Tooltip(
                message: _showExplanation
                    ? 'Hide derivation'
                    : 'How were these calculated?',
                child: IconButton(
                  icon: Icon(
                    FluentIcons.lightbulb,
                    size: 14,
                    color: _showExplanation ? theme.accentColor : null,
                  ),
                  onPressed: () =>
                      setState(() => _showExplanation = !_showExplanation),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _GainRow('kP', widget.pid.kP.toStringAsFixed(6)),
          _GainRow('kI', widget.pid.kI.toStringAsFixed(6)),
          _GainRow('kD', widget.pid.kD.toStringAsFixed(6)),
          _GainRow('kF', widget.pid.kF.toStringAsFixed(6)),
          if (_showExplanation && widget.ff != null) ..._buildExplanation(theme),
        ],
      ),
    );
  }

  List<Widget> _buildExplanation(FluentThemeData theme) {
    final ff = widget.ff!;
    final explainColor = theme.typography.body?.color?.withValues(alpha: 0.8);
    const monoStyle = TextStyle(fontFamily: 'Consolas', fontSize: 12);
    final captionStyle = TextStyle(fontSize: 12, color: explainColor, height: 1.5);

    if (widget.mode == _PidMode.velocity) {
      return [
        const Divider(),
        const SizedBox(height: 8),
        Text('How Velocity PID is derived', style: TextStyle(
          fontSize: 13, fontWeight: FontWeight.w600, color: theme.accentColor)),
        const SizedBox(height: 6),
        Text(
          'The motor + mechanism acts like a first-order system:\n'
          '    G(s) = 1 / (kA\u00b7s + kV)\n\n'
          'We design a PI controller using model-inversion, targeting a '
          'closed-loop time constant \u03c4 = 100 ms:',
          style: captionStyle,
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.accentColor.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('kP = (kA / \u03c4) / V_nominal', style: monoStyle),
              Text('   = (${ff.kA.toStringAsFixed(5)} / 0.100) / 12.0', style: monoStyle),
              Text('   = ${widget.pid.kP.toStringAsFixed(6)}', style: monoStyle),
              const SizedBox(height: 4),
              Text('kF = kV / V_nominal', style: monoStyle),
              Text('   = ${ff.kV.toStringAsFixed(5)} / 12.0', style: monoStyle),
              Text('   = ${widget.pid.kF.toStringAsFixed(6)}', style: monoStyle),
              const SizedBox(height: 4),
              Text('kI = 0  (avoids integral windup)', style: monoStyle),
              Text('kD = 0  (not needed for velocity)', style: monoStyle),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'kP controls how aggressively the controller corrects velocity '
          'errors. kF is a feedforward term that predicts most of the '
          'output, so PID only handles small corrections.',
          style: captionStyle,
        ),
      ];
    } else {
      // Position PID
      const bwHz = 5.0;
      final omega = 2.0 * 3.14159265 * bwHz;
      return [
        const Divider(),
        const SizedBox(height: 8),
        Text('How Position PID is derived', style: TextStyle(
          fontSize: 13, fontWeight: FontWeight.w600, color: theme.accentColor)),
        const SizedBox(height: 6),
        Text(
          'The motor + mechanism from voltage to position is a '
          'second-order system:\n'
          '    G(s) = 1 / (kA\u00b7s\u00b2 + kV\u00b7s)\n\n'
          'We use pole placement for a critically-damped response '
          'at ${bwHz.toStringAsFixed(0)} Hz bandwidth '
          '(\u03c9 = ${omega.toStringAsFixed(1)} rad/s):',
          style: captionStyle,
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.accentColor.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('kP = (kA \u00b7 \u03c9\u00b2) / V_nominal', style: monoStyle),
              Text('   = (${ff.kA.toStringAsFixed(5)} \u00b7 ${omega.toStringAsFixed(1)}\u00b2) / 12.0', style: monoStyle),
              Text('   = ${widget.pid.kP.toStringAsFixed(6)}', style: monoStyle),
              const SizedBox(height: 4),
              Text('kD = (2\u00b7kA\u00b7\u03c9 \u2212 kV) / V_nominal', style: monoStyle),
              Text('   = (2\u00b7${ff.kA.toStringAsFixed(5)}\u00b7${omega.toStringAsFixed(1)} \u2212 ${ff.kV.toStringAsFixed(5)}) / 12.0', style: monoStyle),
              Text('   = ${widget.pid.kD.toStringAsFixed(6)}  ${widget.pid.kD == 0 ? "(clamped \u2265 0)" : ""}', style: monoStyle),
              const SizedBox(height: 4),
              Text('kI = 0  (not needed for position)', style: monoStyle),
              Text('kF = 0  (no velocity feedforward for position)', style: monoStyle),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'kP creates a restoring force proportional to position error. '
          'kD provides damping (like shock absorbers) to prevent oscillation. '
          'The "2\u00b7kA\u00b7\u03c9 \u2212 kV" subtracts the system\u2019s '
          'natural damping (kV) so we don\u2019t over-damp.',
          style: captionStyle,
        ),
      ];
    }
  }
}

class _VoltageVelocityPlot extends StatefulWidget {
  final List<TestRun> testRuns;
  final FeedforwardGains ff;

  const _VoltageVelocityPlot({required this.testRuns, required this.ff});

  @override
  State<_VoltageVelocityPlot> createState() => _VoltageVelocityPlotState();
}

class _VoltageVelocityPlotState extends State<_VoltageVelocityPlot> {
  bool _walkthroughActive = false;

  @override
  Widget build(BuildContext context) {
    // Scatter plot: voltage vs velocity from quasistatic data
    final spots = <FlSpot>[];
    for (final run in widget.testRuns) {
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

    final chart = Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Voltage vs Velocity (Quasistatic)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              WalkthroughToggle(
                isActive: _walkthroughActive,
                onToggle: () =>
                    setState(() => _walkthroughActive = !_walkthroughActive),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: LineChart(
              LineChartData(
                lineTouchData: LineTouchData(
                  enabled: !_walkthroughActive,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (touchedSpots) {
                      return touchedSpots.map((spot) {
                        return LineTooltipItem(
                          'Vel: ${spot.x.toStringAsFixed(1)}\n'
                          'V: ${spot.y.toStringAsFixed(2)} V',
                          const TextStyle(fontSize: 11),
                        );
                      }).toList();
                    },
                  ),
                ),
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
                      FlSpot(minVel, widget.ff.kS * minVel.sign + widget.ff.kV * minVel),
                      FlSpot(maxVel, widget.ff.kS * maxVel.sign + widget.ff.kV * maxVel),
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

    return ChartWalkthrough(
      isActive: _walkthroughActive,
      steps: voltageVelocityWalkthroughSteps(
        kS: widget.ff.kS,
        kV: widget.ff.kV,
        rSquared: widget.ff.rSquared,
      ),
      onDismiss: () => setState(() => _walkthroughActive = false),
      child: chart,
    );
  }
}

class _StepResponsePlot extends StatefulWidget {
  final List<TestRun> testRuns;

  const _StepResponsePlot({required this.testRuns});

  @override
  State<_StepResponsePlot> createState() => _StepResponsePlotState();
}

class _StepResponsePlotState extends State<_StepResponsePlot> {
  bool _walkthroughActive = false;

  static final _runColors = [Colors.orange, Colors.teal];

  @override
  Widget build(BuildContext context) {
    // Build a separate line bar per test run so runs aren't connected
    // by an unwanted diagonal line.
    final lineBars = <LineChartBarData>[];
    for (var i = 0; i < widget.testRuns.length; i++) {
      final run = widget.testRuns[i];
      final spots = run.data
          .map((dp) => FlSpot(dp.timestamp, dp.velocity))
          .toList();
      if (spots.isEmpty) continue;
      lineBars.add(LineChartBarData(
        spots: spots,
        isCurved: false,
        color: _runColors[i % _runColors.length],
        barWidth: 1.5,
        dotData: const FlDotData(show: false),
      ));
    }

    if (lineBars.isEmpty) {
      return const Card(child: Center(child: Text('No data')));
    }

    final chart = Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Step Response (Dynamic)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              WalkthroughToggle(
                isActive: _walkthroughActive,
                onToggle: () =>
                    setState(() => _walkthroughActive = !_walkthroughActive),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: LineChart(
              LineChartData(
                lineTouchData: LineTouchData(
                  enabled: !_walkthroughActive,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (touchedSpots) {
                      return touchedSpots.map((spot) {
                        return LineTooltipItem(
                          't: ${spot.x.toStringAsFixed(2)}s\n'
                          'vel: ${spot.y.toStringAsFixed(1)}',
                          const TextStyle(fontSize: 11),
                        );
                      }).toList();
                    },
                  ),
                ),
                lineBarsData: lineBars,
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

    return ChartWalkthrough(
      isActive: _walkthroughActive,
      steps: stepResponseWalkthroughSteps(),
      onDismiss: () => setState(() => _walkthroughActive = false),
      child: chart,
    );
  }
}
