/// Interactive Plant Model Visualizer screen.
///
/// Lets students adjust feedforward constants (kS, kV, kA, kG) via sliders
/// and instantly see the simulated step response for flywheel, arm, or
/// elevator mechanisms.  Three charts display velocity, position, and
/// voltage vs time.  No hardware connection is required — the existing
/// physics engines are instantiated directly with slider values.
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../mechanisms/mechanism.dart';
import '../../simulation/flywheel_physics.dart';
import '../../simulation/arm_physics.dart';
import '../../simulation/elevator_physics.dart';
import '../widgets/chart_walkthrough.dart';

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

/// A single simulation sample for charting.
class SimSample {
  final double time;
  final double velocity;
  final double position;
  final double voltage;

  const SimSample({
    required this.time,
    required this.velocity,
    required this.position,
    required this.voltage,
  });
}

/// Default feedforward constants per mechanism type.
class _Defaults {
  final double kS, kV, kA, kG;

  const _Defaults({
    required this.kS,
    required this.kV,
    required this.kA,
    required this.kG,
  });

  static const flywheel = _Defaults(kS: 0.14, kV: 0.0185, kA: 0.003, kG: 0.0);
  static const arm = _Defaults(kS: 0.20, kV: 0.018, kA: 0.002, kG: 0.80);
  static const elevator =
      _Defaults(kS: 0.18, kV: 0.12, kA: 0.015, kG: 0.55);
  static const simple = _Defaults(kS: 0.14, kV: 0.0185, kA: 0.003, kG: 0.0);

  static _Defaults forMechanism(MechanismType type) => switch (type) {
        MechanismType.flywheel => flywheel,
        MechanismType.arm => arm,
        MechanismType.elevator => elevator,
        MechanismType.simple => simple,
      };
}

/// Slider range for each feedforward parameter.
class _SliderRange {
  final double min, max;
  const _SliderRange(this.min, this.max);
}

// ---------------------------------------------------------------------------
// Simulation runner (pure function, no state)
// ---------------------------------------------------------------------------

/// Run a step-voltage simulation and return sampled data.
///
/// Instantiates the appropriate physics model with the given constants,
/// applies [stepVoltage] at t=0, and steps at 1 kHz for [durationS] seconds.
/// Returns one [SimSample] every [outputDtS] seconds for chart efficiency.
List<SimSample> runStepResponse({
  required MechanismType mechanism,
  required double kS,
  required double kV,
  required double kA,
  required double kG,
  required double stepVoltage,
  required double durationS,
  double simDtS = 0.001,
  double outputDtS = 0.005,
}) {
  // Guard against degenerate inputs.
  if (kA <= 0 || kV <= 0 || durationS <= 0) return [];

  // Instantiate the chosen physics model with no noise.
  late final dynamic physics;
  switch (mechanism) {
    case MechanismType.flywheel:
      physics = FlywheelPhysics(kS: kS, kV: kV, kA: kA, noiseLevel: 0);
    case MechanismType.arm:
      physics = ArmPhysics(kS: kS, kV: kV, kA: kA, kG: kG, noiseLevel: 0);
    case MechanismType.elevator:
      physics = ElevatorPhysics(kS: kS, kV: kV, kA: kA, kG: kG, noiseLevel: 0);
    case MechanismType.simple:
      physics = FlywheelPhysics(kS: kS, kV: kV, kA: kA, noiseLevel: 0);
  }

  physics.reset();

  final samples = <SimSample>[];
  final totalSteps = (durationS / simDtS).ceil();
  final outputEvery = (outputDtS / simDtS).round().clamp(1, totalSteps);

  for (var i = 0; i <= totalSteps; i++) {
    final t = i * simDtS;

    if (i % outputEvery == 0) {
      samples.add(SimSample(
        time: t,
        velocity: physics.noisyVelocityRpm,
        position: physics.noisyPositionRotations,
        voltage: physics.commandedVoltage as double,
      ));
    }

    physics.step(stepVoltage, simDtS);
  }

  return samples;
}

// ---------------------------------------------------------------------------
// Velocity units helper
// ---------------------------------------------------------------------------

String _velocityUnit(MechanismType m) => switch (m) {
      MechanismType.flywheel => 'RPM',
      MechanismType.arm => 'RPM',
      MechanismType.elevator => 'RPM',
      MechanismType.simple => 'RPM',
    };

