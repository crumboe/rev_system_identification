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

/// Whether to show the velocity or position loop (both have 2nd-order
/// closed-loop characteristic equations when using PI/PD control).
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

class _PoleZeroMapState extends State<PoleZeroMap> {
  PoleZeroMode _mode = PoleZeroMode.velocity;
  bool _walkthroughActive = false;

  PidResult? get _activePid =>
      _mode == PoleZeroMode.velocity ? widget.velPid : widget.posPid;

  @override
  Widget build(BuildContext context) {
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
          const SizedBox(height: 4),

          // s-plane painter
          Expanded(
            child: _SPlaneCanvas(poles: poles),
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
    return Row(
      children: [
        _legendMarker(color: _stablePoleColor, label: 'Stable pole', isX: true),
        const SizedBox(width: 16),
        _legendMarker(
            color: _unstablePoleColor, label: 'Unstable pole', isX: true),
        const SizedBox(width: 16),
        _colorBox(
            color: _stableRegionColor.withValues(alpha: 0.25),
            label: 'Stable (LHP)'),
        const SizedBox(width: 16),
        _colorBox(
            color: _unstableRegionColor.withValues(alpha: 0.25),
            label: 'Unstable (RHP)'),
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

  switch (mode) {
    case PoleZeroMode.velocity:
      // C(s)·G(s) = (kP·s + kI) / (s·(kA·s + kV))
      // Characteristic: kA·s² + (kV + kP)·s + kI = 0
      final kP = pid?.kP ?? 0.0;
      final kI = pid?.kI ?? 0.0;

      if (kI == 0) {
        // Single real pole: s = -(kV + kP)/kA
        if (kA == 0) return [];
        return [_Complex(-(kV + kP) / kA, 0)];
      }

      // Quadratic: kA·s² + (kV+kP)·s + kI = 0
      return _solveQuadratic(kA, kV + kP, kI);

    case PoleZeroMode.position:
      // C(s)·G(s) = (kP + kD·s) / (s·(kA·s + kV))
      // Characteristic: kA·s² + (kV + kD)·s + kP = 0
      final kP = pid?.kP ?? 0.0;
      final kD = pid?.kD ?? 0.0;

      return _solveQuadratic(kA, kV + kD, kP);
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

// ──────────────────────────────────────────────────────────────────────
// s-plane CustomPainter
// ──────────────────────────────────────────────────────────────────────

const Color _stableRegionColor = Color(0xFF44AA44);
const Color _unstableRegionColor = Color(0xFFAA4444);
const Color _stablePoleColor = Color(0xFF22BB22);
const Color _unstablePoleColor = Color(0xFFDD3333);
const Color _gridColor = Color(0xFF555555);
const Color _axisColor = Color(0xFFBBBBBB);
const Color _labelColor = Color(0xFFDDDDDD);

class _SPlaneCanvas extends StatelessWidget {
  final List<_Complex> poles;

  const _SPlaneCanvas({required this.poles});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SPlanePainter(poles: poles),
    );
  }
}

class _SPlanePainter extends CustomPainter {
  final List<_Complex> poles;

  const _SPlanePainter({required this.poles});

  @override
  void paint(Canvas canvas, Size size) {
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

    // ── Poles ─────────────────────────────────────────────────────────
    for (final pole in poles) {
      final px = toX(pole.re);
      final py = toY(pole.im);
      final color = pole.isStable ? _stablePoleColor : _unstablePoleColor;
      _drawXMarker(canvas, Offset(px, py), color);

      // Annotate natural frequency (wn) and damping ratio (zeta) for complex poles
      if (pole.im.abs() > 1e-6 && pole.im > 0) {
        final naturalFrequency = pole.wn; // rad/s
        final dampingRatio = pole.zeta; // dimensionless (0=undamped, 1=critically damped)
        final annotation =
            'wn=${naturalFrequency.toStringAsFixed(1)}\nzeta=${dampingRatio.toStringAsFixed(2)}';
        final annotStyle = TextStyle(
            color: color.withValues(alpha: 0.85), fontSize: 9);
        _drawLabel(canvas, annotation, Offset(px + 6, py - 18), annotStyle,
            TextAlign.left);
      } else if (pole.im.abs() <= 1e-6) {
        // Real pole: label the value
        _drawLabel(
            canvas,
            pole.re.toStringAsFixed(1),
            Offset(px + 6, py - 12),
            TextStyle(color: color.withValues(alpha: 0.85), fontSize: 9),
            TextAlign.left);
      }
    }
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

  @override
  bool shouldRepaint(_SPlanePainter old) => old.poles != poles;
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
      title: 'What are Poles?',
      description:
          'Poles (marked X) are the roots of the closed-loop characteristic '
          'equation 1 + C(s)*G(s) = 0. They determine the natural behavior '
          'of the system.\n\n'
          'Real poles = exponential response (no oscillation).\n'
          'Complex conjugate pair = oscillatory response (like a spring).',
      icon: FluentIcons.trending12,
    ),
  ];

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
          'Plant: G(s) = 1 / (kA*s^2 + kV*s)\n'
          'Controller: C(s) = kP + kD*s\n'
          'Characteristic eq: kA*s^2 + (kV+kD)*s + kP = 0\n\n'
          'Increasing kD adds damping (moves poles left). '
          'Increasing kP increases natural frequency.',
      icon: FluentIcons.trending12,
    ));
  }

  return steps;
}
