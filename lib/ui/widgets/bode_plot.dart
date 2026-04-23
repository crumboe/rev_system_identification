/// Bode Plot widget: displays magnitude and phase frequency response
/// for the identified plant model with optional PID controller overlay.
///
/// Shows open-loop plant G(s), open-loop with controller L(s) = C(s)·G(s),
/// closed-loop T(s) = L/(1+L), gain/phase margins, and bandwidth.
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../data/test_data.dart';
import 'chart_walkthrough.dart';
import 'chart_annotations.dart';

// ──────────────────────────────────────────────────────────────────────
// Data model
// ──────────────────────────────────────────────────────────────────────

/// Whether to show velocity (1st-order) or position (2nd-order) Bode plot.
enum BodePlotMode { velocity, position }

/// A single frequency-domain sample.
class FrequencyResponse {
  final double omegaRadPerSec;
  final double magnitudeDb;
  final double phaseDeg;

  const FrequencyResponse({
    required this.omegaRadPerSec,
    required this.magnitudeDb,
    required this.phaseDeg,
  });
}

/// Stability margins computed from the open-loop response L(jω).
class StabilityMargins {
  /// Gain margin in dB (positive = stable).
  final double gainMarginDb;

  /// Frequency (rad/s) where phase crosses −180° (phase crossover).
  final double gainMarginFreq;

  /// Phase margin in degrees (positive = stable).
  final double phaseMarginDeg;

  /// Frequency (rad/s) where |L| crosses 0 dB (gain crossover).
  final double phaseMarginFreq;

  /// Closed-loop −3 dB bandwidth (rad/s).
  final double bandwidthRadPerSec;

  const StabilityMargins({
    required this.gainMarginDb,
    required this.gainMarginFreq,
    required this.phaseMarginDeg,
    required this.phaseMarginFreq,
    required this.bandwidthRadPerSec,
  });
}

// ──────────────────────────────────────────────────────────────────────
// Complex number helpers (minimal, avoids dart:complex dep)
// ──────────────────────────────────────────────────────────────────────

class _C {
  final double re, im;
  const _C(this.re, this.im);
  _C operator +(_C o) => _C(re + o.re, im + o.im);
  _C operator -(_C o) => _C(re - o.re, im - o.im);
  _C operator *(_C o) =>
      _C(re * o.re - im * o.im, re * o.im + im * o.re);
  _C operator /(_C o) {
    final d = o.re * o.re + o.im * o.im;
    return _C((re * o.re + im * o.im) / d, (im * o.re - re * o.im) / d);
  }
  double get mag => math.sqrt(re * re + im * im);
  double get phaseDeg => math.atan2(im, re) * 180.0 / math.pi;
  static _C fromReal(double r) => _C(r, 0);
}

// ──────────────────────────────────────────────────────────────────────
// Transfer function evaluation
// ──────────────────────────────────────────────────────────────────────

const double _nominalVoltage = 12.0;

/// Evaluate the plant G(jω).
_C _plantAt(double omega, double kV, double kA, BodePlotMode mode) {
  final s = _C(0, omega);
  switch (mode) {
    case BodePlotMode.velocity:
      // G_v(s) = 1 / (kA·s + kV)
      return _C.fromReal(1.0) / (_C.fromReal(kA) * s + _C.fromReal(kV));
    case BodePlotMode.position:
      // G_p(s) = 1 / (kA·s² + kV·s)
      return _C.fromReal(1.0) /
          (_C.fromReal(kA) * s * s + _C.fromReal(kV) * s);
  }
}

/// Evaluate PID controller C(jω).
/// C(s) = kP + kI/s + kD·s
/// The gains stored in PidResult are already in duty-cycle-per-unit form.
/// Multiply by nominalVoltage to get back to voltage units (matching G(s)).
_C _controllerAt(double omega, PidResult pid) {
  final s = _C(0, omega);
  var c = _C.fromReal(pid.kP * _nominalVoltage);
  if (pid.kI != 0) {
    c = c + _C.fromReal(pid.kI * _nominalVoltage) / s;
  }
  if (pid.kD != 0) {
    c = c + _C.fromReal(pid.kD * _nominalVoltage) * s;
  }
  return c;
}