String _positionUnit(MechanismType m) => switch (m) {
      MechanismType.flywheel => 'rot',
      MechanismType.arm => 'rot',
      MechanismType.elevator => 'rot',
      MechanismType.simple => 'rot',
    };

// ---------------------------------------------------------------------------
// Screen widget
// ---------------------------------------------------------------------------

/// Interactive Plant Model Visualizer.
class PlantVisualizerScreen extends ConsumerStatefulWidget {
  const PlantVisualizerScreen({super.key});

  @override
  ConsumerState<PlantVisualizerScreen> createState() =>
      _PlantVisualizerScreenState();
}

class _PlantVisualizerScreenState
    extends ConsumerState<PlantVisualizerScreen> {
  // -- Slider state --
  MechanismType _mechanism = MechanismType.flywheel;
  double _kS = _Defaults.flywheel.kS;
  double _kV = _Defaults.flywheel.kV;
  double _kA = _Defaults.flywheel.kA;
  double _kG = _Defaults.flywheel.kG;
  double _stepVoltage = 6.0;
  double _durationS = 3.0;

  // -- Comparison state --
  bool _compareMode = false;
  List<SimSample>? _frozenSamples;
  String _frozenLabel = '';

  // -- Walkthrough state --
  bool _showWalkthrough = false;

  // -- Computed data --
  List<SimSample> _samples = [];

  @override
  void initState() {
    super.initState();
    _recompute();
  }

  void _recompute() {
    _samples = runStepResponse(
      mechanism: _mechanism,
      kS: _kS,
      kV: _kV,
      kA: _kA,
      kG: _kG,
      stepVoltage: _stepVoltage,
      durationS: _durationS,
    );
  }

  void _resetToDefaults() {
    final d = _Defaults.forMechanism(_mechanism);
    setState(() {
      _kS = d.kS;
      _kV = d.kV;
      _kA = d.kA;
      _kG = d.kG;
      _recompute();
    });
  }

  void _switchMechanism(MechanismType type) {
    final d = _Defaults.forMechanism(type);
    setState(() {
      _mechanism = type;
      _kS = d.kS;
      _kV = d.kV;
      _kA = d.kA;
      _kG = d.kG;
      _frozenSamples = null;
      _compareMode = false;
      _recompute();
    });
  }

  void _toggleCompare() {
    setState(() {
      if (!_compareMode) {
        // Freeze the current curve.
        _frozenSamples = List.of(_samples);
        _frozenLabel =
            'kS=${_kS.toStringAsFixed(3)}, kV=${_kV.toStringAsFixed(4)}, '
            'kA=${_kA.toStringAsFixed(4)}'
            '${_mechanism.hasGravity ? ', kG=${_kG.toStringAsFixed(3)}' : ''}';
        _compareMode = true;
      } else {
        _frozenSamples = null;
        _compareMode = false;
      }
    });
  }

  // -- Slider ranges per mechanism --
  _SliderRange get _kSRange => const _SliderRange(0.0, 1.0);
  _SliderRange get _kVRange => switch (_mechanism) {
        MechanismType.flywheel => const _SliderRange(0.001, 0.10),
        MechanismType.arm => const _SliderRange(0.001, 0.10),
        MechanismType.elevator => const _SliderRange(0.01, 0.50),
        MechanismType.simple => const _SliderRange(0.001, 0.10),
      };
  _SliderRange get _kARange => switch (_mechanism) {
        MechanismType.flywheel => const _SliderRange(0.0005, 0.02),
        MechanismType.arm => const _SliderRange(0.0005, 0.02),
        MechanismType.elevator => const _SliderRange(0.001, 0.10),
        MechanismType.simple => const _SliderRange(0.0005, 0.02),
      };
  _SliderRange get _kGRange => const _SliderRange(0.0, 2.0);

  // =========================================================================
  // Build
  // =========================================================================

  @override
  Widget build(BuildContext context) {
    return ScaffoldPage.scrollable(
      header: PageHeader(
        title: const Text('Plant Model Visualizer'),
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: _compareMode
                  ? 'Clear frozen comparison curve'
                  : 'Freeze current curve for comparison',
              child: ToggleButton(
                checked: _compareMode,
                onChanged: (_) => _toggleCompare(),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_compareMode
                        ? FluentIcons.clear
                        : FluentIcons.copy),
                    const SizedBox(width: 6),
                    Text(_compareMode ? 'Clear Compare' : 'Compare'),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: 'Show educational walkthrough for the step response',
              child: IconButton(
                icon: const Icon(FluentIcons.education),
                onPressed: () =>
                    setState(() => _showWalkthrough = !_showWalkthrough),
              ),
            ),
          ],
        ),
      ),
      children: [
        // ---------------------------------------------------------------
        // Block diagram
        // ---------------------------------------------------------------
        _buildBlockDiagram(context),
        const SizedBox(height: 12),

        // ---------------------------------------------------------------
        // Controls row: mechanism selector + sliders + step config
        // ---------------------------------------------------------------
        _buildControls(context),
        const SizedBox(height: 16),

        // ---------------------------------------------------------------
        // Charts
        // ---------------------------------------------------------------
        SizedBox(
          height: 280,
          child: _buildChart(
            title: 'Velocity',
            yLabel: _velocityUnit(_mechanism),
            extractor: (s) => s.velocity,
            color: Colors.blue,
            frozenExtractor:
                _frozenSamples != null ? (s) => s.velocity : null,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 240,
          child: _buildChart(
            title: 'Position',
            yLabel: _positionUnit(_mechanism),
            extractor: (s) => s.position,
            color: Colors.teal,
            frozenExtractor:
                _frozenSamples != null ? (s) => s.position : null,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: _buildChart(
            title: 'Applied Voltage',
            yLabel: 'V',
            extractor: (s) => s.voltage,
            color: Colors.orange.normal,
            frozenExtractor:
                _frozenSamples != null ? (s) => s.voltage : null,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // =========================================================================
  // Block diagram
  // =========================================================================

  Widget _buildBlockDiagram(BuildContext context) {
    final theme = FluentTheme.of(context);
    final boxDeco = BoxDecoration(
      border: Border.all(
        color: theme.accentColor,
        width: 1.5,
      ),
      borderRadius: BorderRadius.circular(6),
    );

    Widget box(String text, {bool wide = false}) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: BoxConstraints(minWidth: wide ? 200 : 60),
        decoration: boxDeco,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: theme.accentColor,
          ),
        ),
      );
    }

    Widget arrow() {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Icon(FluentIcons.forward, size: 14, color: theme.accentColor),
      );
    }

    final equation = switch (_mechanism) {
      MechanismType.flywheel =>
        'V = kS·sign(ω) + kV·ω + kA·α',
      MechanismType.arm =>
        'V = kS·sign(ω) + kG·cos(θ) + kV·ω + kA·α',
      MechanismType.elevator =>
        'V = kS·sign(v) + kG + kV·v + kA·a',
      MechanismType.simple =>
        'V = kS·sign(ω) + kV·ω + kA·α',
    };

    return Card(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          // Visual block diagram
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                box('Step Voltage\n${_stepVoltage.toStringAsFixed(1)} V'),
                arrow(),
                box(equation, wide: true),
                arrow(),
                box(_mechanism == MechanismType.elevator
                    ? 'Velocity (v)\nPosition (x)'
                    : 'Velocity (ω)\nPosition (θ)'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Steady-state annotation
          _buildSteadyStateAnnotation(context),
        ],
      ),
    );
  }

  Widget _buildSteadyStateAnnotation(BuildContext context) {
    // For a flywheel: V_ss = kS + kV * ω_ss  →  ω_ss = (V - kS) / kV
    // For an elevator: V_ss = kS + kG + kV * v_ss  →  v_ss = (V - kS - kG) / kV
    // For an arm at θ=0: V_ss = kS + kG*cos(0) + kV * ω_ss
    //   → ω_ss = (V - kS - kG) / kV

    final gravity = _mechanism == MechanismType.flywheel ? 0.0 : _kG;
    final netVoltage = _stepVoltage - _kS - gravity;
    final steadyState = netVoltage > 0 && _kV > 0 ? netVoltage / _kV : 0.0;
    final timeConstant = _kV > 0 ? _kA / _kV : 0.0;

    final velUnit = _mechanism == MechanismType.flywheel ? 'RPM' : 'units/s';

    return Row(
      children: [
        const Icon(FluentIcons.info, size: 12),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Predicted steady-state velocity ≈ '
            '${steadyState.toStringAsFixed(1)} $velUnit'
            '  •  Time constant τ = kA/kV ≈ '
            '${timeConstant.toStringAsFixed(3)} s'
            '${_stepVoltage <= _kS + gravity ? '  ⚠ Step voltage is below deadband (kS${gravity > 0 ? ' + kG' : ''})' : ''}',
            style: const TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }

  // =========================================================================
  // Controls panel
  // =========================================================================

  Widget _buildControls(BuildContext context) {
    return Card(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // -- Row 1: Mechanism selector + reset button --
          Row(
            children: [
              const Text('Mechanism:',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              RadioGroup<MechanismType>(
                groupValue: _mechanism,
                onChanged: (value) {
                  if (value != null) _switchMechanism(value);
                },
                child: Row(
                  children: MechanismType.values.map((type) => Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: RadioButton<MechanismType>(
                          value: type,
                          content: Text(type.displayName),
                        ),
                      )).toList(),
                ),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _resetToDefaults,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.reset, size: 12),
                    SizedBox(width: 6),
                    Text('Reset to Defaults'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // -- Row 2: FF constant sliders --
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _buildSlider(
                label: 'kS (friction)',
                value: _kS,
                range: _kSRange,
                decimals: 3,
                onChanged: (v) => setState(() {
                  _kS = v;
                  _recompute();
                }),
              ),
              _buildSlider(
                label: 'kV (velocity)',
                value: _kV,
                range: _kVRange,
                decimals: 4,
                onChanged: (v) => setState(() {
                  _kV = v;
                  _recompute();
                }),
              ),
              _buildSlider(
                label: 'kA (accel)',
                value: _kA,
                range: _kARange,
                decimals: 4,
                onChanged: (v) => setState(() {
                  _kA = v;
                  _recompute();
                }),
              ),
              if (_mechanism.hasGravity)
                _buildSlider(
                  label: 'kG (gravity)',
                  value: _kG,
                  range: _kGRange,
                  decimals: 3,
                  onChanged: (v) => setState(() {
                    _kG = v;
                    _recompute();
                  }),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // -- Row 3: Step voltage & duration --
          Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              _buildSlider(
                label: 'Step Voltage',
                value: _stepVoltage,
                range: const _SliderRange(-12.0, 12.0),
                decimals: 1,
                suffix: ' V',
                onChanged: (v) => setState(() {
                  _stepVoltage = v;
                  _recompute();
                }),
              ),
              _buildSlider(
                label: 'Duration',
                value: _durationS,
                range: const _SliderRange(0.5, 10.0),
                decimals: 1,
                suffix: ' s',
                onChanged: (v) => setState(() {
                  _durationS = v;
                  _recompute();
                }),
              ),
            ],
          ),

          // -- Compare legend --
          if (_compareMode && _frozenLabel.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Container(width: 16, height: 2, color: Colors.grey[100]),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Frozen: $_frozenLabel',
                    style: TextStyle(fontSize: 10, color: Colors.grey[100]),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Build a labeled horizontal slider with a numeric readout.
  Widget _buildSlider({
    required String label,
    required double value,
    required _SliderRange range,
    required int decimals,
    required ValueChanged<double> onChanged,
    String suffix = '',
  }) {
    return SizedBox(
      width: 260,
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(range.min, range.max),
              min: range.min,
              max: range.max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 70,
            child: Text(
              '${value.toStringAsFixed(decimals)}$suffix',
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // Charts
  // =========================================================================

  Widget _buildChart({
    required String title,
    required String yLabel,
    required double Function(SimSample) extractor,
    required Color color,
    double Function(SimSample)? frozenExtractor,
  }) {
    final spots = _samples
        .map((s) => FlSpot(s.time, extractor(s)))
        .toList();

    final lineBars = <LineChartBarData>[];

    // Frozen comparison curve (dashed, grey).
    if (_compareMode && _frozenSamples != null && frozenExtractor != null) {
      lineBars.add(LineChartBarData(
        spots: _frozenSamples!
            .map((s) => FlSpot(s.time, frozenExtractor(s)))
            .toList(),
        isCurved: false,
        color: Colors.grey[100],
        barWidth: 1.5,
        dotData: const FlDotData(show: false),
        dashArray: [6, 3],
      ));
    }

    // Active curve (solid).
    if (spots.isNotEmpty) {
      lineBars.add(LineChartBarData(
        spots: spots,
        isCurved: false,
        color: color,
        barWidth: 2,
        dotData: const FlDotData(show: false),
      ));
    }

    final chart = Card(
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
              if (_compareMode) ...[
                const Spacer(),
                Container(
                    width: 12,
                    height: 2,
                    color: Colors.grey[100]),
                const SizedBox(width: 3),
                Text('Frozen',
                    style: TextStyle(fontSize: 9, color: Colors.grey[100])),
                const SizedBox(width: 8),
                Container(width: 12, height: 2, color: color),
                const SizedBox(width: 3),
                const Text('Current', style: TextStyle(fontSize: 9)),
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
                      maxX: _durationS,
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipItems: (touchedSpots) {
                            return touchedSpots.map((spot) {
                              final label = (_compareMode &&
                                      spot.barIndex == 0)
                                  ? 'Frozen'
                                  : 'Current';
                              return LineTooltipItem(
                                '$label: ${spot.y.toStringAsFixed(2)} $yLabel\n'
                                't=${spot.x.toStringAsFixed(2)}s',
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
                          axisNameWidget: Text(yLabel,
                              style: const TextStyle(fontSize: 10)),
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 50,
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

    // Wrap velocity chart in an optional walkthrough overlay.
    if (title == 'Velocity' && _showWalkthrough) {
      return ChartWalkthrough(
        isActive: true,
        steps: _walkthroughSteps(),
        onDismiss: () => setState(() => _showWalkthrough = false),
        child: chart,
      );
    }

    return chart;
  }

  // =========================================================================
  // Walkthrough steps
  // =========================================================================

  List<WalkthroughStep> _walkthroughSteps() {
    final gravity = _mechanism == MechanismType.flywheel ? 0.0 : _kG;
    final netV = _stepVoltage - _kS - gravity;
    final steadyState = netV > 0 && _kV > 0 ? netV / _kV : 0.0;
    final tau = _kV > 0 ? _kA / _kV : 0.0;

    return [
      const WalkthroughStep(
        title: 'What is a Step Response?',
        description:
            'This chart shows what happens when you instantly apply a constant '
            'voltage to your motor. The velocity climbs from zero toward a '
            'steady-state value.  This is the most important test for '
            'understanding your system.',
        icon: FluentIcons.chart,
      ),
      WalkthroughStep(
        title: 'kS — Deadband / Static Friction',
        description:
            'kS = ${_kS.toStringAsFixed(3)} V.  '
            'This is the minimum voltage to START moving. If your step '
            'voltage is below kS${gravity > 0 ? ' + kG' : ''}, the motor '
            'won\'t move at all.\n\n'
            'Try increasing kS and watch the steady-state velocity drop '
            '(more voltage is "wasted" on friction).',
        icon: FluentIcons.pinned,
      ),
      WalkthroughStep(
        title: 'kV — Velocity Constant',
        description:
            'kV = ${_kV.toStringAsFixed(4)}.  '
            'This is the slope of the voltage-vs-velocity relationship.  '
            'It determines the STEADY-STATE speed:\n\n'
            '    ω_ss = (V - kS${gravity > 0 ? ' - kG' : ''}) / kV '
            '≈ ${steadyState.toStringAsFixed(1)}\n\n'
            'A higher kV means the motor reaches a LOWER top speed for '
            'the same voltage.',
        icon: FluentIcons.up,
      ),
      WalkthroughStep(
        title: 'kA — Time Constant',
        description:
            'kA = ${_kA.toStringAsFixed(4)}.  '
            'This controls HOW FAST velocity reaches steady state.\n\n'
            'The time constant is τ = kA / kV ≈ '
            '${tau.toStringAsFixed(3)} s.\n\n'
            'After about 3τ ≈ ${(3 * tau).toStringAsFixed(2)} s, the motor '
            'is at ~95% of its final speed.  Try increasing kA and watch '
            'the rise become slower.',
        icon: FluentIcons.timer,
      ),
      if (_mechanism.hasGravity)
        WalkthroughStep(
          title: 'kG — Gravity Compensation',
          description:
              'kG = ${_kG.toStringAsFixed(3)} V.  '
              'This is the voltage needed to hold the mechanism against '
              'gravity.  '
              '${_mechanism == MechanismType.arm ? 'For an arm, it varies as cos(θ).' : 'For an elevator, it\'s constant.'}\n\n'
              'kG "uses up" some of your step voltage, so the motor '
              'reaches a lower steady-state speed.  Try setting kG to 0 '
              'and watch the speed increase.',
          icon: FluentIcons.down,
        ),
      const WalkthroughStep(
        title: 'What to do with these constants',
        description:
            'These constants go into your robot code\'s feedforward '
            'controller.  When you command a velocity, the feedforward '
            'calculates the voltage to get CLOSE to the target speed.  '
            'Then PID makes fine corrections.\n\n'
            'Good feedforward = the motor responds instantly and '
            'predictably.  That\'s what system identification is all about!',
        icon: FluentIcons.rocket,
      ),
    ];
  }
}
