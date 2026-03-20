/// Animated PID step-response diagram.
///
/// Shows P, I, D contributions and the combined response
/// approaching a setpoint using [CustomPaint] animation.
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

/// Animated step-response plot illustrating PID controller behavior.
class PidResponseDiagram extends StatefulWidget {
  const PidResponseDiagram({super.key});

  @override
  State<PidResponseDiagram> createState() => _PidResponseDiagramState();
}

class _PidResponseDiagramState extends State<PidResponseDiagram>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final textColor = theme.typography.body?.color ?? Colors.white;

    return SizedBox(
      height: 150,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _PidResponsePainter(
            progress: _controller.value,
            textColor: textColor,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _PidResponsePainter extends CustomPainter {
  final double progress;
  final Color textColor;

  _PidResponsePainter({required this.progress, required this.textColor});

  @override
  void paint(Canvas canvas, Size size) {
    const ml = 40.0;
    const mb = 24.0;
    const mt = 12.0;
    const mr = 12.0;
    final plotW = size.width - ml - mr;
    final plotH = size.height - mt - mb;

    final axisPaint = Paint()
      ..color = textColor.withValues(alpha: 0.3)
      ..strokeWidth = 1;

    // Axes
    canvas.drawLine(Offset(ml, mt), Offset(ml, mt + plotH), axisPaint);
    canvas.drawLine(
      Offset(ml, mt + plotH),
      Offset(ml + plotW, mt + plotH),
      axisPaint,
    );

    // Setpoint line (dashed)
    final spY = mt + plotH * 0.2;
    final spPaint = Paint()
      ..color = textColor.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    _drawDashedLine(
      canvas,
      Offset(ml, spY),
      Offset(ml + plotW, spY),
      spPaint,
    );

    // Setpoint label
    _drawLabel(
      canvas,
      'Setpoint',
      Offset(ml + plotW - 25, spY - 10),
      TextStyle(color: textColor.withValues(alpha: 0.6), fontSize: 9),
    );

    // PID response: damped oscillation converging to setpoint
    // y(t) = 1 - e^(-ζωt)(cos(ωd·t) + (ζω/ωd)sin(ωd·t))
    final responsePaint = Paint()
      ..color = const Color(0xFF4488FF)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final baseY = mt + plotH; // y=0 line
    final amplitude = plotH * 0.8; // full scale
    final samples = (plotW * progress).toInt().clamp(1, plotW.toInt());

    final path = Path();
    for (var i = 0; i <= samples; i++) {
      final t = i / plotW * 5; // time scale
      final y = _pidResponse(t);
      final px = ml + i;
      final py = baseY - amplitude * y;

      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
    }
    canvas.drawPath(path, responsePaint);

    // Labels
    final labelStyle = TextStyle(color: textColor, fontSize: 9);
    _drawLabel(
      canvas,
      'Output',
      Offset(ml - 5, mt + plotH / 2),
      labelStyle,
      rotate: true,
    );
    _drawLabel(
      canvas,
      'Time',
      Offset(ml + plotW / 2, mt + plotH + 14),
      labelStyle,
    );

    // Legend
    _drawLabel(
      canvas,
      'PID Response',
      Offset(ml + 50, mt + 2),
      TextStyle(
        color: const Color(0xFF4488FF),
        fontSize: 9,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  /// Second-order underdamped response: zeta=0.3, omega=3
  double _pidResponse(double t) {
    const zeta = 0.3;
    const omega = 3.0;
    final omegaD = omega * math.sqrt(1 - zeta * zeta);
    final envelope = math.exp(-zeta * omega * t);
    final oscillation = math.cos(omegaD * t) +
        (zeta * omega / omegaD) * math.sin(omegaD * t);
    return (1 - envelope * oscillation).clamp(0.0, 1.5);
  }

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    const dashLen = 5.0;
    const gapLen = 3.0;
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final dist = math.sqrt(dx * dx + dy * dy);
    final ux = dx / dist;
    final uy = dy / dist;
    var d = 0.0;
    while (d < dist) {
      final start = Offset(a.dx + ux * d, a.dy + uy * d);
      final end = Offset(
        a.dx + ux * math.min(d + dashLen, dist),
        a.dy + uy * math.min(d + dashLen, dist),
      );
      canvas.drawLine(start, end, paint);
      d += dashLen + gapLen;
    }
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Offset position,
    TextStyle style, {
    bool rotate = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    if (rotate) {
      canvas.save();
      canvas.translate(position.dx, position.dy);
      canvas.rotate(-math.pi / 2);
      tp.paint(canvas, Offset(-tp.width / 2, -tp.height / 2));
      canvas.restore();
    } else {
      tp.paint(canvas, position - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _PidResponsePainter old) =>
      progress != old.progress || textColor != old.textColor;
}