/// Compute frequency response arrays + stability margins.
///
/// Returns (plantResponse, openLoopResponse, closedLoopResponse, margins).
///
/// [transportDelaySec] adds a first-order Padé approximation of the
/// measurement delay `e^{-sT}` to the plant, capturing the phase lag
/// introduced by encoder velocity filtering and other pipeline delays.
({
  List<FrequencyResponse> plant,
  List<FrequencyResponse> openLoop,
  List<FrequencyResponse> closedLoop,
  StabilityMargins margins,
}) computeBodeData({
  required FeedforwardGains ff,
  required PidResult pid,
  required BodePlotMode mode,
  double transportDelaySec = 0.0,
  double omegaMin = 0.1,
  double omegaMax = 1000.0,
  int numPoints = 500,
}) {
  final plant = <FrequencyResponse>[];
  final openLoop = <FrequencyResponse>[];
  final closedLoop = <FrequencyResponse>[];

  final logMin = math.log(omegaMin) / math.ln10;
  final logMax = math.log(omegaMax) / math.ln10;

  // For margin detection we track crossover data.
  double prevOpenMagDb = double.nan;
  double prevOpenPhaseDeg = double.nan;
  double prevOmega = 0;

  // Crossover tracking
  double gainCrossoverFreq = double.nan;
  double phaseAtGainCrossover = double.nan;
  double phaseCrossoverFreq = double.nan;
  double magAtPhaseCrossover = double.nan;
  double bandwidthFreq = double.nan;

  for (var i = 0; i < numPoints; i++) {
    final logOmega = logMin + (logMax - logMin) * i / (numPoints - 1);
    final omega = math.pow(10, logOmega).toDouble();

    // Plant
    final gPlant = _plantAt(omega, ff.kV, ff.kA, mode);
    // Apply first-order Padé approximation of transport delay:
    // e^{-sT} ≈ (1 - sT/2) / (1 + sT/2),  s = jω
    final gVal = transportDelaySec <= 0
        ? gPlant
        : () {
            final h = transportDelaySec / 2.0;
            final joh = _C(0, omega * h);
            final pade =
                (_C.fromReal(1.0) - joh) / (_C.fromReal(1.0) + joh);
            return gPlant * pade;
          }();
    plant.add(FrequencyResponse(
      omegaRadPerSec: omega,
      magnitudeDb: 20.0 * math.log(gVal.mag) / math.ln10,
      phaseDeg: gVal.phaseDeg,
    ));

    // Open-loop L(jω) = C(jω) · G(jω)
    final cVal = _controllerAt(omega, pid);
    final lVal = cVal * gVal;
    final lMagDb = 20.0 * math.log(lVal.mag) / math.ln10;
    var lPhaseDeg = lVal.phaseDeg;

    // Unwrap phase for position mode (starts near -180° due to integrator)
    if (mode == BodePlotMode.position && lPhaseDeg > 0) {
      lPhaseDeg -= 360.0;
    }

    openLoop.add(FrequencyResponse(
      omegaRadPerSec: omega,
      magnitudeDb: lMagDb,
      phaseDeg: lPhaseDeg,
    ));

    // Closed-loop T(jω) = L / (1 + L)
    final one = _C.fromReal(1.0);
    final tVal = lVal / (one + lVal);
    final tMagDb = 20.0 * math.log(tVal.mag) / math.ln10;
    closedLoop.add(FrequencyResponse(
      omegaRadPerSec: omega,
      magnitudeDb: tMagDb,
      phaseDeg: tVal.phaseDeg,
    ));

    // Detect gain crossover: |L| crosses 0 dB from above
    if (!prevOpenMagDb.isNaN && prevOpenMagDb >= 0 && lMagDb < 0) {
      // Linear interpolation
      final frac = prevOpenMagDb / (prevOpenMagDb - lMagDb);
      gainCrossoverFreq =
          prevOmega * math.pow(omega / prevOmega, frac);
      phaseAtGainCrossover =
          prevOpenPhaseDeg + frac * (lPhaseDeg - prevOpenPhaseDeg);
    }

    // Detect phase crossover: phase crosses −180° from above
    if (!prevOpenPhaseDeg.isNaN &&
        prevOpenPhaseDeg > -180.0 &&
        lPhaseDeg <= -180.0) {
      final frac =
          (prevOpenPhaseDeg + 180.0) / (prevOpenPhaseDeg - lPhaseDeg);
      phaseCrossoverFreq =
          prevOmega * math.pow(omega / prevOmega, frac);
      magAtPhaseCrossover =
          prevOpenMagDb + frac * (lMagDb - prevOpenMagDb);
    }

    // Detect −3 dB bandwidth of closed-loop
    if (bandwidthFreq.isNaN && tMagDb < -3.0 && i > 0) {
      final prevTDb = closedLoop[i - 1].magnitudeDb;
      if (prevTDb >= -3.0) {
        final frac = (prevTDb + 3.0) / (prevTDb - tMagDb);
        final prevOm = closedLoop[i - 1].omegaRadPerSec;
        bandwidthFreq = prevOm * math.pow(omega / prevOm, frac);
      }
    }

    prevOpenMagDb = lMagDb;
    prevOpenPhaseDeg = lPhaseDeg;
    prevOmega = omega;
  }

  // Compute margins
  final gainMarginDb =
      magAtPhaseCrossover.isNaN ? double.infinity : -magAtPhaseCrossover;
  final phaseMarginDeg =
      phaseAtGainCrossover.isNaN ? double.infinity : phaseAtGainCrossover + 180.0;

  final margins = StabilityMargins(
    gainMarginDb: gainMarginDb,
    gainMarginFreq: phaseCrossoverFreq.isNaN ? 0 : phaseCrossoverFreq,
    phaseMarginDeg: phaseMarginDeg,
    phaseMarginFreq: gainCrossoverFreq.isNaN ? 0 : gainCrossoverFreq,
    bandwidthRadPerSec: bandwidthFreq.isNaN ? 0 : bandwidthFreq,
  );

  return (
    plant: plant,
    openLoop: openLoop,
    closedLoop: closedLoop,
    margins: margins,
  );
}

