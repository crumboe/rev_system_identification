/// Results screen: display computed feedforward & PID gains, diagnostic
/// plots, and export options.
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

// Needed for PointerDeviceKind
import 'dart:ui';

import '../../data/test_data.dart';
import '../../data/csv_exporter.dart';
import '../../data/notebook_exporter.dart';
import '../../data/report_generator.dart';
import '../../mechanisms/mechanism.dart';
import '../../state/app_state.dart';
import '../../sysid/feedforward_analyzer.dart';
import '../../sysid/pid_autotuner.dart';
import '../widgets/bode_plot.dart';
import '../widgets/chart_walkthrough.dart';
import '../widgets/chart_annotations.dart';
import '../widgets/concept_panel.dart';
import '../widgets/control_block_diagram.dart';
import '../widgets/pid_playground.dart';
import '../widgets/pole_zero_map.dart';
import '../widgets/matrix_equation_visual.dart';
import '../widgets/logo_header.dart';

class ResultsScreen extends ConsumerStatefulWidget {
  const ResultsScreen({super.key});

  @override
  ConsumerState<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends ConsumerState<ResultsScreen> {
  FeedforwardGains? _ff; // unloaded (or single) FF gains
  FeedforwardGains? _ffLoaded; // loaded FF gains (null if no loaded data)
  FeedforwardGains? _ffBlended; // blended FF for controller (null if single)
  PidResult? _velPid;
  PidResult? _posPid;
  String? _analysisError;
  bool _analyzed = false;
  bool _isPositionMode = false;

  // Legacy PID calculation toggle (hidden, only for sim)
  bool _legacyPidMode = false;

  // Hidden toggle activation: long-press on PID Gains title
  void _toggleLegacyPidMode() {
    setState(() => _legacyPidMode = !_legacyPidMode);
  }

  void _setLoopMode(bool isPosition) {
    if (isPosition != _isPositionMode) {
      setState(() => _isPositionMode = isPosition);
    }
  }

  @override
  Widget build(BuildContext context) {
    final testRuns = ref.watch(testRunsProvider);
    final config = ref.watch(mechanismConfigProvider);

    final qsRuns = testRuns.where((r) => r.testType.isQuasistatic).toList();
    final dynRuns = testRuns.where((r) => r.testType.isDynamic).toList();
    final canAnalyze = qsRuns.isNotEmpty && dynRuns.isNotEmpty;

    return ScaffoldPage.scrollable(
      header: LogoPageHeader(
        title: 'Results',
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          overflowBehavior: CommandBarOverflowBehavior.dynamicOverflow,
          primaryItems: [
            CommandBarButton(
              icon: const Icon(FluentIcons.education),
              label: const Text('Control Theory Concepts'),
              onPressed: () => _showConceptsDialog(context),
            ),
            const CommandBarSeparator(),
            CommandBarButton(
              icon: const Icon(FluentIcons.download),
              label: const Text('Export CSV'),
              onPressed: testRuns.isNotEmpty
                  ? () => _exportCsv(testRuns)
                  : null,
            ),
            CommandBarButton(
              icon: const Icon(FluentIcons.download),
              label: const Text('Export WPILib JSON'),
              onPressed: testRuns.isNotEmpty
                  ? () => _exportWpiLib(testRuns)
                  : null,
            ),
            CommandBarButton(
              icon: const Icon(FluentIcons.print),
              label: const Text('Export PDF Report'),
              onPressed: _ff != null
                  ? () => _exportPdf(config, testRuns)
                  : null,
            ),
            CommandBarButton(
              icon: const Icon(FluentIcons.text_document),
              label: const Text('Export Notebook'),
              onPressed: _ff != null
                  ? () => _exportNotebook(config, testRuns)
                  : null,
            ),
            CommandBarButton(
              icon: const Icon(FluentIcons.rocket),
              label: const Text('Go to Deploy'),
              onPressed: _ff != null
                  ? () => ref.read(selectedPageProvider.notifier).state = 7
                  : null,
            ),
          ],
        ),
      ),
      children: [
        // Tuning parameters (damping, velocity τ, position ω)
        _TuningParametersPanel(),
        const SizedBox(height: 12),

        // Analysis button
        Row(
          children: [
            FilledButton(
              onPressed: canAnalyze
                  ? () => _runAnalysis(qsRuns, dynRuns, config)
                  : null,
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
          if (_ffLoaded != null && _ffBlended != null) ...[
            _DualGainsTable(
              ffUnloaded: _ff!,
              ffLoaded: _ffLoaded!,
              ffBlended: _ffBlended!,
              config: config,
            ),
          ] else
            _GainsTable(ff: _ff!, config: config),

          // Regression walkthrough
          const SizedBox(height: 16),
          _buildRegressionWalkthrough(qsRuns, dynRuns),

          const SizedBox(height: 24),

          // Block diagram of the control system
          Expander(
            header: const Text(
              'Control System Architecture',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            content: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_velPid != null)
                  Expanded(
                    child: ControlBlockDiagram(
                      ff: _ff!,
                      pid: _velPid!,
                      mode: LoopMode.velocity,
                      mechanismType: config.type,
                    ),
                  ),
                const SizedBox(width: 16),
                if (_posPid != null)
                  Expanded(
                    child: ControlBlockDiagram(
                      ff: _ff!,
                      pid: _posPid!,
                      mode: LoopMode.position,
                      mechanismType: config.type,
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // PID gains

          // PID Gains title with hidden legacy toggle (only in sim)
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (event) {
              // Right-click (secondary button)
              if (event.kind == PointerDeviceKind.mouse && event.buttons == 2) {
                _toggleLegacyPidMode();
              }
            },
            child: GestureDetector(
              onLongPress: _toggleLegacyPidMode,
              onDoubleTap: _toggleLegacyPidMode,
              child: Row(
                children: [
                  const Text(
                    'PID Gains (Auto-Tuned)',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  if (_legacyPidMode) ...[
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Color(0xFFB8860B),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'LEGACY PID',
                        style: TextStyle(
                          color: Color(0xFFFFFFFF),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_velPid != null)
                Expanded(
                  child: _PidCard(
                    title: 'Velocity PID',
                    pid: _velPid!,
                    ff: _ff,
                    ffLoaded: _ffLoaded,
                    mode: _PidMode.velocity,
                    config: config,
                    onAllowedErrorChanged: (v) {
                      setState(
                        () => _velPid = _velPid!.copyWith(
                          allowedClosedLoopError: v,
                        ),
                      );
                      ref.read(pidResultProvider.notifier).state = _velPid;
                    },
                  ),
                ),
              const SizedBox(width: 12),
              if (_posPid != null)
                Expanded(
                  child: _PidCard(
                    title: 'Position PID',
                    pid: _posPid!,
                    ff: _ff,
                    ffLoaded: _ffLoaded,
                    mode: _PidMode.position,
                    config: config,
                    onAllowedErrorChanged: (v) {
                      setState(
                        () => _posPid = _posPid!.copyWith(
                          allowedClosedLoopError: v,
                        ),
                      );
                      ref.read(posPidResultProvider.notifier).state = _posPid;
                    },
                  ),
                ),
            ],
          ),

          const SizedBox(height: 24),

          // PID Playground
          Expander(
            initiallyExpanded: false,
            header: const Text(
              '"What If" PID Gain Playground',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            content: PidPlayground(
              ff: _ff!,
              initialPid: _velPid,
              initialPosPid: _posPid,
              isPositionMode: _isPositionMode,
              onModeChanged: _setLoopMode,
              onReset: () => _runAnalysis(qsRuns, dynRuns, config),
              mechanismConfig: config,
              onPidChanged: (pid) {
                setState(() => _velPid = pid);
              },
              onPosPidChanged: (pid) {
                setState(() => _posPid = pid);
              },
            ),
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
                  child: _ModelFitPlot(
                    testRuns: [...qsRuns, ...dynRuns],
                    ff: _ff!,
                    mechanismType: config.type,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: _StepResponsePlot(testRuns: dynRuns)),
              ],
            ),
          ),

          // Bode Plot — Frequency Response
          const SizedBox(height: 24),
          const Text(
            'Frequency Response (Bode Plot)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 350,
            child: BodePlot(
              ff: _ff!,
              velPid: _velPid,
              posPid: _posPid,
              mode: _isPositionMode
                  ? BodePlotMode.position
                  : BodePlotMode.velocity,
              onModeChanged: (m) => _setLoopMode(m == BodePlotMode.position),
            ),
          ),

          // Pole-Zero Map
          const SizedBox(height: 24),
          const Text(
            'Pole-Zero Map',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 350,
            child: PoleZeroMap(
              ff: _ff!,
              velPid: _velPid,
              posPid: _posPid,
              mechanismType: config.type,
              mode: _isPositionMode
                  ? PoleZeroMode.position
                  : PoleZeroMode.velocity,
              onModeChanged: (m) => _setLoopMode(m == PoleZeroMode.position),
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
          ...testRuns.map(
            (run) => Padding(
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
                    if (run.loadCondition != null) ...[
                      InfoBadge(
                        source: Text(
                          run.loadCondition == LoadCondition.loaded
                              ? 'LOADED'
                              : 'UNLOADED',
                        ),
                        color: run.loadCondition == LoadCondition.loaded
                            ? Colors.orange
                            : Colors.green,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Button(
                      onPressed: () {
                        ref.read(testRunsProvider.notifier).removeRun(run.id);
                      },
                      child: const Icon(FluentIcons.delete, size: 14),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  void _showConceptsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: const Row(
          children: [
            Icon(FluentIcons.education, size: 20),
            SizedBox(width: 8),
            Text('Control Theory Concepts'),
          ],
        ),
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 520),
        content: const ConceptPanel(embedded: true),
        actions: [
          FilledButton(
            child: const Text('Close'),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildRegressionWalkthrough(
    List<TestRun> qsRuns,
    List<TestRun> dynRuns,
  ) {
    final ff = _ff!;
    final mechType = ref.read(mechanismConfigProvider).type;

    final totalSamples = [
      ...qsRuns,
      ...dynRuns,
    ].fold<int>(0, (sum, r) => sum + r.sampleCount);
    final qsCount = qsRuns.length;
    final dynCount = dynRuns.length;

    final hasGravity = mechType.hasGravity;
    final theme = FluentTheme.of(context);
    const monoStyle = TextStyle(fontFamily: 'Consolas', fontSize: 12);
    final captionStyle = TextStyle(
      fontSize: 12,
      color: theme.typography.body?.color?.withValues(alpha: 0.75),
      height: 1.5,
    );

    // Shared builder for a numbered step card.
    Widget stepCard(int number, String title, List<Widget> children) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.accentColor.withValues(alpha: 0.04),
            border: Border.all(
              color: theme.accentColor.withValues(alpha: 0.15),
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: theme.accentColor,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        '$number',
                        style: const TextStyle(
                          color: Color(0xFFFFFFFF),
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );
    }

    final gravityTermLabel = mechType == MechanismType.arm
        ? '\n• kG · cos(θ) — gravity torque (arm, varies with angle)'
        : mechType == MechanismType.elevator
        ? '\n• kG — constant gravity compensation (elevator)'
        : '';

    return Expander(
      header: const Row(
        children: [
          Icon(FluentIcons.lightbulb, size: 14),
          SizedBox(width: 8),
          Text('Explain the Math — How Gains Were Computed'),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Step 1 — Data collection
          stepCard(1, 'Collected Data Points', [
            Text(
              'We collected $totalSamples voltage-velocity samples from '
              '$qsCount quasistatic and $dynCount dynamic test runs.',
              style: captionStyle,
            ),
            const SizedBox(height: 6),
            Text(
              'Each data point records the applied voltage (V), velocity (ω), '
              'acceleration (α = Δω/Δt), and position (θ) of the mechanism.',
              style: captionStyle,
            ),
          ]),

          // Step 2 — Physics model
          stepCard(2, 'The Physics Model', [
            Text(
              'The mechanism obeys a linear feedforward model:',
              style: captionStyle,
            ),
            const SizedBox(height: 8),
            _buildEquationRow(mechType, theme),
            const SizedBox(height: 8),
            Text(
              '• kS · sign(ω) — static friction (always opposes motion)\n'
              '• kV · ω — back-EMF (proportional to velocity)\n'
              '• kA · α — inertia (proportional to acceleration)'
              '$gravityTermLabel',
              style: captionStyle,
            ),
          ]),

          // Step 3 — Matrix equation (interactive visual)
          stepCard(3, 'Build the Matrix Equation', [
            MatrixEquationVisualizer(
              mechanismType: mechType,
              gains: ff,
              sampleRows: _gatherSampleRows(qsRuns, dynRuns),
              totalSamples: totalSamples,
            ),
          ]),

          // Step 4 — Least squares solution
          stepCard(4, 'Solve via Least Squares', [
            Text(
              'The ordinary least-squares (OLS) solution minimizes the '
              'sum of squared residuals  Σ(V_actual − V_predicted)²:',
              style: captionStyle,
            ),
            const SizedBox(height: 8),
            Text(
              '  β  =  (XᵀX)⁻¹ Xᵀ V',
              style: monoStyle.copyWith(fontSize: 13),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.accentColor.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('kS = ${ff.kS.toStringAsFixed(5)} V', style: monoStyle),
                  Text(
                    'kV = ${ff.kV.toStringAsFixed(5)} V·s/unit',
                    style: monoStyle,
                  ),
                  Text(
                    'kA = ${ff.kA.toStringAsFixed(5)} V·s²/unit',
                    style: monoStyle,
                  ),
                  if (hasGravity)
                    Text(
                      'kG = ${ff.kG.toStringAsFixed(5)} V',
                      style: monoStyle,
                    ),
                  const SizedBox(height: 4),
                  Text(
                    'R² = ${ff.rSquared.toStringAsFixed(4)}',
                    style: monoStyle.copyWith(
                      color: ff.rSquared > 0.9
                          ? Colors.successPrimaryColor
                          : Colors.warningPrimaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'R² = 1 − SS_res / SS_tot measures how much of the variance '
              'in voltage the model explains. Values above 0.9 are good; '
              'above 0.95 is excellent.',
              style: captionStyle,
            ),
          ]),
        ],
      ),
    );
  }

  /// Renders the feedforward equation styled like a math expression.
  Widget _buildEquationRow(MechanismType mechType, FluentThemeData theme) {
    final suffix = mechType == MechanismType.arm
        ? '  +  kG·cos(θ)'
        : mechType == MechanismType.elevator
        ? '  +  kG'
        : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.accentColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        'V  =  kS·sign(ω)  +  kV·ω  +  kA·α$suffix',
        style: TextStyle(
          fontFamily: 'Consolas',
          fontSize: 13,
          color: theme.accentColor,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  /// Pick a few representative data points from the test runs for the
  /// matrix equation visualizer.
  List<DataPoint>? _gatherSampleRows(
    List<TestRun> qsRuns,
    List<TestRun> dynRuns,
  ) {
    final all = <DataPoint>[];
    for (final run in [...qsRuns, ...dynRuns]) {
      for (final p in run.data) {
        if (p.velocity.abs() > 1e-4) all.add(p);
      }
    }
    if (all.length < 3) return null;
    // Spread the selection evenly across the data.
    final step = all.length ~/ 5;
    if (step < 1) return all.take(5).toList();
    return [for (var i = 0; i < all.length && i ~/ step < 5; i += step) all[i]];
  }

  void _runAnalysis(
    List<TestRun> qsRuns,
    List<TestRun> dynRuns,
    MechanismConfig config,
  ) {
    try {
      // Partition runs by load condition (arm/elevator only).
      final hasLoadTags =
          qsRuns.any((r) => r.loadCondition != null) ||
          dynRuns.any((r) => r.loadCondition != null);
      final isGravityMech =
          config.type == MechanismType.arm ||
          config.type == MechanismType.elevator;

      FeedforwardGains ff;
      FeedforwardGains? ffLoaded;
      FeedforwardGains? ffBlended;

      if (hasLoadTags && isGravityMech) {
        // Split into unloaded and loaded sets.
        final qsUnloaded = qsRuns
            .where(
              (r) =>
                  r.loadCondition == null ||
                  r.loadCondition == LoadCondition.unloaded,
            )
            .toList();
        final dynUnloaded = dynRuns
            .where(
              (r) =>
                  r.loadCondition == null ||
                  r.loadCondition == LoadCondition.unloaded,
            )
            .toList();
        final qsLoaded = qsRuns
            .where((r) => r.loadCondition == LoadCondition.loaded)
            .toList();
        final dynLoaded = dynRuns
            .where((r) => r.loadCondition == LoadCondition.loaded)
            .toList();

        // Analyze unloaded set (always available — may include legacy runs).
        ff = FeedforwardAnalyzer.analyze(
          quasistaticRuns: qsUnloaded.isNotEmpty ? qsUnloaded : qsRuns,
          dynamicRuns: dynUnloaded.isNotEmpty ? dynUnloaded : dynRuns,
          mechanismType: config.type,
        );

        // Analyze loaded set if sufficient data exists.
        if (qsLoaded.isNotEmpty && dynLoaded.isNotEmpty) {
          ffLoaded = FeedforwardAnalyzer.analyze(
            quasistaticRuns: qsLoaded,
            dynamicRuns: dynLoaded,
            mechanismType: config.type,
          );
          ffBlended = PidAutoTuner.blendFeedforward(ff, ffLoaded);
        }
      } else {
        // Single-condition analysis (legacy / flywheel / no tags).
        ff = FeedforwardAnalyzer.analyze(
          quasistaticRuns: qsRuns,
          dynamicRuns: dynRuns,
          mechanismType: config.type,
        );
      }

      // Compute and apply plant-optimal defaults.
      final primaryFF = ffBlended ?? ff;
      final (optTau, optBw) = PidAutoTuner.optimalDefaults(primaryFF);
      ref
          .read(pidTuningParamsProvider.notifier)
          .setOptimalDefaults(optTau, optBw);

      final tuningParams = ref.read(pidTuningParamsProvider);

      PidResult velPid;
      PidResult posPid;


      if (_legacyPidMode) {
        // Use legacy PID calculation for sim/legacy mode
        velPid = PidAutoTuner.tuneVelocityLegacy(
          ff: primaryFF,
          mechanismType: config.type,
          desiredTimeConstantMs: tuningParams.velocityTimeConstantMs,
        );
        posPid = PidAutoTuner.tunePositionLegacy(
          ff: primaryFF,
          mechanismType: config.type,
          desiredBandwidthHz: tuningParams.positionBandwidthHz,
          dampingRatio: tuningParams.dampingRatio,
        );
      } else if (ffLoaded != null) {
        // Robust PID: stable for both unloaded and loaded conditions.
        velPid = PidAutoTuner.tuneRobustVelocity(
          ffUnloaded: ff,
          ffLoaded: ffLoaded,
          mechanismType: config.type,
          desiredTimeConstantMs: tuningParams.velocityTimeConstantMs,
        );
        posPid = PidAutoTuner.tuneRobustPosition(
          ffUnloaded: ff,
          ffLoaded: ffLoaded,
          mechanismType: config.type,
          desiredBandwidthHz: tuningParams.positionBandwidthHz,
          dampingRatio: tuningParams.dampingRatio,
        );
      } else {
        // Single-condition PID (current behavior).
        velPid = PidAutoTuner.tuneVelocity(
          ff: primaryFF,
          mechanismType: config.type,
          desiredTimeConstantMs: tuningParams.velocityTimeConstantMs,
        );
        posPid = PidAutoTuner.tunePosition(
          ff: primaryFF,
          mechanismType: config.type,
          desiredBandwidthHz: tuningParams.positionBandwidthHz,
          dampingRatio: tuningParams.dampingRatio,
        );
      }

      setState(() {
        _ff = ff;
        _ffLoaded = ffLoaded;
        _ffBlended = ffBlended;
        _velPid = velPid;
        _posPid = posPid;
        _analyzed = true;
        _analysisError = null;
      });

      // Store in global state for other screens.
      ref.read(feedforwardGainsProvider.notifier).state = ffBlended ?? ff;
      ref.read(loadedFeedforwardGainsProvider.notifier).state = ffLoaded;
      ref.read(pidResultProvider.notifier).state = velPid;
      ref.read(posPidResultProvider.notifier).state = posPid;
    } catch (e) {
      setState(() {
        _analysisError = e.toString();
      });
    }
  }

  Future<void> _exportCsv(List<TestRun> runs) async {
    final path = await CsvExporter.exportAllRuns(runs);
    if (path != null && mounted) {
      await displayInfoBar(
        context,
        builder: (ctx, close) {
          return InfoBar(
            title: const Text('Exported'),
            content: Text('Saved to: $path'),
            severity: InfoBarSeverity.success,
            action: IconButton(
              icon: const Icon(FluentIcons.clear),
              onPressed: close,
            ),
          );
        },
      );
    }
  }

  Future<void> _exportWpiLib(List<TestRun> runs) async {
    final path = await CsvExporter.exportWpiLibFormat(runs);
    if (path != null && mounted) {
      await displayInfoBar(
        context,
        builder: (ctx, close) {
          return InfoBar(
            title: const Text('Exported'),
            content: Text('WPILib SysId JSON saved to: $path'),
            severity: InfoBarSeverity.success,
            action: IconButton(
              icon: const Icon(FluentIcons.clear),
              onPressed: close,
            ),
          );
        },
      );
    }
  }

  Future<void> _exportPdf(MechanismConfig config, List<TestRun> runs) async {
    try {
      final path = await ReportGenerator.generate(
        config: config,
        ff: _ff!,
        velocityPid: _velPid,
        positionPid: _posPid,
        testRuns: runs,
        tuningParams: ref.read(pidTuningParamsProvider),
      );
      if (path != null && mounted) {
        await displayInfoBar(
          context,
          builder: (ctx, close) {
            return InfoBar(
              title: const Text('Report saved'),
              content: Text('PDF saved to: $path'),
              severity: InfoBarSeverity.success,
              action: IconButton(
                icon: const Icon(FluentIcons.clear),
                onPressed: close,
              ),
            );
          },
        );
      }
    } catch (e) {
      if (mounted) {
        await displayInfoBar(
          context,
          builder: (ctx, close) {
            return InfoBar(
              title: const Text('Export failed'),
              content: Text('$e'),
              severity: InfoBarSeverity.error,
              action: IconButton(
                icon: const Icon(FluentIcons.clear),
                onPressed: close,
              ),
            );
          },
        );
      }
    }
  }

  Future<void> _exportNotebook(
    MechanismConfig config,
    List<TestRun> testRuns,
  ) async {
    final path = await NotebookExporter.export(
      config: config,
      ff: _ff!,
      velocityPid: _velPid,
      positionPid: _posPid,
      testRuns: testRuns,
      validationResult: ref.read(validationResultProvider),
    );
    if (path != null && mounted) {
      await displayInfoBar(
        context,
        builder: (ctx, close) {
          return InfoBar(
            title: const Text('Notebook Exported'),
            content: Text('Saved to $path'),
            severity: InfoBarSeverity.success,
            action: IconButton(
              icon: const Icon(FluentIcons.chrome_close),
              onPressed: close,
            ),
          );
        },
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _GainsTable extends StatelessWidget {
  final FeedforwardGains ff;
  final MechanismConfig config;

  const _GainsTable({required this.ff, required this.config});

  MechanismType get mechanismType => config.type;

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
    final velUnit = config.velocityUnit;

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
            '${ff.kV.toStringAsFixed(5)} V/$velUnit',
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
            '${ff.kA.toStringAsFixed(5)} V·s/$velUnit',
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

class _DualGainsTable extends StatelessWidget {
  final FeedforwardGains ffUnloaded;
  final FeedforwardGains ffLoaded;
  final FeedforwardGains ffBlended;
  final MechanismConfig config;

  const _DualGainsTable({
    required this.ffUnloaded,
    required this.ffLoaded,
    required this.ffBlended,
    required this.config,
  });

  @override
  Widget build(BuildContext context) {
    final isArm = config.type == MechanismType.arm;
    final isElevator = config.type == MechanismType.elevator;
    final velUnit = config.velocityUnit;

    Widget row(String label, double u, double l, double b, String unit) {
      final diff = u != 0 ? ((l - u).abs() / u.abs()) : 0.0;
      final highlight = diff > 0.10;
      final style = TextStyle(
        fontWeight: FontWeight.w600,
        fontFamily: 'Consolas',
        color: highlight ? Colors.warningPrimaryColor : null,
      );
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(width: 160, child: Text(label)),
            SizedBox(
              width: 140,
              child: Text('${u.toStringAsFixed(5)} $unit', style: style),
            ),
            SizedBox(
              width: 140,
              child: Text('${l.toStringAsFixed(5)} $unit', style: style),
            ),
            SizedBox(
              width: 140,
              child: Text(
                '${b.toStringAsFixed(5)} $unit',
                style: style.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                const SizedBox(
                  width: 160,
                  child: Text(
                    'Parameter',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(
                  width: 140,
                  child: Text(
                    'Unloaded',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(
                  width: 140,
                  child: Text(
                    'Loaded',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(
                  width: 140,
                  child: Text(
                    'Blended',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          row(
            'kS (Static Friction)',
            ffUnloaded.kS,
            ffLoaded.kS,
            ffBlended.kS,
            'V',
          ),
          row(
            'kV (Velocity)',
            ffUnloaded.kV,
            ffLoaded.kV,
            ffBlended.kV,
            'V/$velUnit',
          ),
          row(
            'kA (Acceleration)',
            ffUnloaded.kA,
            ffLoaded.kA,
            ffBlended.kA,
            'V·s/$velUnit',
          ),
          if (isArm || isElevator)
            row('kG (Gravity)', ffUnloaded.kG, ffLoaded.kG, ffBlended.kG, 'V'),
          const Divider(),
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Blended gains (arithmetic mean) are written to the controller. '
              'Parameters with >10% difference are highlighted.',
              style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
            ),
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

  const _GainRow(
    this.label,
    this.value, {
    this.highlight = false,
    this.tooltip,
  });

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
        child: MouseRegion(cursor: SystemMouseCursors.help, child: row),
      );
    }

    return row;
  }
}

enum _PidMode { velocity, position }

/// Preset damping options with label, value, and explanation.
class _DampingPreset {
  final String label;
  final double zeta;
  final String description;
  const _DampingPreset(this.label, this.zeta, this.description);
}

const _dampingPresets = [
  _DampingPreset(
    'Overdamped (ζ = 1.5)',
    1.5,
    'Very conservative — slow approach with no overshoot. '
        'Use when overshoot is absolutely unacceptable (e.g. elevator near hard stop).',
  ),
  _DampingPreset(
    'Critically Damped (ζ = 1.0)',
    1.0,
    'Fastest response with zero overshoot. '
        'Recommended for most FRC mechanisms. The "textbook" default.',
  ),
  _DampingPreset(
    'Butterworth (ζ ≈ 0.707)',
    0.707,
    '~4 % overshoot, maximally flat frequency response. '
        'Good for mechanisms that can tolerate a small overshoot in exchange for a faster rise time.',
  ),
  _DampingPreset(
    'Underdamped (ζ = 0.5)',
    0.5,
    '~16 % overshoot, faster rise time but oscillatory settling. '
        'Use with caution — the mechanism will ring past the setpoint.',
  ),
];

/// Dropdown + explanation shown before the Compute button.
class _DampingSelector extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final params = ref.watch(pidTuningParamsProvider);
    final theme = FluentTheme.of(context);
    // Find best-matching preset (or default to critically damped).
    final selected = _dampingPresets.firstWhere(
      (p) => (p.zeta - params.dampingRatio).abs() < 0.01,
      orElse: () => _dampingPresets[1],
    );
    final isCustom = !_dampingPresets.any(
      (p) => (p.zeta - params.dampingRatio).abs() < 0.01,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 200,
              child: Text(
                'Position damping (ζ)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: theme.typography.body?.color,
                ),
              ),
            ),
            ComboBox<double>(
              value: selected.zeta,
              items: _dampingPresets
                  .map(
                    (p) => ComboBoxItem<double>(
                      value: p.zeta,
                      child: Text(p.label),
                    ),
                  )
                  .toList(),
              onChanged: (val) {
                if (val != null) {
                  ref
                      .read(pidTuningParamsProvider.notifier)
                      .setDampingRatio(val);
                }
              },
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 120,
              child: NumberBox<double>(
                value: params.dampingRatio,
                min: 0.1,
                max: 5.0,
                smallChange: 0.1,
                mode: SpinButtonPlacementMode.inline,
                onChanged: (v) {
                  if (v != null) {
                    ref
                        .read(pidTuningParamsProvider.notifier)
                        .setDampingRatio(v);
                  }
                },
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 200, top: 4),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              isCustom
                  ? 'Custom damping ratio (ζ = ${params.dampingRatio.toStringAsFixed(1)}). '
                        'Higher values are more overdamped and conservative; lower values are faster but can ring.'
                  : selected.description,
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: theme.typography.body?.color?.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Unified panel with all three tuning knobs before the Compute button.
class _TuningParametersPanel extends ConsumerStatefulWidget {
  @override
  ConsumerState<_TuningParametersPanel> createState() =>
      _TuningParametersPanelState();
}

class _TuningParametersPanelState
    extends ConsumerState<_TuningParametersPanel> {
  late TextEditingController _tauController;
  late TextEditingController _bwController;

  @override
  void initState() {
    super.initState();
    final params = ref.read(pidTuningParamsProvider);
    _tauController = TextEditingController(
      text: params.velocityTimeConstantMs.toStringAsFixed(0),
    );
    _bwController = TextEditingController(
      text: params.positionBandwidthHz.toStringAsFixed(1),
    );
  }

  @override
  void dispose() {
    _tauController.dispose();
    _bwController.dispose();
    super.dispose();
  }

  void _onTauChanged(double value) {
    ref.read(pidTuningParamsProvider.notifier).setVelocityTimeConstant(value);
    _tauController.text = value.round().toString();
  }

  void _onBwChanged(double value) {
    ref.read(pidTuningParamsProvider.notifier).setPositionBandwidth(value);
    _bwController.text = value.toStringAsFixed(1);
  }

  void _onTauEdited(String text) {
    final val = double.tryParse(text);
    if (val != null) {
      ref.read(pidTuningParamsProvider.notifier).setVelocityTimeConstant(val);
    }
  }

  void _onBwEdited(String text) {
    final val = double.tryParse(text);
    if (val != null) {
      ref.read(pidTuningParamsProvider.notifier).setPositionBandwidth(val);
    }
  }

  @override
  Widget build(BuildContext context) {
    final params = ref.watch(pidTuningParamsProvider);
    final notifier = ref.read(pidTuningParamsProvider.notifier);
    final theme = FluentTheme.of(context);
    final isDefault = notifier.isAtDefaults;

    // Sync text controllers when state changes externally (e.g. optimal
    // defaults set after feedforward analysis).
    final tauText = params.velocityTimeConstantMs.round().toString();
    if (_tauController.text != tauText) _tauController.text = tauText;
    final bwText = params.positionBandwidthHz.toStringAsFixed(1);
    if (_bwController.text != bwText) _bwController.text = bwText;

    return Expander(
      header: Row(
        children: [
          const Icon(FluentIcons.settings, size: 14),
          const SizedBox(width: 8),
          const Text('PID Tuning Parameters'),
          if (!isDefault) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.accentColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Modified',
                style: TextStyle(fontSize: 10, color: theme.accentColor),
              ),
            ),
          ],
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'These settings shape how aggressive the auto-tuned PID is. '
            'They control the tradeoff between speed and smoothness by setting '
            'the target closed-loop behavior before gains are computed.',
            style: TextStyle(
              fontSize: 12,
              color: theme.typography.body?.color?.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),

          // ── Position damping ratio ─────────────────────────────
          _DampingSelector(),
          const SizedBox(height: 12),

          // ── Velocity time constant ─────────────────────────────
          Row(
            children: [
              SizedBox(
                width: 200,
                child: Text(
                  'Velocity time constant (τ)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: theme.typography.body?.color,
                  ),
                ),
              ),
              Expanded(
                child: Slider(
                  value: params.velocityTimeConstantMs,
                  min: 20,
                  max: 500,
                  divisions: 48,
                  label: '${params.velocityTimeConstantMs.round()} ms',
                  onChanged: _onTauChanged,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 60,
                child: TextBox(
                  controller: _tauController,
                  suffix: const Text('ms'),
                  onSubmitted: _onTauEdited,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 200),
            child: Text(
              'Smaller \u03c4 feels snappier and larger \u03c4 feels calmer. '
              'Decreasing \u03c4 raises loop aggressiveness and reduces phase margin. '
              'Current optimal baseline: ${notifier.optimalTauMs.round()} ms.',
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: theme.typography.body?.color?.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── Position bandwidth ─────────────────────────────────
          Row(
            children: [
              SizedBox(
                width: 200,
                child: Text(
                  'Position bandwidth (ω)',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: theme.typography.body?.color,
                  ),
                ),
              ),
              Expanded(
                child: Slider(
                  value: params.positionBandwidthHz,
                  min: 0.1,
                  max: 10,
                  divisions: 99,
                  label: '${params.positionBandwidthHz.toStringAsFixed(1)} Hz',
                  onChanged: _onBwChanged,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 60,
                child: TextBox(
                  controller: _bwController,
                  suffix: const Text('Hz'),
                  onSubmitted: _onBwEdited,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 200),
            child: Text(
              'Higher bandwidth tracks quicker but can ring. '
              'Increasing BW raises crossover and sensitivity to noise/resonance. '
              'Current optimal baseline: ${notifier.optimalBwHz.toStringAsFixed(1)} Hz.',
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: theme.typography.body?.color?.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(height: 16),

          if (!isDefault)
            Button(
              onPressed: () {
                ref.read(pidTuningParamsProvider.notifier).reset();
                _tauController.text = notifier.optimalTauMs.round().toString();
                _bwController.text = notifier.optimalBwHz.toStringAsFixed(1);
              },
              child: const Text('Reset to Optimal'),
            ),
        ],
      ),
    );
  }
}

class _PidCard extends StatefulWidget {
  final String title;
  final PidResult pid;
  final FeedforwardGains? ff;
  final FeedforwardGains? ffLoaded;
  final _PidMode mode;
  final MechanismConfig? config;
  final ValueChanged<double>? onAllowedErrorChanged;

  const _PidCard({
    required this.title,
    required this.pid,
    this.ff,
    this.ffLoaded,
    this.mode = _PidMode.velocity,
    this.config,
    this.onAllowedErrorChanged,
  });

  @override
  State<_PidCard> createState() => _PidCardState();
}

class _PidCardState extends State<_PidCard> {
  bool _showExplanation = false;
  late TextEditingController _allowedErrorCtrl;

  @override
  void initState() {
    super.initState();
    _allowedErrorCtrl = TextEditingController(
      text: widget.pid.allowedClosedLoopError == 0.0
          ? '0'
          : widget.pid.allowedClosedLoopError.toString(),
    );
  }

  @override
  void didUpdateWidget(covariant _PidCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pid.allowedClosedLoopError !=
        widget.pid.allowedClosedLoopError) {
      _allowedErrorCtrl.text = widget.pid.allowedClosedLoopError == 0.0
          ? '0'
          : widget.pid.allowedClosedLoopError.toString();
    }
  }

  @override
  void dispose() {
    _allowedErrorCtrl.dispose();
    super.dispose();
  }

  String get _pidUnitNote {
    final cfg = widget.config;
    if (cfg == null) return '';
    if (widget.mode == _PidMode.velocity) {
      return 'Units: duty-cycle per ${cfg.velocityUnit}';
    } else {
      return 'Units: duty-cycle per ${cfg.positionUnit}';
    }
  }

  String get _kITooltip {
    final hasRobustLoadedTune =
        widget.ff != null && widget.ffLoaded != null && widget.pid.kI > 0;
    if (hasRobustLoadedTune) {
      return widget.mode == _PidMode.velocity
          ? 'Loaded and unloaded behavior were different, so a small integral term removes leftover bias. '
            'Robust tuning detected plant/load mismatch, so a slow kI trims blended-feedforward residual without dominating transients.'
          : 'Loaded and unloaded gravity/load did not match, so a slow integral term corrects final offset after the step settles. '
            'Robust tuning adds conservative kI for steady-state bias removal while keeping PD transient shaping dominant.';
    }
    return widget.mode == _PidMode.velocity
        ? 'kI is off by default so it does not wind up. Single-condition velocity tuning relies on feedforward plus kP correction for steady-state tracking.'
        : 'kI is usually not needed for position here. Single-condition position tuning uses PD pole shaping while feedforward carries most static load/gravity demand.';
  }

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
                child: Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
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
          // Low-inertia or other auto-tuning warnings
          for (final warning in widget.pid.warnings) ...[
            InfoBar(
              title: Text(warning),
              severity: InfoBarSeverity.warning,
              isLong: true,
            ),
            const SizedBox(height: 6),
          ],
          _GainRow(
            'kP',
            widget.pid.kP.toStringAsFixed(6),
            tooltip: _pidUnitNote,
          ),
          _GainRow('kI', widget.pid.kI.toStringAsFixed(6), tooltip: _kITooltip),
          _GainRow('kD', widget.pid.kD.toStringAsFixed(6)),
          if (widget.mode == _PidMode.position && widget.pid.dFilter > 0)
            _GainRow(
              'D Filter',
              widget.pid.dFilter.toStringAsFixed(4),
              tooltip:
                  'EMA low-pass on derivative (0=off, higher=more smoothing)',
            ),
          if (widget.pid.iZone > 0)
            _GainRow(
              'I-Zone',
              widget.pid.iZone.toStringAsFixed(4),
              tooltip:
                  'Limits integral accumulation to prevent windup. '
                  'Integral only accumulates when error is within this zone.',
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: 260,
            child: InfoLabel(
              label:
                  'Allowed Closed-Loop Error'
                  '${widget.config != null ? ' (${widget.mode == _PidMode.velocity ? widget.config!.velocityUnit : widget.config!.positionUnit})' : ''}',
              child: TextBox(
                controller: _allowedErrorCtrl,
                placeholder: '0 = no dead-band',
                onChanged: (v) {
                  final val = double.tryParse(v);
                  if (val != null && val >= 0) {
                    widget.onAllowedErrorChanged?.call(val);
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'These are user-unit gains — use them directly in WPILib\n'
            'after setting your encoder\'s conversion factors.\n'
            'Feedforward gains (kS, kV, kA, kG) are configured\n'
            'separately via FeedForwardConfig on the controller.',
            style: TextStyle(
              fontSize: 11,
              color: FluentTheme.of(
                context,
              ).typography.body?.color?.withValues(alpha: 0.6),
              fontStyle: FontStyle.italic,
            ),
          ),
          if (_showExplanation && widget.ff != null)
            ..._buildExplanation(theme),
        ],
      ),
    );
  }

  List<Widget> _buildExplanation(FluentThemeData theme) {
    final ff = widget.ff!;
    final explainColor = theme.typography.body?.color?.withValues(alpha: 0.8);
    const monoStyle = TextStyle(fontFamily: 'Consolas', fontSize: 12);
    final captionStyle = TextStyle(
      fontSize: 12,
      color: explainColor,
      height: 1.5,
    );

    if (widget.mode == _PidMode.velocity) {
      final tauMs = widget.pid.velocityTimeConstantMs ?? 100.0;
      final tauS = tauMs / 1000.0;
      final isCustomTau = tauMs != 100.0;
      final hasRobustIntegral = widget.ffLoaded != null && widget.pid.kI > 0;
      if (hasRobustIntegral) {
        final ffLoaded = widget.ffLoaded!;
        final kA = math.min(ff.kA, ffLoaded.kA);
        final kV = math.max(ff.kV, ffLoaded.kV);
        final plantTau = kV > 0 ? kA / kV : 0.0;
        final ti = PidAutoTuner.robustVelocityIntegralTimeSec(
          closedLoopTauSec: tauS,
          plantTauSec: plantTau,
        );
        final deltaKG = (ffLoaded.kG - ff.kG).abs();
        return [
          const Divider(),
          const SizedBox(height: 8),
          Text(
            'How Velocity PID is derived',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.accentColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Loaded and unloaded characterization were both present, so the tuner '
            'builds a robust PI controller. kP is sized from the lighter plant '
            'so neither condition is over-driven, while kI is made intentionally '
            'slow to trim the residual blended-load mismatch.',
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
                Text(
                  'kP = (min(kA_unloaded, kA_loaded) / τ) / V_nominal',
                  style: monoStyle,
                ),
                Text(
                  '   = (${kA.toStringAsFixed(5)} / ${tauS.toStringAsFixed(3)}) / 12.0',
                  style: monoStyle,
                ),
                Text(
                  '   = ${widget.pid.kP.toStringAsFixed(6)}',
                  style: monoStyle,
                ),
                const SizedBox(height: 4),
                Text('Tᵢ = max(12·τ, 30·τ_plant)', style: monoStyle),
                Text('   = ${ti.toStringAsFixed(3)} s', style: monoStyle),
                Text('kI = kP / Tᵢ', style: monoStyle),
                Text(
                  '   = ${widget.pid.kI.toStringAsFixed(6)}',
                  style: monoStyle,
                ),
                const SizedBox(height: 4),
                Text('I-Zone = 2·ΔkG / kI', style: monoStyle),
                Text(
                  '      = ${widget.pid.iZone.toStringAsFixed(4)}   (ΔkG = ${deltaKG.toStringAsFixed(3)} V)',
                  style: monoStyle,
                ),
                Text('kD = 0', style: monoStyle),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'This integral term is only present because the blended feedforward can '
            'sit between unloaded and loaded gravity/load demand. The slower '
            'integral time constant keeps the response from overshooting while '
            'still pulling out the remaining steady-state error.',
            style: captionStyle,
          ),
        ];
      }
      return [
        const Divider(),
        const SizedBox(height: 8),
        Text(
          'How Velocity PID is derived',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: theme.accentColor,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'The motor + mechanism acts like a first-order system:\n'
          '    G(s) = 1 / (kA\u00b7s + kV)\n\n'
          'We design a PI controller using model-inversion, targeting a '
          'closed-loop time constant \u03c4 = ${tauMs.round()} ms'
          '${isCustomTau ? " (custom)" : " (default)"}:',
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
              Text(
                '   = (${ff.kA.toStringAsFixed(5)} / ${tauS.toStringAsFixed(3)}) / 12.0',
                style: monoStyle,
              ),
              Text(
                '   = ${widget.pid.kP.toStringAsFixed(6)}',
                style: monoStyle,
              ),
              const SizedBox(height: 4),
              Text('kI = 0  (avoids integral windup)', style: monoStyle),
              Text('kD = 0  (not needed for velocity)', style: monoStyle),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'kP controls how aggressively the controller corrects velocity '
          'errors. '
          '${isCustomTau ? "You chose \u03c4 = ${tauMs.round()} ms — " : ""}'
          '${tauMs < 100
              ? "faster than default (more aggressive)."
              : tauMs > 100
              ? "slower than default (more conservative)."
              : ""}'
          ' Feedforward (kS, kV) is now configured separately '
          'via the controller\u2019s FeedForwardConfig and predicts most '
          'of the output, so PID only handles small corrections.',
          style: captionStyle,
        ),
      ];
    } else {
      // Position PID
      final bwHz = widget.pid.positionBandwidthHz ?? 5.0;
      final omega = 2.0 * 3.14159265 * bwHz;
      final isCustomBw = bwHz != 5.0;
      final hasRobustIntegral = widget.ffLoaded != null && widget.pid.kI > 0;
      if (hasRobustIntegral) {
        final ffLoaded = widget.ffLoaded!;
        final kA = math.max(ff.kA, ffLoaded.kA);
        final kV = math.max(ff.kV, ffLoaded.kV);
        final plantTau = kV > 0 ? kA / kV : 0.0;
        final ti = PidAutoTuner.robustPositionIntegralTimeSec(
          omegaRadPerSec: omega,
          plantTauSec: plantTau,
        );
        final deltaKG = (ffLoaded.kG - ff.kG).abs();
        return [
          const Divider(),
          const SizedBox(height: 8),
          Text(
            'How Position PID is derived',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.accentColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Loaded and unloaded characterization were both present, so the tuner '
            'builds a robust PID controller. kP and kD are sized from the heavier '
            'plant for conservative transient behavior, then a slow integral term '
            'is added only to trim the residual blended-load bias.',
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
                Text(
                  'kP = (max(kA_unloaded, kA_loaded) · ω²) / V_nominal',
                  style: monoStyle,
                ),
                Text(
                  '   = (${kA.toStringAsFixed(5)} · ${omega.toStringAsFixed(1)}²) / 12.0',
                  style: monoStyle,
                ),
                Text(
                  '   = ${widget.pid.kP.toStringAsFixed(6)}',
                  style: monoStyle,
                ),
                const SizedBox(height: 4),
                Text('kD = (2·ζ·kA·ω − max(kV)) / V_nominal', style: monoStyle),
                Text(
                  '   = ${widget.pid.kD.toStringAsFixed(6)}',
                  style: monoStyle,
                ),
                const SizedBox(height: 4),
                Text('Tᵢ = max(8/ω, 20·τ_plant)', style: monoStyle),
                Text('   = ${ti.toStringAsFixed(3)} s', style: monoStyle),
                Text('kI = kP / Tᵢ', style: monoStyle),
                Text(
                  '   = ${widget.pid.kI.toStringAsFixed(6)}',
                  style: monoStyle,
                ),
                const SizedBox(height: 4),
                Text('I-Zone = ΔkG / kI', style: monoStyle),
                Text(
                  '      = ${widget.pid.iZone.toStringAsFixed(4)}   (ΔkG = ${deltaKG.toStringAsFixed(3)} V)',
                  style: monoStyle,
                ),
                if (widget.pid.dFilter > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    'D Filter = ${widget.pid.dFilter.toStringAsFixed(4)}',
                    style: monoStyle,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'The PD portion still shapes the step response. Integral is slowed down '
            'on purpose so it removes the remaining loaded-vs-unloaded bias '
            'without causing the overshoot and lazy return that a large kI would create.',
            style: captionStyle,
          ),
        ];
      }
      return [
        const Divider(),
        const SizedBox(height: 8),
        Text(
          'How Position PID is derived',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: theme.accentColor,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'The motor + mechanism from voltage to position is a '
          'second-order system:\n'
          '    G(s) = 1 / (kA\u00b7s\u00b2 + kV\u00b7s)\n\n'
          'We use pole placement for a critically-damped response '
          'at ${bwHz.toStringAsFixed(1)} Hz bandwidth '
          '(\u03c9 = ${omega.toStringAsFixed(1)} rad/s)'
          '${isCustomBw ? " (custom)" : " (default)"}:',
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
              Text(
                'kP = (kA \u00b7 \u03c9\u00b2) / V_nominal',
                style: monoStyle,
              ),
              Text(
                '   = (${ff.kA.toStringAsFixed(5)} \u00b7 ${omega.toStringAsFixed(1)}\u00b2) / 12.0',
                style: monoStyle,
              ),
              Text(
                '   = ${widget.pid.kP.toStringAsFixed(6)}',
                style: monoStyle,
              ),
              const SizedBox(height: 4),
              Text(
                'kD = (2\u00b7kA\u00b7\u03c9 \u2212 kV) / V_nominal',
                style: monoStyle,
              ),
              Text(
                '   = (2\u00b7${ff.kA.toStringAsFixed(5)}\u00b7${omega.toStringAsFixed(1)} \u2212 ${ff.kV.toStringAsFixed(5)}) / 12.0',
                style: monoStyle,
              ),
              Text(
                '   = ${widget.pid.kD.toStringAsFixed(6)}  ${widget.pid.kD == 0 ? "(clamped \u2265 0)" : ""}',
                style: monoStyle,
              ),
              const SizedBox(height: 4),
              Text('kI = 0  (not needed for position)', style: monoStyle),
              if (widget.pid.dFilter > 0) ...[
                const SizedBox(height: 4),
                Text(
                  'D Filter = 1 / (1 + 2\u03c0 \u00b7 8 \u00b7 BW \u00b7 T\u209b)',
                  style: monoStyle,
                ),
                Text(
                  '        = ${widget.pid.dFilter.toStringAsFixed(4)}  (EMA \u03b1 on derivative)',
                  style: monoStyle,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'kP creates a restoring force proportional to position error. '
          'kD provides damping (like shock absorbers) to prevent oscillation. '
          'The "2\u00b7kA\u00b7\u03c9 \u2212 kV" subtracts the system\u2019s '
          'natural damping (kV) so we don\u2019t over-damp.'
          '${isCustomBw ? " Bandwidth set to ${bwHz.toStringAsFixed(1)} Hz" : ""}'
          '${isCustomBw && bwHz > 5
              ? " (faster than default)."
              : isCustomBw && bwHz < 5
              ? " (slower than default)."
              : ""}',
          style: captionStyle,
        ),
      ];
    }
  }
}

class _ModelFitPlot extends StatefulWidget {
  final List<TestRun> testRuns;
  final FeedforwardGains ff;
  final MechanismType mechanismType;

  const _ModelFitPlot({
    required this.testRuns,
    required this.ff,
    required this.mechanismType,
  });

  @override
  State<_ModelFitPlot> createState() => _ModelFitPlotState();
}

class _ModelFitPlotState extends State<_ModelFitPlot> {
  bool _walkthroughActive = false;

  /// Compute the model-predicted voltage for a single data point.
  double _predictVoltage(DataPoint dp, DataPoint? prev) {
    final vel = dp.velocity;
    final signVel = vel > 0 ? 1.0 : -1.0;
    double accel = 0.0;
    if (prev != null) {
      final dt = dp.timestamp - prev.timestamp;
      if (dt > 0) accel = (dp.velocity - prev.velocity) / dt;
    }
    double gravity = 0.0;
    if (widget.mechanismType == MechanismType.arm) {
      gravity = math.cos(dp.position * math.pi / 180.0);
    } else if (widget.mechanismType == MechanismType.elevator) {
      gravity = 1.0;
    }
    return widget.ff.kS * signVel +
        widget.ff.kV * vel +
        widget.ff.kA * accel +
        widget.ff.kG * gravity;
  }

  @override
  Widget build(BuildContext context) {
    final hasGravity = widget.mechanismType.hasGravity;

    // Build scatter: predicted voltage vs actual voltage,
    // separated by test type for distinct coloring.
    final qsSpots = <FlSpot>[];
    final dynSpots = <FlSpot>[];
    for (final run in widget.testRuns) {
      final data = run.data;
      final isQs = run.testType.isQuasistatic;
      for (var i = 0; i < data.length; i++) {
        final dp = data[i];
        if (dp.velocity.abs() < 1e-6) continue;
        final prev = i > 0 ? data[i - 1] : null;
        final predicted = _predictVoltage(dp, prev);
        (isQs ? qsSpots : dynSpots).add(FlSpot(predicted, dp.voltage));
      }
    }

    final allSpots = [...qsSpots, ...dynSpots];
    if (allSpots.isEmpty) {
      return const Card(child: Center(child: Text('No data')));
    }

    // Range for the y=x reference line
    final allVals = allSpots.expand((s) => [s.x, s.y]);
    final lo = allVals.reduce((a, b) => a < b ? a : b);
    final hi = allVals.reduce((a, b) => a > b ? a : b);
    final margin = (hi - lo) * 0.05;
    final lineMin = lo - margin;
    final lineMax = hi + margin;

    final chartTitle = hasGravity
        ? 'Predicted vs Actual Voltage (Full Model)'
        : 'Predicted vs Actual Voltage';

    final chart = Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  chartTitle,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              WalkthroughToggle(
                isActive: _walkthroughActive,
                onToggle: () =>
                    setState(() => _walkthroughActive = !_walkthroughActive),
              ),
            ],
          ),
          // Legend
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF4488DD),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                const Text('Quasistatic', style: TextStyle(fontSize: 9)),
                const SizedBox(width: 10),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: Colors.orange,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 4),
                const Text('Dynamic', style: TextStyle(fontSize: 9)),
                const SizedBox(width: 10),
                Container(
                  width: 12,
                  height: 2,
                  color: Colors.successPrimaryColor,
                ),
                const SizedBox(width: 4),
                const Text('Perfect fit', style: TextStyle(fontSize: 9)),
              ],
            ),
          ),
          Expanded(
            child: LineChart(
              LineChartData(
                lineTouchData: LineTouchData(
                  enabled: !_walkthroughActive,
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipItems: (touchedSpots) {
                      return touchedSpots.map((spot) {
                        if (spot.barIndex <= 1) {
                          final label = spot.barIndex == 0 ? 'QS' : 'Dyn';
                          return LineTooltipItem(
                            '$label — Pred: ${spot.x.toStringAsFixed(2)} V\n'
                            'Actual: ${spot.y.toStringAsFixed(2)} V',
                            const TextStyle(fontSize: 11),
                          );
                        }
                        return null;
                      }).toList();
                    },
                  ),
                ),
                lineBarsData: [
                  // Quasistatic scatter (blue)
                  if (qsSpots.isNotEmpty)
                    LineChartBarData(
                      spots: qsSpots,
                      isCurved: false,
                      color: const Color(0xFF4488DD).withValues(alpha: 0.3),
                      barWidth: 0,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, data, barData, index) =>
                            FlDotCirclePainter(
                              radius: 1.5,
                              color: const Color(0xFF4488DD),
                              strokeWidth: 0,
                            ),
                      ),
                    ),
                  // Dynamic scatter (orange)
                  if (dynSpots.isNotEmpty)
                    LineChartBarData(
                      spots: dynSpots,
                      isCurved: false,
                      color: Colors.orange.withValues(alpha: 0.25),
                      barWidth: 0,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, data, barData, index) =>
                            FlDotCirclePainter(
                              radius: 1.5,
                              color: Colors.orange,
                              strokeWidth: 0,
                            ),
                      ),
                    ),
                  // Perfect fit reference line (y = x)
                  LineChartBarData(
                    spots: [FlSpot(lineMin, lineMin), FlSpot(lineMax, lineMax)],
                    isCurved: false,
                    color: Colors.successPrimaryColor,
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                    dashArray: [6, 3],
                  ),
                ],
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  bottomTitles: AxisTitles(
                    axisNameWidget: Text(
                      hasGravity ? 'Predicted Voltage (V)' : 'Velocity',
                      style: const TextStyle(fontSize: 10),
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
                    axisNameWidget: const Text(
                      'Actual Voltage (V)',
                      style: TextStyle(fontSize: 10),
                    ),
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
      steps: hasGravity
          ? _gravityModelWalkthroughSteps(
              ff: widget.ff,
              mechanismType: widget.mechanismType,
            )
          : voltageVelocityWalkthroughSteps(
              kS: widget.ff.kS,
              kV: widget.ff.kV,
              rSquared: widget.ff.rSquared,
            ),
      onDismiss: () => setState(() => _walkthroughActive = false),
      child: chart,
    );
  }

  static List<WalkthroughStep> _gravityModelWalkthroughSteps({
    required FeedforwardGains ff,
    required MechanismType mechanismType,
  }) {
    final gravityDesc = mechanismType == MechanismType.arm
        ? 'kG\u00b7cos(\u03b8) — the torque needed to hold the arm '
              'against gravity varies with angle'
        : 'kG — a constant voltage offset to hold the elevator '
              'against gravity';

    return [
      const WalkthroughStep(
        title: 'What is this chart?',
        description:
            'This is a predicted-vs-actual voltage plot. Each dot compares '
            'the voltage the MODEL predicts is needed vs the voltage that '
            'was ACTUALLY applied at that instant.\n\n'
            'If the model were perfect, every dot would sit on the '
            'dashed green diagonal line (predicted = actual).',
        icon: FluentIcons.chart,
      ),
      WalkthroughStep(
        title: 'The Full Model',
        description:
            'The complete feedforward model is:\n\n'
            '  V = kS\u00b7sign(\u03c9) + kV\u00b7\u03c9 + kA\u00b7\u03b1 + $gravityDesc\n\n'
            'A simple voltage-vs-velocity line can\u2019t show the gravity '
            'term, which is why we plot predicted vs actual instead.',
        icon: FluentIcons.variable_group,
      ),
      WalkthroughStep(
        title: 'R\u00b2 — Goodness of Fit',
        description:
            'R\u00b2 = ${ff.rSquared.toStringAsFixed(4)}.\n\n'
            'Points tightly clustered around the diagonal = high R\u00b2 '
            '(good fit). Widely scattered = low R\u00b2.\n\n'
            'R\u00b2 > 0.95 = excellent\n'
            'R\u00b2 > 0.90 = good\n'
            'R\u00b2 < 0.80 = check your configuration',
        icon: FluentIcons.check_mark,
      ),
      WalkthroughStep(
        title: 'Gravity Compensation',
        description:
            'kG = ${ff.kG.toStringAsFixed(4)} V.\n\n'
            '$gravityDesc.\n\n'
            'Without kG, all the gravity-related scatter would pull the '
            'points off the diagonal.',
        icon: FluentIcons.globe2,
      ),
      WalkthroughStep(
        title: 'What to look for',
        description:
            'A good fit shows a tight cloud along the diagonal.\n\n'
            'If you see a curved band the model may be missing a '
            'non-linearity. If there\u2019s an offset, check your '
            'motor inversion or zero offset.\n\n'
            'Outliers far from the line may indicate binding or '
            'intermittent faults.',
        icon: FluentIcons.search,
      ),
    ];
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
      lineBars.add(
        LineChartBarData(
          spots: spots,
          isCurved: false,
          color: _runColors[i % _runColors.length],
          barWidth: 1.5,
          dotData: const FlDotData(show: false),
        ),
      );
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
                child: Text(
                  'Step Response (Dynamic)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
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
                    axisNameWidget: const Text(
                      'Velocity',
                      style: TextStyle(fontSize: 10),
                    ),
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
