/// Pole-Zero Map widget: visualizes closed-loop poles on the s-plane for
/// the identified plant model with PID controller.
///
/// Shows stability regions (left-half-plane = stable, right-half-plane =
/// unstable), poles as X markers, and annotates natural frequency / damping.
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

import '../../data/test_data.dart';
import 'chart_walkthrough.dart';

// ──────────────────────────────────────────────────────────────────────
// Public widget
// ──────────────────────────────────────────────────────────────────────

/// Whether to show the velocity or position loop.
/// Velocity PI → 2nd-order, Position PD → 2nd-order, Position PID → 3rd-order.
enum PoleZeroMode { velocity, position }

class PoleZeroMap extends StatefulWidget {
  final FeedforwardGains ff;
  final PidResult? velPid;
  final PidResult? posPid;

  const PoleZeroMap({
    super.key,
    required this.ff,
    this.velPid,
    this.posPid,
  });

  @override
  State<PoleZeroMap> createState() => _PoleZeroMapState();
}

class _PoleZeroMapState extends State<PoleZeroMap>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  PoleZeroMode _mode = PoleZeroMode.velocity;
  bool _walkthroughActive = false;

  PidResult? get _activePid =>
      _mode == PoleZeroMode.velocity ? widget.velPid : widget.posPid;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final pid = _activePid;
    final poles = _computePoles(widget.ff, pid, _mode);

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
                'Pole-Zero Map — s-Plane',
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
                ComboBox<PoleZeroMode>(
                  value: _mode,
                  items: [
                    if (widget.velPid != null)
                      const ComboBoxItem<PoleZeroMode>(
                        value: PoleZeroMode.velocity,
                        child: Text('Velocity Loop'),
                      ),
                    if (widget.posPid != null)
                      const ComboBoxItem<PoleZeroMode>(
                        value: PoleZeroMode.position,
                        child: Text('Position Loop'),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _mode = v);
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Legend
          _buildLegend(),
          const SizedBox(height: 2),

          // Explanation
          Text(
            _mode == PoleZeroMode.velocity
                ? 'Showing closed-loop poles of the velocity control system '
                  '(plant + PID controller combined). These describe how the '
                  'complete system responds — not the motor alone or the '
                  'controller alone.'
                : 'Showing closed-loop poles of the position control system '
                  '(plant + PID controller combined). These describe how the '
                  'complete system responds — not the motor alone or the '
                  'controller alone.',
            style: TextStyle(
              fontSize: 10,
              color: FluentTheme.of(context)
                  .typography
                  .body
                  ?.color
                  ?.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 4),

          // s-plane painter
          Expanded(
            child: _SPlaneCanvas(
              poles: poles,
              ff: widget.ff,
              pid: pid,
              mode: _mode,
            ),
          ),
        ],
      ),
    );

    return ChartWalkthrough(
      isActive: _walkthroughActive,
      steps: _poleZeroWalkthroughSteps(_mode, poles),
      onDismiss: () => setState(() => _walkthroughActive = false),
      child: chart,
    );
  }

  Widget _buildLegend() {
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        _legendMarker(color: _stablePoleColor, label: 'Closed-loop pole', isX: true),
        _legendMarker(color: _openLoopPoleColor, label: 'Open-loop pole', isX: false),
        _colorBox(
            color: _rootLocusColor.withValues(alpha: 0.7),
            label: 'Root locus'),
        _colorBox(
            color: _stableRegionColor.withValues(alpha: 0.25),
            label: 'Stable (LHP)'),
        _colorBox(
            color: _unstableRegionColor.withValues(alpha: 0.25),
            label: 'Unstable (RHP)'),
        _colorBox(
            color: _dampingLineColor.withValues(alpha: 0.5),
            label: 'Damping ratio lines'),
      ],
    );
  }

  Widget _legendMarker(
      {required Color color, required String label, required bool isX}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(isX ? 'X' : 'O',
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    );
  }

  Widget _colorBox({required Color color, required String label}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            border: Border.all(color: color.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────
// Pole computation
// ──────────────────────────────────────────────────────────────────────

class _Complex {
  final double re;
  final double im;
  const _Complex(this.re, this.im);

  bool get isStable => re < 0;
  double get magnitude => math.sqrt(re * re + im * im);

  /// Natural frequency (rad/s).
  double get wn => magnitude;

  /// Damping ratio (only meaningful for conjugate pairs).
  double get zeta => magnitude > 0 ? -re / magnitude : 0.0;

  @override
  String toString() {
    if (im == 0) return re.toStringAsFixed(3);
    final sign = im >= 0 ? '+' : '-';
    return '${re.toStringAsFixed(3)} $sign ${im.abs().toStringAsFixed(3)}j';
  }
}

List<_Complex> _computePoles(
    FeedforwardGains ff, PidResult? pid, PoleZeroMode mode) {
  final kA = ff.kA;
  final kV = ff.kV;

  if (kA <= 0) return [];

  // PID gains from the autotuner are in duty-cycle units (divided by
  // nominalVoltage).  The plant model is in voltage units, so we must
  // scale PID gains back to volts before combining with kV / kA.
  const nomV = 12.0;

  switch (mode) {
    case PoleZeroMode.velocity:
      // C(s)·G(s) = (kP_v·s + kI_v) / (s·(kA·s + kV))
      // Characteristic: kA·s² + (kV + kP_v)·s + kI_v = 0
      final kPv = (pid?.kP ?? 0.0) * nomV;
      final kIv = (pid?.kI ?? 0.0) * nomV;

      if (kIv == 0) {
        // Single real pole: s = -(kV + kPv)/kA
        return [_Complex(-(kV + kPv) / kA, 0)];
      }

      // Quadratic: kA·s² + (kV+kPv)·s + kIv = 0
      return _solveQuadratic(kA, kV + kPv, kIv);

    case PoleZeroMode.position:
      // C(s) = kP + kD·s + kI/s = (kD·s² + kP·s + kI) / s
      // G(s) = 1 / (s·(kA·s + kV))
      // Characteristic: kA·s³ + (kV + kD)·s² + kP·s + kI = 0
      // When kI = 0 (PD): reduces to kA·s² + (kV + kD)·s + kP = 0
      final kPv = (pid?.kP ?? 0.0) * nomV;
      final kDv = (pid?.kD ?? 0.0) * nomV;
      final kIv = (pid?.kI ?? 0.0) * nomV;

      if (kIv.abs() < 1e-12) {
        return _solveQuadratic(kA, kV + kDv, kPv);
      }
      return _solveCubic(kA, kV + kDv, kPv, kIv);
  }
}

List<_Complex> _solveQuadratic(double a, double b, double c) {
  if (a == 0) {
    if (b == 0) return [];
    return [_Complex(-c / b, 0)];
  }
  final disc = b * b - 4 * a * c;
  if (disc >= 0) {
    final sqrtDisc = math.sqrt(disc);
    return [
      _Complex((-b + sqrtDisc) / (2 * a), 0),
      _Complex((-b - sqrtDisc) / (2 * a), 0),
    ];
  } else {
    final realPart = -b / (2 * a);
    final imagPart = math.sqrt(-disc) / (2 * a);
    return [
      _Complex(realPart, imagPart),
      _Complex(realPart, -imagPart),
    ];
  }
}

/// Cube root that handles negative values.
double _cbrt(double x) =>
    x >= 0 ? math.pow(x, 1.0 / 3.0).toDouble() : -math.pow(-x, 1.0 / 3.0).toDouble();

/// Solve a cubic equation ax³ + bx² + cx + d = 0 using Cardano / trigonometric method.
List<_Complex> _solveCubic(double a, double b, double c, double d) {
  if (a.abs() < 1e-15) return _solveQuadratic(b, c, d);

  // Normalize: x³ + px² + qx + r = 0
  final p = b / a;
  final q = c / a;
  final r = d / a;

  // Depressed cubic: t³ + At + B = 0 where x = t - p/3
  final A = q - p * p / 3;
  final B = r - p * q / 3 + 2 * p * p * p / 27;

  final disc = -4 * A * A * A - 27 * B * B;

  if (disc > 1e-10) {
    // Three distinct real roots – trigonometric method
    final m = 2 * math.sqrt(-A / 3);
    final theta = math.acos(3 * B / (A * m)) / 3;
    return [
      _Complex(m * math.cos(theta) - p / 3, 0),
      _Complex(m * math.cos(theta - 2 * math.pi / 3) - p / 3, 0),
      _Complex(m * math.cos(theta - 4 * math.pi / 3) - p / 3, 0),
    ];
  } else if (disc < -1e-10) {
    // One real root + conjugate pair – Cardano
    final sqrtD = math.sqrt(B * B / 4 + A * A * A / 27);
    final u = _cbrt(-B / 2 + sqrtD);
    final v = _cbrt(-B / 2 - sqrtD);
    final realRoot = u + v - p / 3;
    final complexRe = -(u + v) / 2 - p / 3;
    final complexIm = (u - v) * math.sqrt(3) / 2;
    return [
      _Complex(realRoot, 0),
      _Complex(complexRe, complexIm),
      _Complex(complexRe, -complexIm),
    ];
  } else {
    // Repeated roots
    if (B.abs() < 1e-15) {
      return [
        _Complex(-p / 3, 0),
        _Complex(-p / 3, 0),
        _Complex(-p / 3, 0),
      ];
    }
    final u = _cbrt(-B / 2);
    return [
      _Complex(2 * u - p / 3, 0),
      _Complex(-u - p / 3, 0),
      _Complex(-u - p / 3, 0),
    ];
  }
}

// ──────────────────────────────────────────────────────────────────────
// s-plane CustomPainter
// ──────────────────────────────────────────────────────────────────────

const Color _stableRegionColor = Color(0xFF44AA44);
const Color _unstableRegionColor = Color(0xFFAA4444);
const Color _stablePoleColor = Color(0xFF22BB22);
const Color _unstablePoleColor = Color(0xFFDD3333);
const Color _rootLocusColor = Color(0xFFFF8800);
const Color _openLoopPoleColor = Color(0xFF6688CC);
const Color _dampingLineColor = Color(0xFF888888);
const Color _wnCircleColor = Color(0xFF666666);
const Color _gridColor = Color(0xFF555555);
const Color _axisColor = Color(0xFFBBBBBB);
const Color _labelColor = Color(0xFFDDDDDD);

class _SPlaneCanvas extends StatelessWidget {
  final List<_Complex> poles;
  final FeedforwardGains ff;
  final PidResult? pid;
  final PoleZeroMode mode;

  const _SPlaneCanvas({
    required this.poles,
    required this.ff,
    this.pid,
    required this.mode,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      child: CustomPaint(
        painter: _SPlanePainter(
          poles: poles,
          ff: ff,
          pid: pid,
          mode: mode,
        ),
      ),
    );
  }
}

class _SPlanePainter extends CustomPainter {
  final List<_Complex> poles;
  final FeedforwardGains ff;
  final PidResult? pid;
  final PoleZeroMode mode;

  const _SPlanePainter({
    required this.poles,
    required this.ff,
    this.pid,
    required this.mode,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // Determine the axis extents based on where the poles are.
    double maxAbs = 50.0; // minimum range
    for (final p in poles) {
      final extent = math.max(p.re.abs(), p.im.abs());
      if (extent > maxAbs) maxAbs = extent * 1.3;
    }
    maxAbs = (maxAbs * 1.2).ceilToDouble();

    final realMin = -maxAbs;
    final realMax = maxAbs;
    final imagMin = -maxAbs;
    final imagMax = maxAbs;

    // Coordinate helpers
    double toX(double re) =>
        (re - realMin) / (realMax - realMin) * size.width;
    double toY(double im) =>
        (1 - (im - imagMin) / (imagMax - imagMin)) * size.height;

    final originX = toX(0);
    final originY = toY(0);

    // ── Background stability regions ──────────────────────────────────
    final stablePaint = Paint()
      ..color = _stableRegionColor.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;
    final unstablePaint = Paint()
      ..color = _unstableRegionColor.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;

    canvas.drawRect(
        Rect.fromLTRB(0, 0, originX, size.height), stablePaint);
    canvas.drawRect(
        Rect.fromLTRB(originX, 0, size.width, size.height), unstablePaint);

    // ── Grid lines ────────────────────────────────────────────────────
    final gridPaint = Paint()
      ..color = _gridColor.withValues(alpha: 0.35)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    final step = _niceStep(maxAbs);
    for (double v = -maxAbs; v <= maxAbs + step * 0.1; v += step) {
      final px = toX(v);
      final py = toY(v);
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), gridPaint);
      canvas.drawLine(Offset(0, py), Offset(size.width, py), gridPaint);
    }

    // ── Imaginary axis (stability boundary) ──────────────────────────
    final axisPaint = Paint()
      ..color = _axisColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
        Offset(originX, 0), Offset(originX, size.height), axisPaint);
    canvas.drawLine(
        Offset(0, originY), Offset(size.width, originY), axisPaint);

    // ── Axis labels ───────────────────────────────────────────────────
    final labelStyle = TextStyle(
        color: _labelColor, fontSize: 9, fontFamily: 'monospace');
    for (double v = -maxAbs; v <= maxAbs + step * 0.1; v += step) {
      if (v.abs() < step * 0.1) continue; // skip zero
      _drawLabel(canvas, v.toStringAsFixed(0),
          Offset(toX(v), originY + 4), labelStyle, TextAlign.center);
      _drawLabel(canvas, v.toStringAsFixed(0),
          Offset(originX + 4, toY(v)), labelStyle, TextAlign.left);
    }

    // Axis name labels
    final axisNameStyle =
        TextStyle(color: _labelColor, fontSize: 10, fontStyle: FontStyle.italic);
    _drawLabel(
        canvas, 'Re', Offset(size.width - 16, originY - 14), axisNameStyle,
        TextAlign.right);
    _drawLabel(
        canvas, 'Im', Offset(originX + 6, 4), axisNameStyle, TextAlign.left);

    // Stability boundary label
    final boundaryStyle = TextStyle(
        color: _axisColor.withValues(alpha: 0.7),
        fontSize: 9,
        fontStyle: FontStyle.italic);
    _drawLabel(canvas, 'Stability\nboundary',
        Offset(originX + 4, size.height * 0.08), boundaryStyle, TextAlign.left);

    // ── Constant damping ratio lines ──────────────────────────────────
    final dampingPaint = Paint()
      ..color = _dampingLineColor.withValues(alpha: 0.35)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    final dampingLabelStyle = TextStyle(
        color: _dampingLineColor.withValues(alpha: 0.6),
        fontSize: 8,
        fontStyle: FontStyle.italic);
    for (final zeta in [0.3, 0.5, 0.707, 0.9]) {
      // ζ = cos(θ) where θ is angle from negative real axis
      final theta = math.acos(zeta);
      // Draw line from origin at angle π-θ and π+θ (both upper and lower)
      final lineLen = maxAbs * 1.1;
      final reEnd = -lineLen * math.cos(theta);
      final imEnd = lineLen * math.sin(theta);
      // Upper half (only in LHP)
      canvas.drawLine(
          Offset(originX, originY),
          Offset(toX(reEnd), toY(imEnd)),
          dampingPaint);
      // Lower half
      canvas.drawLine(
          Offset(originX, originY),
          Offset(toX(reEnd), toY(-imEnd)),
          dampingPaint);
      // Label near the end
      final labelRe = reEnd * 0.75;
      final labelIm = imEnd * 0.75;
      final zetaStr = zeta == 0.707 ? '0.707' : zeta.toString();
      _drawLabel(canvas, 'z=$zetaStr',
          Offset(toX(labelRe) - 4, toY(labelIm) - 10),
          dampingLabelStyle, TextAlign.left);
    }

    // ── Natural frequency arcs (LHP only) ─────────────────────────────
    final wnPaint = Paint()
      ..color = _wnCircleColor.withValues(alpha: 0.2)
      ..strokeWidth = 0.6
      ..style = PaintingStyle.stroke;
    final wnStep = _niceStep(maxAbs);
    for (double wn = wnStep; wn < maxAbs; wn += wnStep) {
      final r = (wn / maxAbs) * (size.width / 2);
      // Draw arc only in LHP (from 90° to 270° i.e. left semicircle)
      canvas.drawArc(
        Rect.fromCircle(center: Offset(originX, originY), radius: r),
        math.pi / 2, // start at bottom of LHP
        math.pi,     // sweep 180° through LHP
        false,
        wnPaint,
      );
    }

    // ── Root locus ────────────────────────────────────────────────────
    _drawRootLocus(canvas, size, toX, toY);

    // ── Open-loop poles ───────────────────────────────────────────────
    final olPoles = _computeOpenLoopPoles();
    // ── Open-loop poles (with multiplicity) ─────────────────────────
    final olDrawn = <int>{};
    for (int i = 0; i < olPoles.length; i++) {
      if (olDrawn.contains(i)) continue;
      final olp = olPoles[i];
      int mult = 1;
      for (int j = i + 1; j < olPoles.length; j++) {
        if (!olDrawn.contains(j) &&
            (olp.re - olPoles[j].re).abs() < 1e-3 &&
            (olp.im - olPoles[j].im).abs() < 1e-3) {
          mult++;
          olDrawn.add(j);
        }
      }
      olDrawn.add(i);
      final px = toX(olp.re);
      final py = toY(olp.im);
      _drawOMarker(canvas, Offset(px, py), _openLoopPoleColor);
      if (mult > 1) {
        _drawLabel(
          canvas,
          '×$mult',
          Offset(px + 8, py - 10),
          TextStyle(
              color: _openLoopPoleColor.withValues(alpha: 0.85), fontSize: 9),
          TextAlign.left,
        );
      }
    }

    // ── Closed-loop poles (with multiplicity detection) ─────────────
    // Group poles that are at (nearly) the same location.
    final drawn = <int>{};
    for (int i = 0; i < poles.length; i++) {
      if (drawn.contains(i)) continue;
      final pole = poles[i];
      int mult = 1;
      for (int j = i + 1; j < poles.length; j++) {
        if (!drawn.contains(j) &&
            (pole.re - poles[j].re).abs() < 1e-3 &&
            (pole.im - poles[j].im).abs() < 1e-3) {
          mult++;
          drawn.add(j);
        }
      }
      drawn.add(i);

      final px = toX(pole.re);
      final py = toY(pole.im);
      final color = pole.isStable ? _stablePoleColor : _unstablePoleColor;
      _drawXMarker(canvas, Offset(px, py), color);

      // Annotate natural frequency (wn) and damping ratio (zeta) for complex poles
      if (pole.im.abs() > 1e-6 && pole.im > 0) {
        final naturalFrequency = pole.wn; // rad/s
        final dampingRatio = pole.zeta;
        final multStr = mult > 1 ? ' (×$mult)' : '';
        final annotation =
            'wn=${naturalFrequency.toStringAsFixed(1)}$multStr\nz=${dampingRatio.toStringAsFixed(2)}';
        final annotStyle = TextStyle(
            color: color.withValues(alpha: 0.85), fontSize: 9);
        _drawLabel(canvas, annotation, Offset(px + 8, py - 18), annotStyle,
            TextAlign.left);
      } else if (pole.im.abs() <= 1e-6) {
        // Real pole: label the value + multiplicity
        final multStr = mult > 1 ? ' (×$mult)' : '';
        _drawLabel(
            canvas,
            '${pole.re.toStringAsFixed(1)}$multStr',
            Offset(px + 8, py - 12),
            TextStyle(color: color.withValues(alpha: 0.85), fontSize: 9),
            TextAlign.left);
      }
    }

    canvas.restore();
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  void _drawXMarker(Canvas canvas, Offset center, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const r = 6.0;
    canvas.drawLine(center + const Offset(-r, -r), center + const Offset(r, r),
        paint);
    canvas.drawLine(center + const Offset(r, -r), center + const Offset(-r, r),
        paint);
  }

  void _drawLabel(Canvas canvas, String text, Offset offset, TextStyle style,
      TextAlign align) {
    final span = TextSpan(text: text, style: style);
    final tp = TextPainter(
        text: span, textAlign: align, textDirection: TextDirection.ltr);
    tp.layout(maxWidth: 80);
    Offset pos = offset;
    if (align == TextAlign.center) {
      pos = offset - Offset(tp.width / 2, 0);
    } else if (align == TextAlign.right) {
      pos = offset - Offset(tp.width, 0);
    }
    tp.paint(canvas, pos);
  }

  /// Choose a nice round grid step for the given max value.
  double _niceStep(double maxAbs) {
    if (maxAbs <= 5) return 1;
    if (maxAbs <= 20) return 5;
    if (maxAbs <= 100) return 25;
    if (maxAbs <= 500) return 100;
    return (maxAbs / 4).roundToDouble();
  }

  /// Compute open-loop poles (plant + controller integrators).
  List<_Complex> _computeOpenLoopPoles() {
    final kA = ff.kA;
    final kV = ff.kV;
    if (kA <= 0) return [];

    final hasIntegrator = (pid?.kI ?? 0.0).abs() > 1e-12;

    switch (mode) {
      case PoleZeroMode.velocity:
        // Plant pole at -kV/kA. PI adds integrator pole at 0.
        if (hasIntegrator) {
          return [const _Complex(0, 0), _Complex(-kV / kA, 0)];
        }
        return [_Complex(-kV / kA, 0)];
      case PoleZeroMode.position:
        // Plant poles at 0, -kV/kA. PID adds integrator → double pole at 0.
        if (hasIntegrator) {
          return [
            const _Complex(0, 0),
            const _Complex(0, 0),
            _Complex(-kV / kA, 0),
          ];
        }
        return [const _Complex(0, 0), _Complex(-kV / kA, 0)];
    }
  }

  /// Draw root locus: sweep an overall gain K and trace pole movement.
  void _drawRootLocus(
    Canvas canvas,
    Size size,
    double Function(double) toX,
    double Function(double) toY,
  ) {
    final kA = ff.kA;
    final kV = ff.kV;
    if (kA <= 0) return;

    const steps = 200;

    final locusPaint = Paint()
      ..color = _rootLocusColor.withValues(alpha: 0.6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final branch1 = <Offset>[];
    final branch2 = <Offset>[];
    final branch3 = <Offset>[];

    double gainMax;
    final hasIntegrator = (pid?.kI ?? 0.0).abs() > 1e-12;

    switch (mode) {
      case PoleZeroMode.velocity:
        // Sweep K in kA·s² + kV·s + K = 0 (2 branches from {0, -kV/kA})
        gainMax = (kV * kV / kA) * 2.0;
        if (gainMax < 1) gainMax = 100;
        for (int i = 0; i <= steps; i++) {
          final k = gainMax * i / steps;
          final roots = _solveQuadratic(kA, kV, k);
          if (roots.isNotEmpty) branch1.add(Offset(toX(roots[0].re), toY(roots[0].im)));
          if (roots.length > 1) branch2.add(Offset(toX(roots[1].re), toY(roots[1].im)));
        }

      case PoleZeroMode.position:
        if (hasIntegrator) {
          // PID: 3 OL poles {0, 0, -kV/kA}. Sweep K in kA·s³ + kV·s² + K = 0
          gainMax = kV * kV * kV / (kA * kA) * 0.5;
          if (gainMax < 1) gainMax = 100;
          for (int i = 0; i <= steps; i++) {
            final k = gainMax * i / steps;
            final roots = _solveCubic(kA, kV, 0, k);
            if (roots.isNotEmpty) branch1.add(Offset(toX(roots[0].re), toY(roots[0].im)));
            if (roots.length > 1) branch2.add(Offset(toX(roots[1].re), toY(roots[1].im)));
            if (roots.length > 2) branch3.add(Offset(toX(roots[2].re), toY(roots[2].im)));
          }
        } else {
          // PD: 2 OL poles {0, -kV/kA}. Sweep K in kA·s² + kV·s + K = 0
          gainMax = (kV * kV / kA) * 2.0;
          if (gainMax < 1) gainMax = 100;
          for (int i = 0; i <= steps; i++) {
            final k = gainMax * i / steps;
            final roots = _solveQuadratic(kA, kV, k);
            if (roots.isNotEmpty) branch1.add(Offset(toX(roots[0].re), toY(roots[0].im)));
            if (roots.length > 1) branch2.add(Offset(toX(roots[1].re), toY(roots[1].im)));
          }
        }
    }

    // Draw the locus paths
    for (final branch in [branch1, branch2, branch3]) {
      if (branch.length > 1) {
        final path = Path()..moveTo(branch.first.dx, branch.first.dy);
        for (int i = 1; i < branch.length; i++) {
          path.lineTo(branch[i].dx, branch[i].dy);
        }
        canvas.drawPath(path, locusPaint);
      }
    }
  }

  void _drawOMarker(Canvas canvas, Offset center, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, 6.0, paint);
  }

  @override
  bool shouldRepaint(_SPlanePainter old) =>
      old.poles != poles || old.ff != ff || old.pid != pid || old.mode != mode;
}

// ──────────────────────────────────────────────────────────────────────
// Walkthrough steps
// ──────────────────────────────────────────────────────────────────────

List<WalkthroughStep> _poleZeroWalkthroughSteps(
    PoleZeroMode mode, List<_Complex> poles) {
  final steps = <WalkthroughStep>[
    const WalkthroughStep(
      title: 'What is the s-plane?',
      description:
          'The s-plane is a 2D map of complex numbers s = sigma + j*omega. '
          'The horizontal axis (Re) represents growth or decay rate. '
          'The vertical axis (Im) represents oscillation frequency.\n\n'
          'This map reveals how your closed-loop system behaves after you '
          'apply PID control.',
      icon: FluentIcons.chart_series,
    ),
    const WalkthroughStep(
      title: 'Left vs Right Half-Plane',
      description:
          'GREEN region (left half): poles here decay over time -- the system '
          'is STABLE. The further left, the faster it settles.\n\n'
          'RED region (right half): poles here grow over time -- the system '
          'is UNSTABLE and will oscillate uncontrollably.',
      icon: FluentIcons.warning,
    ),
    const WalkthroughStep(
      title: 'Open-Loop vs Closed-Loop Poles',
      description:
          'BLUE circles (O) = open-loop poles: where the plant\'s poles '
          'sit before any controller is applied.\n\n'
          'GREEN/RED crosses (X) = closed-loop poles: where the poles '
          'move to after applying your PID gains. The PID controller '
          'shifts the poles to control speed and stability.',
      icon: FluentIcons.trending12,
    ),
    const WalkthroughStep(
      title: 'Root Locus (orange trace)',
      description:
          'The orange curve shows how the closed-loop poles MOVE as gain '
          'increases from 0 to infinity. It starts at the open-loop poles '
          'and traces a path.\n\n'
          'If the path crosses into the right half-plane, the system '
          'becomes unstable at that gain level. Your current poles (X) '
          'are one point on this curve.',
      icon: FluentIcons.chart_series,
    ),
    const WalkthroughStep(
      title: 'Damping Ratio Lines',
      description:
          'The diagonal guide lines show constant damping ratio (zeta):\n\n'
          'z=0.3: very oscillatory (lots of ringing)\n'
          'z=0.5: underdamped\n'
          'z=0.707: optimal (fast + minimal overshoot)\n'
          'z=0.9: well-damped (slightly slower)\n\n'
          'Poles on the real axis have z=1.0 (critically damped, no oscillation).',
      icon: FluentIcons.trending12,
    ),];

  if (poles.isNotEmpty) {
    final allStable = poles.every((p) => p.isStable);
    steps.add(WalkthroughStep(
      title: 'Your System\'s Poles',
      description: allStable
          ? 'All ${poles.length} pole(s) are in the left half-plane -- '
              'your closed-loop system is STABLE with the current PID gains.\n\n'
              'The distance from the imaginary axis controls settling speed.'
          : 'WARNING: One or more poles are in the right half-plane! '
              'Your system is UNSTABLE. Try reducing kP or kI.',
      icon: allStable ? FluentIcons.accept : FluentIcons.warning,
    ));

    // Natural frequency / damping annotation for complex poles
    final complexPoles = poles.where((p) => p.im.abs() > 1e-6).toList();
    if (complexPoles.isNotEmpty) {
      final p = complexPoles.first;
      steps.add(WalkthroughStep(
        title: 'Natural Frequency & Damping',
        description:
            'Your poles have natural frequency wn = '
            '${p.wn.toStringAsFixed(2)} rad/s and damping ratio '
            'zeta = ${p.zeta.toStringAsFixed(3)}.\n\n'
            'zeta < 1: underdamped (oscillatory), '
            'zeta = 1: critically damped, '
            'zeta > 1: overdamped (sluggish).\n\n'
            'Aim for zeta around 0.7 for a good balance.',
        icon: FluentIcons.chart_series,
      ));
    }
  }

  if (mode == PoleZeroMode.velocity) {
    steps.add(const WalkthroughStep(
      title: 'Velocity Loop Math',
      description:
          'Plant: G(s) = 1 / (kA*s + kV)\n'
          'Controller: C(s) = kP + kI/s\n'
          'Characteristic eq: kA*s^2 + (kV+kP)*s + kI = 0\n\n'
          'Increasing kP moves poles left (faster). '
          'Increasing kI adds a pole at origin (integrator).',
      icon: FluentIcons.trending12,
    ));
  } else {
    steps.add(const WalkthroughStep(
      title: 'Position Loop Math',
      description:
          'Plant: G(s) = 1 / (kA·s² + kV·s)\n'
          'Controller: C(s) = kP + kD·s + kI/s\n\n'
          'PD (kI=0): kA·s² + (kV+kD)·s + kP = 0 → 2 poles\n'
          'PID (kI≠0): kA·s³ + (kV+kD)·s² + kP·s + kI = 0 → 3 poles\n\n'
          'Increasing kD adds damping. '
          'Increasing kP increases natural frequency. '
          'Adding kI eliminates steady-state error but adds a 3rd pole.',
      icon: FluentIcons.trending12,
    ));
  }

  return steps;
}

// ──────────────────────────────────────────────────────────────────────
// Public API — used by the PDF report generator
// ──────────────────────────────────────────────────────────────────────

/// A closed-loop pole on the s-plane, exposed for external consumers
/// (e.g. the PDF report generator).
class PolePlotData {
  final double re;
  final double im;
  const PolePlotData(this.re, this.im);

  bool get isStable => re < 0;
  double get magnitude => math.sqrt(re * re + im * im);
  double get wn => magnitude;
  double get zeta => magnitude > 0 ? -re / magnitude : 0.0;

  @override
  String toString() {
    if (im == 0) return re.toStringAsFixed(3);
    final sign = im >= 0 ? '+' : '-';
    return '${re.toStringAsFixed(3)} $sign ${im.abs().toStringAsFixed(3)}j';
  }
}

/// Compute closed-loop poles for the given plant model and PID gains.
List<PolePlotData> computeClosedLoopPoles(
    FeedforwardGains ff, PidResult? pid, PoleZeroMode mode) {
  return _computePoles(ff, pid, mode)
      .map((c) => PolePlotData(c.re, c.im))
      .toList();
}

/// Compute open-loop poles (plant poles + controller integrators).
List<PolePlotData> computeOpenLoopPoles(
    FeedforwardGains ff, PidResult? pid, PoleZeroMode mode) {
  final kA = ff.kA;
  final kV = ff.kV;
  if (kA <= 0) return [];

  final hasIntegrator = (pid?.kI ?? 0.0).abs() > 1e-12;

  switch (mode) {
    case PoleZeroMode.velocity:
      if (hasIntegrator) {
        return [const PolePlotData(0, 0), PolePlotData(-kV / kA, 0)];
      }
      return [PolePlotData(-kV / kA, 0)];
    case PoleZeroMode.position:
      if (hasIntegrator) {
        return [
          const PolePlotData(0, 0),
          const PolePlotData(0, 0),
          PolePlotData(-kV / kA, 0),
        ];
      }
      return [const PolePlotData(0, 0), PolePlotData(-kV / kA, 0)];
  }
}
