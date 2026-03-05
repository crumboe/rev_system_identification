/// Results screen: display computed feedforward & PID gains, diagnostic
/// plots, and export options.
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../data/test_data.dart';
import '../../data/csv_exporter.dart';
import '../../data/report_generator.dart';
import '../../mechanisms/mechanism.dart';
import '../../state/app_state.dart';
import '../../sysid/feedforward_analyzer.dart';
import '../../sysid/pid_autotuner.dart';
import '../widgets/bode_plot.dart';
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
            CommandBarButton(
              icon: const Icon(FluentIcons.print),
              label: const Text('Export PDF Report'),
              onPressed: _ff != null
                  ? () => _exportPdf(config, testRuns)
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
                  canAnalyze ? () => _runAnalysis(qsRuns, dynRuns, config,
                      tuningParams: ref.read(pidTuningParamsProvider)) : null,
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
          _GainsTable(ff: _ff!, config: config),

          const SizedBox(height: 24),

          // PID gains
          const Text(
            'PID Gains (Auto-Tuned)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),

          // Advanced PID tuning parameters
          _PidTuningPanel(
            onRetune: _ff != null
                ? () => _runAnalysis(qsRuns, dynRuns, config,
                    tuningParams: ref.read(pidTuningParamsProvider))
                : null,
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
                  config: config,
                )),
              const SizedBox(width: 12),
              if (_posPid != null)
                Expanded(child: _PidCard(
                  title: 'Position PID',
                  pid: _posPid!,
                  ff: _ff,
                  mode: _PidMode.position,
                  config: config,
                )),
            ],
          ),

          const SizedBox(height: 16),

          // Write to controller buttons
          if (ref.read(deviceManagerProvider).leader != null)
            Row(
              children: [
                FilledButton(
                  onPressed: () => _writeGainsToController(
                    ref, config.type, _WriteMode.velocity),
                  child: const Text('Write Velocity Gains'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: () => _writeGainsToController(
                    ref, config.type, _WriteMode.position),
                  child: const Text('Write Position Gains'),
                ),
              ],
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
                Expanded(
                  child: _StepResponsePlot(testRuns: dynRuns),
                ),
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
    MechanismConfig config, {
    PidTuningParams tuningParams = const PidTuningParams(),
  }) {
    try {
      final ff = FeedforwardAnalyzer.analyze(
        quasistaticRuns: qsRuns,
        dynamicRuns: dynRuns,
        mechanismType: config.type,
      );

      final velPid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: config.type,
        desiredTimeConstantMs: tuningParams.velocityTimeConstantMs,
      );

      final posPid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: config.type,
        desiredBandwidthHz: tuningParams.positionBandwidthHz,
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
      ref.read(posPidResultProvider.notifier).state = posPid;
    } catch (e) {
      setState(() {
        _analysisError = e.toString();
      });
    }
  }

  Future<void> _writeGainsToController(
    WidgetRef ref, MechanismType mechType, _WriteMode writeMode,
  ) async {
    final device = ref.read(deviceManagerProvider).leader;
    final config = ref.read(mechanismConfigProvider);
    if (device == null || _ff == null) return;

    // Conversion factors scale user-unit gains → native controller units.
    // The SPARK CAN protocol always uses RPM for velocity setpoints and
    // rotations for position setpoints.  All stored gains from the regression
    // are in user units, so they must be scaled before being written.
    final vcf = config.velocityConversionFactor; // user_vel per RPM
    final pcf = config.positionConversionFactor; // user_pos per rotation

    try {
      if (writeMode == _WriteMode.velocity && _velPid != null) {
        // Write velocity PID gains (kP, kI, kD) to Slot 0, scaled to native
        // RPM units.  kP_native = kP_user × VCF (error in RPM → duty cycle).
        await device.parameters.setPidSlot0(
          p: _velPid!.kP * vcf,
          i: _velPid!.kI * vcf,
          d: _velPid!.kD * vcf,
          f: 0.0,
        );
      } else if (writeMode == _WriteMode.position && _posPid != null) {
        // Write position PID gains to Slot 0, scaled to native rotation
        // units.  kP_native = kP_user × PCF (error in rotations → duty cycle).
        await device.parameters.setPidSlot0(
          p: _posPid!.kP * pcf,
          i: _posPid!.kI * pcf,
          d: _posPid!.kD * pcf,
          f: 0.0,
        );
      } else {
        return;
      }

      // Write feedforward gains to Slot 0 FeedForwardConfig.
      // kV and kA are scaled by VCF to convert V/(user_vel) → V/RPM.
      // kS, kG, kCos are in Volts — no scaling needed.
      double kG = 0.0;
      double kCos = 0.0;
      // kCosRatio converts encoder rotations to the correct angle for the
      // cosine gravity term: cos(posRot × kCosRatio × 2π).
      // We need kCosRatio such that posRot × kCosRatio × 2π = angleDeg × π/180,
      // i.e. kCosRatio = PCF / 360.
      double kCosRatio = 0.0;

      if (mechType == MechanismType.elevator) {
        kG = _ff!.kG;
      } else if (mechType == MechanismType.arm) {
        kCos = _ff!.kG; // sysid kG maps to kCos for arms
        kCosRatio = pcf / 360.0;
      }

      await device.parameters.setFeedForwardSlot0(
        kS: _ff!.kS,
        kV: _ff!.kV * vcf,
        kA: _ff!.kA * vcf,
        kG: kG,
        kCos: kCos,
        kCosRatio: kCosRatio,
      );

      await device.parameters.burnFlash();

      if (mounted) {
        final modeLabel = writeMode == _WriteMode.velocity
            ? 'Velocity' : 'Position';
        await displayInfoBar(context, builder: (ctx, close) {
          return InfoBar(
            title: const Text('Success'),
            content: Text(
              '$modeLabel PID + FeedForward gains written to controller and saved to flash.',
            ),
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
            content: Text('Failed to write gains: $e'),
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

  Future<void> _exportPdf(
      MechanismConfig config, List<TestRun> runs) async {
    try {
      final path = await ReportGenerator.generate(
        config: config,
        ff: _ff!,
        velocityPid: _velPid,
        positionPid: _posPid,
        testRuns: runs,
      );
      if (path != null && mounted) {
        await displayInfoBar(context, builder: (ctx, close) {
          return InfoBar(
            title: const Text('Report saved'),
            content: Text('PDF saved to: $path'),
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
            title: const Text('Export failed'),
            content: Text('$e'),
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
enum _WriteMode { velocity, position }

/// Collapsible panel for advanced PID tuning parameters.
class _PidTuningPanel extends ConsumerStatefulWidget {
  final VoidCallback? onRetune;

  const _PidTuningPanel({this.onRetune});

  @override
  ConsumerState<_PidTuningPanel> createState() => _PidTuningPanelState();
}

class _PidTuningPanelState extends ConsumerState<_PidTuningPanel> {
  late TextEditingController _tauController;
  late TextEditingController _bwController;
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    final params = ref.read(pidTuningParamsProvider);
    _tauController =
        TextEditingController(text: params.velocityTimeConstantMs.toStringAsFixed(0));
    _bwController =
        TextEditingController(text: params.positionBandwidthHz.toStringAsFixed(1));
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
    final theme = FluentTheme.of(context);
    final isDefault = params.velocityTimeConstantMs == 100.0 &&
        params.positionBandwidthHz == 5.0;

    return Expander(
      initiallyExpanded: _expanded,
      onStateChanged: (open) => setState(() => _expanded = open),
      header: Row(
        children: [
          const Icon(FluentIcons.settings, size: 14),
          const SizedBox(width: 8),
          const Text('Advanced PID Tuning Parameters'),
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
            'Adjust these parameters to control how aggressively the '
            'auto-tuned PID gains respond. Changing these values requires '
            're-computing the PID gains.',
            style: TextStyle(
              fontSize: 12,
              color: theme.typography.body?.color?.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),

          // Velocity time constant
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
                  label:
                      '${params.velocityTimeConstantMs.round()} ms',
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
              'Smaller → faster velocity response, less stability margin. '
              'Default: 100 ms.',
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: theme.typography.body?.color?.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Position bandwidth
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
                  min: 1,
                  max: 20,
                  divisions: 38,
                  label:
                      '${params.positionBandwidthHz.toStringAsFixed(1)} Hz',
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
              'Higher → faster position response, more sensitive to noise. '
              'Default: 5.0 Hz.',
              style: TextStyle(
                fontSize: 11,
                fontStyle: FontStyle.italic,
                color: theme.typography.body?.color?.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              FilledButton(
                onPressed: widget.onRetune,
                child: const Text('Re-compute PID Gains'),
              ),
              const SizedBox(width: 12),
              if (!isDefault)
                Button(
                  onPressed: () {
                    ref.read(pidTuningParamsProvider.notifier).reset();
                    final defaults = const PidTuningParams();
                    _tauController.text =
                        defaults.velocityTimeConstantMs.toStringAsFixed(0);
                    _bwController.text =
                        defaults.positionBandwidthHz.toStringAsFixed(1);
                  },
                  child: const Text('Reset to Defaults'),
                ),
            ],
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
  final _PidMode mode;
  final MechanismConfig? config;

  const _PidCard({
    required this.title,
    required this.pid,
    this.ff,
    this.mode = _PidMode.velocity,
    this.config,
  });

  @override
  State<_PidCard> createState() => _PidCardState();
}

class _PidCardState extends State<_PidCard> {
  bool _showExplanation = false;

  String get _pidUnitNote {
    final cfg = widget.config;
    if (cfg == null) return '';
    if (widget.mode == _PidMode.velocity) {
      return 'Units: duty-cycle per ${cfg.velocityUnit}';
    } else {
      return 'Units: duty-cycle per ${cfg.positionUnit}';
    }
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
          _GainRow('kP', widget.pid.kP.toStringAsFixed(6),
            tooltip: _pidUnitNote),
          _GainRow('kI', widget.pid.kI.toStringAsFixed(6)),
          _GainRow('kD', widget.pid.kD.toStringAsFixed(6)),
          const SizedBox(height: 4),
          Text(
            'These are user-unit gains — use them directly in WPILib\n'
            'after setting your encoder\'s conversion factors.\n'
            'Feedforward gains (kS, kV, kA, kG) are configured\n'
            'separately via FeedForwardConfig on the controller.',
            style: TextStyle(
              fontSize: 11,
              color: FluentTheme.of(context).typography.body?.color
                  ?.withValues(alpha: 0.6),
              fontStyle: FontStyle.italic,
            ),
          ),
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
      final tauMs = widget.pid.velocityTimeConstantMs ?? 100.0;
      final tauS = tauMs / 1000.0;
      final isCustomTau = tauMs != 100.0;
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
              Text('   = (${ff.kA.toStringAsFixed(5)} / ${tauS.toStringAsFixed(3)}) / 12.0', style: monoStyle),
              Text('   = ${widget.pid.kP.toStringAsFixed(6)}', style: monoStyle),
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
          '${tauMs < 100 ? "faster than default (more aggressive)." : tauMs > 100 ? "slower than default (more conservative)." : ""}'
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
              Text('kP = (kA \u00b7 \u03c9\u00b2) / V_nominal', style: monoStyle),
              Text('   = (${ff.kA.toStringAsFixed(5)} \u00b7 ${omega.toStringAsFixed(1)}\u00b2) / 12.0', style: monoStyle),
              Text('   = ${widget.pid.kP.toStringAsFixed(6)}', style: monoStyle),
              const SizedBox(height: 4),
              Text('kD = (2\u00b7kA\u00b7\u03c9 \u2212 kV) / V_nominal', style: monoStyle),
              Text('   = (2\u00b7${ff.kA.toStringAsFixed(5)}\u00b7${omega.toStringAsFixed(1)} \u2212 ${ff.kV.toStringAsFixed(5)}) / 12.0', style: monoStyle),
              Text('   = ${widget.pid.kD.toStringAsFixed(6)}  ${widget.pid.kD == 0 ? "(clamped \u2265 0)" : ""}', style: monoStyle),
              const SizedBox(height: 4),
              Text('kI = 0  (not needed for position)', style: monoStyle),
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
          '${isCustomBw && bwHz > 5 ? " (faster than default)." : isCustomBw && bwHz < 5 ? " (slower than default)." : ""}',
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
                child: Text(chartTitle,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
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
                Container(width: 8, height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF4488DD), shape: BoxShape.circle)),
                const SizedBox(width: 4),
                const Text('Quasistatic', style: TextStyle(fontSize: 9)),
                const SizedBox(width: 10),
                Container(width: 8, height: 8,
                    decoration: BoxDecoration(
                      color: Colors.orange, shape: BoxShape.circle)),
                const SizedBox(width: 4),
                const Text('Dynamic', style: TextStyle(fontSize: 9)),
                const SizedBox(width: 10),
                Container(width: 12, height: 2,
                    color: Colors.successPrimaryColor),
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
                          final label = spot.barIndex == 0
                              ? 'QS' : 'Dyn';
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
                    spots: [
                      FlSpot(lineMin, lineMin),
                      FlSpot(lineMax, lineMax),
                    ],
                    isCurved: false,
                    color: Colors.successPrimaryColor,
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                    dashArray: [6, 3],
                  ),
                ],
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    axisNameWidget: Text(
                        hasGravity ? 'Predicted Voltage (V)' : 'Velocity',
                        style: const TextStyle(fontSize: 10)),
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
                    axisNameWidget: const Text('Actual Voltage (V)',
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
                gridData:
                    const FlGridData(show: true, drawVerticalLine: false),
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