// ──────────────────────────────────────────────────────────────────────
// Widget
// ──────────────────────────────────────────────────────────────────────

class BodePlot extends StatefulWidget {
  final FeedforwardGains ff;
  final PidResult? velPid;
  final PidResult? posPid;

  /// Transport delay (seconds) to include in the frequency response.
  /// Encoder filter delay + pipeline delay should be summed here.
  final double transportDelaySec;

  /// When non-null, overrides the internal mode state.
  final BodePlotMode? mode;

  /// Called when the user changes the mode selector.
  final ValueChanged<BodePlotMode>? onModeChanged;

  const BodePlot({
    super.key,
    required this.ff,
    this.velPid,
    this.posPid,
    this.transportDelaySec = 0.0,
    this.mode,
    this.onModeChanged,
  });

  @override
  State<BodePlot> createState() => _BodePlotState();
}

class _BodePlotState extends State<BodePlot> {
  BodePlotMode _localMode = BodePlotMode.velocity;
  bool _showPlant = true;
  bool _showOpenLoop = true;
  bool _showClosedLoop = true;
  bool _walkthroughActive = false;

  BodePlotMode get _mode => widget.mode ?? _localMode;

  PidResult? get _activePid =>
      _mode == BodePlotMode.velocity ? widget.velPid : widget.posPid;

