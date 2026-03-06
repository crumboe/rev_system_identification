/// Interactive control-system block diagram showing the identified plant model
/// and controller gains with live values from the analysis.
library;

import 'package:fluent_ui/fluent_ui.dart';

import '../../data/test_data.dart';
import '../../mechanisms/mechanism.dart';

/// Which control loop the diagram represents.
enum LoopMode { velocity, position }

/// Draws a closed-loop block diagram populated with the identified plant model
/// and the auto-tuned PID / FF gains.
class ControlBlockDiagram extends StatelessWidget {
  final FeedforwardGains ff;
  final PidResult pid;
  final LoopMode mode;
  final MechanismType mechanismType;

  const ControlBlockDiagram({
    super.key,
    required this.ff,
    required this.pid,
    required this.mode,
    required this.mechanismType,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          mode == LoopMode.velocity ? 'Velocity Control Loop' : 'Position Control Loop',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 220,
          child: CustomPaint(
            painter: _BlockDiagramPainter(
              ff: ff,
              pid: pid,
              mode: mode,
              mechanismType: mechanismType,
              isDark: isDark,
              accentColor: theme.accentColor,
            ),
            child: const SizedBox.expand(),
          ),
        ),
        const SizedBox(height: 8),
        _PlantEquation(ff: ff, mode: mode),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Transfer function equation display beneath the diagram
// ─────────────────────────────────────────────────────────────────────────────

class _PlantEquation extends StatelessWidget {
  final FeedforwardGains ff;
  final LoopMode mode;

  const _PlantEquation({required this.ff, required this.mode});

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final muted = theme.typography.body?.color?.withValues(alpha: 0.7);

    final kA = ff.kA.toStringAsFixed(4);
    final kV = ff.kV.toStringAsFixed(4);

    final String tf;
    final String metrics;
    if (mode == LoopMode.velocity) {
      tf = 'G(s) = 1 / ($kA·s + $kV)';
      final tau = ff.kV > 0 ? ff.kA / ff.kV : double.infinity;
      final dcGain = ff.kV > 0 ? 1.0 / ff.kV : double.infinity;
      metrics = 'τ_plant = kA/kV = ${tau.toStringAsFixed(3)} s'
          '    DC gain = 1/kV = ${dcGain.toStringAsFixed(2)} (unit/s)/V';
    } else {
      tf = 'G(s) = 1 / ($kA·s² + $kV·s)';
      final tau = ff.kV > 0 ? ff.kA / ff.kV : double.infinity;
      metrics = 'τ_plant = kA/kV = ${tau.toStringAsFixed(3)} s';
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Identified plant:  $tf',
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'Consolas',
              color: theme.typography.body?.color,
            ),
          ),
          const SizedBox(height: 2),
          Text(metrics, style: TextStyle(fontSize: 11, color: muted)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CustomPainter – the actual block diagram drawing
// ─────────────────────────────────────────────────────────────────────────────

class _BlockDiagramPainter extends CustomPainter {
  final FeedforwardGains ff;
  final PidResult pid;
  final LoopMode mode;
  final MechanismType mechanismType;
  final bool isDark;
  final AccentColor accentColor;

  const _BlockDiagramPainter({
    required this.ff,
    required this.pid,
    required this.mode,
    required this.mechanismType,
    required this.isDark,
    required this.accentColor,
  });

  // ── Palette ──────────────────────────────────────────────────────────────

  Color get _controllerColor => const Color(0xFF4A90D9); // blue
  Color get _plantColor => const Color(0xFF5CB85C); // green
  Color get _ffColor => const Color(0xFFE8943A); // orange
  Color get _sumColor => isDark ? const Color(0xFFBBBBBB) : const Color(0xFF555555);
  Color get _lineColor => isDark ? const Color(0xFFAAAAAA) : const Color(0xFF444444);
  Color get _textColor => isDark ? const Color(0xFFDDDDDD) : const Color(0xFF222222);
  Color get _labelColor => isDark ? const Color(0xFF999999) : const Color(0xFF666666);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    final w = size.width;
    final h = size.height;

    // Layout constants — all relative to widget size.
    final blockH = h * 0.22;
    final blockW = w * 0.18;
    final midY = h * 0.38; // main signal path vertical center
    final ffY = h * 0.82; // feedforward path vertical center

    // Horizontal positions (left edges of blocks along the signal path).
    final refX = w * 0.02;
    final sumX = w * 0.14;
    final ctrlX = w * 0.24;
    final sumFfX = w * 0.48;
    final plantX = w * 0.60;
    final outX = w * 0.88;

    final linePaint = Paint()
      ..color = _lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final arrowPaint = Paint()
      ..color = _lineColor
      ..style = PaintingStyle.fill;

    // ── Signal lines ───────────────────────────────────────────────────────

    // Reference label
    _drawLabel(canvas, mode == LoopMode.velocity ? 'ω_ref' : 'x_ref',
        Offset(refX, midY), _labelColor, 12, align: TextAlign.right);

    // r → Σ₁
    _drawArrow(canvas, Offset(refX + w * 0.06, midY),
        Offset(sumX - 6, midY), linePaint, arrowPaint);

    // Σ₁ (error summing junction)
    _drawSum(canvas, Offset(sumX, midY), 10, '+', '−');

    // Σ₁ → Controller
    _drawArrow(canvas, Offset(sumX + 12, midY),
        Offset(ctrlX, midY), linePaint, arrowPaint);

    // Controller block
    _drawBlock(canvas, Rect.fromCenter(
        center: Offset(ctrlX + blockW / 2, midY),
        width: blockW, height: blockH),
        _controllerColor, _controllerLabel(), _controllerValues());

    // Controller → Σ₂ (FF summing junction)
    _drawArrow(canvas, Offset(ctrlX + blockW, midY),
        Offset(sumFfX - 6, midY), linePaint, arrowPaint);

    // Σ₂ (FF summing junction)
    _drawSum(canvas, Offset(sumFfX, midY), 10, '+', '+');

    // Σ₂ → Plant
    _drawArrow(canvas, Offset(sumFfX + 12, midY),
        Offset(plantX, midY), linePaint, arrowPaint);

    // Plant block
    _drawBlock(canvas, Rect.fromCenter(
        center: Offset(plantX + blockW / 2, midY),
        width: blockW, height: blockH),
        _plantColor, 'Plant G(s)', _plantValues());

    // Plant → Output
    _drawArrow(canvas, Offset(plantX + blockW, midY),
        Offset(outX, midY), linePaint, arrowPaint);

    // Output label
    _drawLabel(canvas, mode == LoopMode.velocity ? 'ω' : 'x',
        Offset(outX + 4, midY), _labelColor, 12);

    // ── Feedforward path (below) ──────────────────────────────────────────

    // Tap from reference line down to FF block
    final ffBlockW = blockW;
    final ffBlockH = blockH;
    final ffBlockCenterX = (sumX + sumFfX) / 2;

    // Vertical line from ref signal down to FF row
    final tapX = sumX - 20;
    canvas.drawLine(Offset(tapX, midY), Offset(tapX, ffY), linePaint);

    // Horizontal line to FF block
    _drawArrow(canvas, Offset(tapX, ffY),
        Offset(ffBlockCenterX - ffBlockW / 2, ffY), linePaint, arrowPaint);

    // FF block
    _drawBlock(canvas, Rect.fromCenter(
        center: Offset(ffBlockCenterX, ffY),
        width: ffBlockW, height: ffBlockH),
        _ffColor, 'Feedforward', _ffValues());

    // FF block → up to Σ₂
    final ffOutX = ffBlockCenterX + ffBlockW / 2;
    _drawArrow(canvas, Offset(ffOutX, ffY),
        Offset(sumFfX, ffY), linePaint, arrowPaint);
    canvas.drawLine(Offset(sumFfX, ffY), Offset(sumFfX, midY + 12), linePaint);
    _drawArrowHead(canvas, Offset(sumFfX, midY + 12), _ArrowDir.up, arrowPaint);

    // ── Feedback path (along bottom of main row) ──────────────────────────

    final fbY = midY + blockH / 2 + 18;
    // Output tap down
    final fbTapX = outX - 8;
    canvas.drawLine(Offset(fbTapX, midY), Offset(fbTapX, fbY), linePaint);

    // Horizontal feedback line back to Σ₁
    canvas.drawLine(Offset(fbTapX, fbY), Offset(sumX, fbY), linePaint);

    // Up into the summing junction
    canvas.drawLine(Offset(sumX, fbY), Offset(sumX, midY + 12), linePaint);
    _drawArrowHead(canvas, Offset(sumX, midY + 12), _ArrowDir.up, arrowPaint);

    // Feedback label
    _drawLabel(canvas, mode == LoopMode.velocity ? 'ω_meas' : 'x_meas',
        Offset(sumX + 14, fbY - 14), _labelColor, 10);

    // ── Signal labels on lines ────────────────────────────────────────────

    _drawLabel(canvas, 'e', Offset((sumX + 12 + ctrlX) / 2, midY - 14),
        _labelColor, 10);
    _drawLabel(canvas, 'u_pid', Offset((ctrlX + blockW + sumFfX - 6) / 2, midY - 14),
        _labelColor, 10);
    _drawLabel(canvas, 'u_ff', Offset(ffBlockCenterX, ffY - ffBlockH / 2 - 10),
        _ffColor, 10);
    _drawLabel(canvas, 'V', Offset((sumFfX + 12 + plantX) / 2, midY - 14),
        _labelColor, 10);

    canvas.restore();
  }

  // ── Block labels & values ──────────────────────────────────────────────

  String _controllerLabel() {
    if (mode == LoopMode.velocity) {
      return pid.kI > 0 ? 'PI Controller' : 'P Controller';
    } else {
      if (pid.kI > 0 && pid.kD > 0) return 'PID Controller';
      if (pid.kD > 0) return 'PD Controller';
      if (pid.kI > 0) return 'PI Controller';
      return 'P Controller';
    }
  }

  String _controllerValues() {
    final buf = StringBuffer();
    buf.write('kP=${pid.kP.toStringAsFixed(4)}');
    if (pid.kI > 0) buf.write('\nkI=${pid.kI.toStringAsFixed(4)}');
    if (pid.kD > 0) buf.write('\nkD=${pid.kD.toStringAsFixed(4)}');
    return buf.toString();
  }

  String _plantValues() {
    if (mode == LoopMode.velocity) {
      return '1/(${_fmt(ff.kA)}s + ${_fmt(ff.kV)})';
    } else {
      return '1/(${_fmt(ff.kA)}s² + ${_fmt(ff.kV)}s)';
    }
  }

  String _ffValues() {
    final parts = <String>[];
    parts.add('kS=${_fmt(ff.kS)}');
    parts.add('kV=${_fmt(ff.kV)}');
    if (mechanismType == MechanismType.arm) {
      parts.add('kG·cos(θ)=${_fmt(ff.kG)}');
    } else if (mechanismType == MechanismType.elevator) {
      parts.add('kG=${_fmt(ff.kG)}');
    }
    return parts.join('\n');
  }

  String _fmt(double v) => v.toStringAsFixed(4);

  // ── Drawing helpers ────────────────────────────────────────────────────

  void _drawBlock(
      Canvas canvas, Rect rect, Color color, String title, String body) {
    final bg = Paint()..color = color.withValues(alpha: isDark ? 0.25 : 0.12);
    final border = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(4));
    canvas.drawRRect(rr, bg);
    canvas.drawRRect(rr, border);

    // Title
    _drawLabel(canvas, title, Offset(rect.center.dx, rect.top + 10),
        color, 10, bold: true);

    // Body values
    _drawLabel(canvas, body, Offset(rect.center.dx, rect.center.dy + 4),
        _textColor, 9);
  }

  void _drawSum(Canvas canvas, Offset center, double r,
      String topSign, String bottomSign) {
    final circlePaint = Paint()
      ..color = _sumColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, r, circlePaint);

    // Cross inside
    canvas.drawLine(
        Offset(center.dx - r * 0.5, center.dy),
        Offset(center.dx + r * 0.5, center.dy), circlePaint);
    canvas.drawLine(
        Offset(center.dx, center.dy - r * 0.5),
        Offset(center.dx, center.dy + r * 0.5), circlePaint);

    // + / − signs outside
    _drawLabel(canvas, topSign,
        Offset(center.dx - r - 6, center.dy - r - 2), _sumColor, 9);
    _drawLabel(canvas, bottomSign,
        Offset(center.dx + r + 6, center.dy + r + 2), _sumColor, 9);
  }