  @override
  Widget build(BuildContext context) {
    final pid = _activePid;
    final hasPid = pid != null && (pid.kP != 0 || pid.kD != 0);

    // If there's no PID for the selected mode, show plant-only
    final data = hasPid
        ? computeBodeData(
            ff: widget.ff,
            pid: pid,
            mode: _mode,
            transportDelaySec: widget.transportDelaySec,
          )
        : null;

    // Always compute plant-only response
    final plantOnly = computeBodeData(
      ff: widget.ff,
      pid: const PidResult(kP: 0),
      mode: _mode,
      transportDelaySec: widget.transportDelaySec,
    );

    final chart = Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              const Icon(FluentIcons.chart_series, size: 16),
              const SizedBox(width: 8),
              const Text(
                'Bode Plot — Frequency Response',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              WalkthroughToggle(
                isActive: _walkthroughActive,
                onToggle: () =>
                    setState(() => _walkthroughActive = !_walkthroughActive),
              ),
              const SizedBox(width: 8),
              // Mode selector
              if (widget.velPid != null || widget.posPid != null)
                ComboBox<BodePlotMode>(
                  value: _mode,
                  items: [
                    if (widget.velPid != null)
                      const ComboBoxItem<BodePlotMode>(
                        value: BodePlotMode.velocity,
                        child: Text('Velocity Loop'),
                      ),
                    if (widget.posPid != null)
                      const ComboBoxItem<BodePlotMode>(
                        value: BodePlotMode.position,
                        child: Text('Position Loop'),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _localMode = v);
                      widget.onModeChanged?.call(v);
                    }
                  },
                ),
            ],
          ),
          const SizedBox(height: 4),

          // Legend / toggles
          _buildLegend(hasPid),
          const SizedBox(height: 8),

          // Margins info bar
          if (hasPid && data != null) _buildMarginsBanner(data.margins),

          // Charts
          Expanded(
            child: Row(
              children: [
                // Magnitude plot
                Expanded(
                  child: _MagnitudePlot(
                    plantData: plantOnly.plant,
                    openLoopData: data?.openLoop,
                    closedLoopData: data?.closedLoop,
                    margins: data?.margins,
                    showPlant: _showPlant,
                    showOpenLoop: _showOpenLoop && hasPid,
                    showClosedLoop: _showClosedLoop && hasPid,
                  ),
                ),
                const SizedBox(width: 8),
                // Phase plot
                Expanded(
                  child: _PhasePlot(
                    plantData: plantOnly.plant,
                    openLoopData: data?.openLoop,
                    showPlant: _showPlant,
                    showOpenLoop: _showOpenLoop && hasPid,
                    margins: data?.margins,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return ChartWalkthrough(
      isActive: _walkthroughActive,
      steps: bodeWalkthroughSteps(
        mode: _mode,
        ff: widget.ff,
        margins: data?.margins,
      ),
      onDismiss: () => setState(() => _walkthroughActive = false),
      child: chart,
    );
  }

  Widget _buildLegend(bool hasPid) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          _legendItem(
            color: _plantColor,
            label: 'Plant G(s)',
            active: _showPlant,
            onTap: () => setState(() => _showPlant = !_showPlant),
          ),
          const SizedBox(width: 16),
          if (hasPid) ...[
            _legendItem(
              color: _openLoopColor,
              label: 'Open-Loop L(s)',
              active: _showOpenLoop,
              onTap: () => setState(() => _showOpenLoop = !_showOpenLoop),
            ),
            const SizedBox(width: 16),
            _legendItem(
              color: _closedLoopColor,
              label: 'Closed-Loop T(s)',
              active: _showClosedLoop,
              onTap: () =>
                  setState(() => _showClosedLoop = !_showClosedLoop),
            ),
          ],
        ],
      ),
    );
  }

  Widget _legendItem({
    required Color color,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 3,
            decoration: BoxDecoration(
              color: active ? color : color.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: active ? null : const Color(0xFF888888),
              decoration: active ? null : TextDecoration.lineThrough,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMarginsBanner(StabilityMargins m) {
    final gm = m.gainMarginDb.isInfinite
        ? 'inf'
        : '${m.gainMarginDb.toStringAsFixed(1)} dB';
    final pm = m.phaseMarginDeg.isInfinite
        ? 'inf'
        : '${m.phaseMarginDeg.toStringAsFixed(1)} deg';
    final bw = m.bandwidthRadPerSec > 0
        ? '${(m.bandwidthRadPerSec / (2 * math.pi)).toStringAsFixed(1)} Hz'
        : '--';

    final stable = (m.gainMarginDb.isInfinite || m.gainMarginDb > 0) &&
        (m.phaseMarginDeg.isInfinite || m.phaseMarginDeg > 0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InfoBar(
        title: Text(stable ? 'Stable' : 'Unstable'),
        content: Text(
          'Gain Margin: $gm  |  Phase Margin: $pm  |  Bandwidth: $bw',
        ),
        severity:
            stable ? InfoBarSeverity.success : InfoBarSeverity.error,
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────
// Colors
// ──────────────────────────────────────────────────────────────────────

const _plantColor = Color(0xFF4488DD);
const _openLoopColor = Color(0xFFDD8844);
const _closedLoopColor = Color(0xFF44BB88);
const _annotationColor = Color(0xFFCC4444);

// ──────────────────────────────────────────────────────────────────────
// Magnitude chart
// ──────────────────────────────────────────────────────────────────────

class _MagnitudePlot extends StatelessWidget {
  final List<FrequencyResponse> plantData;
  final List<FrequencyResponse>? openLoopData;
  final List<FrequencyResponse>? closedLoopData;
  final StabilityMargins? margins;
  final bool showPlant;
  final bool showOpenLoop;
  final bool showClosedLoop;

  const _MagnitudePlot({
    required this.plantData,
    this.openLoopData,
    this.closedLoopData,
    this.margins,
    this.showPlant = true,
    this.showOpenLoop = true,
    this.showClosedLoop = true,
  });

  @override
  Widget build(BuildContext context) {
    final bars = <LineChartBarData>[];

    if (showPlant) {
      bars.add(_lineBar(plantData, _plantColor, dashArray: [4, 3]));
    }
    if (showOpenLoop && openLoopData != null) {
      bars.add(_lineBar(openLoopData!, _openLoopColor));
    }
    if (showClosedLoop && closedLoopData != null) {
      bars.add(_lineBar(closedLoopData!, _closedLoopColor));
    }

    // 0 dB reference line
    if (plantData.isNotEmpty) {
      final logMin = _log10(plantData.first.omegaRadPerSec / (2 * math.pi));
      final logMax = _log10(plantData.last.omegaRadPerSec / (2 * math.pi));
      bars.add(LineChartBarData(
        spots: [FlSpot(logMin, 0), FlSpot(logMax, 0)],
        isCurved: false,
        color: const Color(0xFF666666),
        barWidth: 0.5,
        dotData: const FlDotData(show: false),
        dashArray: [3, 3],
      ));
    }

    // Annotate gain margin (vertical line at phase crossover freq)
    if (margins != null && margins!.gainMarginFreq > 0 && !margins!.gainMarginDb.isInfinite) {
      final logF = _log10(margins!.gainMarginFreq / (2 * math.pi));
      bars.add(LineChartBarData(
        spots: [FlSpot(logF, -margins!.gainMarginDb), FlSpot(logF, 0)],
        isCurved: false,
        color: _annotationColor,
        barWidth: 2,
        dotData: const FlDotData(show: false),
      ));
    }

    // Annotate bandwidth (-3 dB horizontal line intersection)
    if (margins != null && margins!.bandwidthRadPerSec > 0 && closedLoopData != null && showClosedLoop) {
      final logMin = _log10(plantData.first.omegaRadPerSec / (2 * math.pi));
      final logBw = _log10(margins!.bandwidthRadPerSec / (2 * math.pi));
      bars.add(LineChartBarData(
        spots: [FlSpot(logMin, -3), FlSpot(logBw, -3)],
        isCurved: false,
        color: _annotationColor.withValues(alpha: 0.5),
        barWidth: 1,
        dotData: const FlDotData(show: false),
        dashArray: [3, 2],
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Magnitude (dB)',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Expanded(
          child: LineChart(
            LineChartData(
              lineBarsData: bars,
              titlesData: _buildTitles('Frequency (Hz)', 'dB'),
              gridData: const FlGridData(
                  show: true, drawVerticalLine: true),
              borderData: FlBorderData(show: false),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => spots.map((s) {
                    final freq = math.pow(10, s.x);
                    return LineTooltipItem(
                      '${freq.toStringAsFixed(1)} Hz\n${s.y.toStringAsFixed(1)} dB',
                      const TextStyle(fontSize: 10),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────
// Phase chart
// ──────────────────────────────────────────────────────────────────────

class _PhasePlot extends StatelessWidget {
  final List<FrequencyResponse> plantData;
  final List<FrequencyResponse>? openLoopData;
  final bool showPlant;
  final bool showOpenLoop;
  final StabilityMargins? margins;

  const _PhasePlot({
    required this.plantData,
    this.openLoopData,
    this.showPlant = true,
    this.showOpenLoop = true,
    this.margins,
  });

  @override
  Widget build(BuildContext context) {
    final bars = <LineChartBarData>[];

    if (showPlant) {
      bars.add(_phaseLineBar(plantData, _plantColor, dashArray: [4, 3]));
    }
    if (showOpenLoop && openLoopData != null) {
      bars.add(_phaseLineBar(openLoopData!, _openLoopColor));
    }

    // −180° reference line
    if (plantData.isNotEmpty) {
      final logMin = _log10(plantData.first.omegaRadPerSec / (2 * math.pi));
      final logMax = _log10(plantData.last.omegaRadPerSec / (2 * math.pi));
      bars.add(LineChartBarData(
        spots: [FlSpot(logMin, -180), FlSpot(logMax, -180)],
        isCurved: false,
        color: const Color(0xFF666666),
        barWidth: 0.5,
        dotData: const FlDotData(show: false),
        dashArray: [3, 3],
      ));
    }

    // Annotate phase margin (arc at gain crossover freq)
    if (margins != null && margins!.phaseMarginFreq > 0 && !margins!.phaseMarginDeg.isInfinite) {
      final logF = _log10(margins!.phaseMarginFreq / (2 * math.pi));
      final phaseAtCross = -180.0 + margins!.phaseMarginDeg;
      bars.add(LineChartBarData(
        spots: [FlSpot(logF, -180), FlSpot(logF, phaseAtCross)],
        isCurved: false,
        color: _annotationColor,
        barWidth: 2,
        dotData: const FlDotData(show: false),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Phase (°)',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Expanded(
          child: LineChart(
            LineChartData(
              lineBarsData: bars,
              titlesData: _buildTitles('Frequency (Hz)', '°'),
              gridData: const FlGridData(
                  show: true, drawVerticalLine: true),
              borderData: FlBorderData(show: false),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => spots.map((s) {
                    final freq = math.pow(10, s.x);
                    return LineTooltipItem(
                      '${freq.toStringAsFixed(1)} Hz\n${s.y.toStringAsFixed(1)}°',
                      const TextStyle(fontSize: 10),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────
// Shared chart helpers
// ──────────────────────────────────────────────────────────────────────

double _log10(double x) => math.log(x) / math.ln10;

/// Build a magnitude line bar from frequency response data.
LineChartBarData _lineBar(
  List<FrequencyResponse> data,
  Color color, {
  List<int>? dashArray,
}) {
  final spots = data
      .map((d) => FlSpot(_log10(d.omegaRadPerSec / (2 * math.pi)), d.magnitudeDb))
      .toList();
  return LineChartBarData(
    spots: spots,
    isCurved: true,
    curveSmoothness: 0.15,
    color: color,
    barWidth: 2,
    dotData: const FlDotData(show: false),
    dashArray: dashArray,
  );
}

/// Build a phase line bar from frequency response data.
LineChartBarData _phaseLineBar(
  List<FrequencyResponse> data,
  Color color, {
  List<int>? dashArray,
}) {
  final spots = data
      .map((d) => FlSpot(_log10(d.omegaRadPerSec / (2 * math.pi)), d.phaseDeg))
      .toList();
  return LineChartBarData(
    spots: spots,
    isCurved: true,
    curveSmoothness: 0.15,
    color: color,
    barWidth: 2,
    dotData: const FlDotData(show: false),
    dashArray: dashArray,
  );
}

/// Common axis titles for Bode plot charts.
FlTitlesData _buildTitles(String xLabel, String yUnit) {
  return FlTitlesData(
    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles:
        const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    bottomTitles: AxisTitles(
      axisNameWidget:
          Text(xLabel, style: const TextStyle(fontSize: 10)),
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 22,
        getTitlesWidget: (v, _) {
          // v is log10(f in Hz); show decade labels
          final freq = math.pow(10, v);
          String label;
          if (freq >= 1000) {
            label = '${(freq / 1000).toStringAsFixed(0)}k';
          } else if (freq >= 1) {
            label = freq.toStringAsFixed(0);
          } else {
            label = freq.toStringAsFixed(1);
          }
          return Text(label, style: const TextStyle(fontSize: 9));
        },
      ),
    ),
    leftTitles: AxisTitles(
      axisNameWidget: Text(yUnit, style: const TextStyle(fontSize: 10)),
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 40,
        getTitlesWidget: (v, _) => Text(
          v.toStringAsFixed(0),
          style: const TextStyle(fontSize: 9),
        ),
      ),
    ),
  );
}