  void _drawArrow(Canvas canvas, Offset from, Offset to,
      Paint linePaint, Paint arrowPaint) {
    canvas.drawLine(from, to, linePaint);
    // Determine direction
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;
    if (dx.abs() > dy.abs()) {
      _drawArrowHead(canvas, to,
          dx > 0 ? _ArrowDir.right : _ArrowDir.left, arrowPaint);
    } else {
      _drawArrowHead(canvas, to,
          dy > 0 ? _ArrowDir.down : _ArrowDir.up, arrowPaint);
    }
  }

  void _drawArrowHead(Canvas canvas, Offset tip, _ArrowDir dir, Paint paint) {
    const s = 5.0;
    final path = Path();
    switch (dir) {
      case _ArrowDir.right:
        path.moveTo(tip.dx, tip.dy);
        path.lineTo(tip.dx - s, tip.dy - s * 0.5);
        path.lineTo(tip.dx - s, tip.dy + s * 0.5);
        break;
      case _ArrowDir.left:
        path.moveTo(tip.dx, tip.dy);
        path.lineTo(tip.dx + s, tip.dy - s * 0.5);
        path.lineTo(tip.dx + s, tip.dy + s * 0.5);
        break;
      case _ArrowDir.up:
        path.moveTo(tip.dx, tip.dy);
        path.lineTo(tip.dx - s * 0.5, tip.dy + s);
        path.lineTo(tip.dx + s * 0.5, tip.dy + s);
        break;
      case _ArrowDir.down:
        path.moveTo(tip.dx, tip.dy);
        path.lineTo(tip.dx - s * 0.5, tip.dy - s);
        path.lineTo(tip.dx + s * 0.5, tip.dy - s);
        break;
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  void _drawLabel(Canvas canvas, String text, Offset pos, Color color,
      double fontSize, {bool bold = false, TextAlign align = TextAlign.center}) {
    final span = TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
        height: 1.2,
      ),
    );
    final tp = TextPainter(
      text: span,
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout();

    final dx = align == TextAlign.center
        ? pos.dx - tp.width / 2
        : align == TextAlign.right
            ? pos.dx - tp.width
            : pos.dx;
    tp.paint(canvas, Offset(dx, pos.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _BlockDiagramPainter old) =>
      old.ff != ff ||
      old.pid != pid ||
      old.mode != mode ||
      old.mechanismType != mechanismType ||
      old.isDark != isDark;
}

enum _ArrowDir { up, down, left, right }
