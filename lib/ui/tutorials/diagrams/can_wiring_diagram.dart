/// Diagram of a CAN bus wiring chain with SPARKs.
///
/// Shows a daisy-chained CAN topology with high/low traces,
/// termination resistors, and device labels.
library;

import 'package:fluent_ui/fluent_ui.dart';

/// CAN wiring diagram showing SPARK controllers in a chain.
class CanWiringDiagram extends StatelessWidget {
  const CanWiringDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return SizedBox(
      height: 160,
      child: CustomPaint(
        painter: _CanWiringPainter(
          textColor: theme.typography.body?.color ?? Colors.white,
          isDark: theme.brightness == Brightness.dark,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _CanWiringPainter extends CustomPainter {
  final Color textColor;
  final bool isDark;

  _CanWiringPainter({required this.textColor, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final boxW = 60.0;
    final boxH = 50.0;
    final spacing = (size.width - 40) / 3;

    final canHPaint = Paint()
      ..color = const Color(0xFFFFCC00)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final canLPaint = Paint()
      ..color = const Color(0xFF44BB44)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final boxPaint = Paint()
      ..color = isDark
          ? const Color(0xFF2A2A2A)
          : const Color(0xFFE8E8E8)
      ..style = PaintingStyle.fill;
    final outlinePaint = Paint()
      ..color = textColor.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    final labelStyle = TextStyle(
      color: textColor,
      fontSize: 10,
      fontWeight: FontWeight.w500,
    );
    final traceStyle = TextStyle(
      fontSize: 9,
      fontWeight: FontWeight.bold,
    );

    final labels = ['roboRIO', 'SPARK #1', 'SPARK #2'];

    for (var i = 0; i < 3; i++) {
      final cx = 20 + spacing * i + spacing / 2;

      // Device box
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy),
          width: boxW,
          height: boxH,
        ),
        const Radius.circular(6),
      );
      canvas.drawRRect(rect, boxPaint);
      canvas.drawRRect(rect, outlinePaint);

      // Device label
      _drawLabel(canvas, labels[i], Offset(cx, cy), labelStyle);

      // CAN traces to next device
      if (i < 2) {
        final x1 = cx + boxW / 2;
        final x2 = 20 + spacing * (i + 1) + spacing / 2 - boxW / 2;
        // CAN-H (yellow)
        canvas.drawLine(
          Offset(x1, cy - 8),
          Offset(x2, cy - 8),
          canHPaint,
        );
        // CAN-L (green)
        canvas.drawLine(
          Offset(x1, cy + 8),
          Offset(x2, cy + 8),
          canLPaint,
        );
      }
    }

    // Termination resistor at end
    final lastCx = 20 + spacing * 2 + spacing / 2;
    final termX = lastCx + boxW / 2 + 15;
    final termPaint = Paint()
      ..color = textColor.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Zigzag resistor symbol
    canvas.drawLine(Offset(lastCx + boxW / 2, cy - 8), Offset(termX, cy - 8), canHPaint);
    canvas.drawLine(Offset(lastCx + boxW / 2, cy + 8), Offset(termX, cy + 8), canLPaint);
    _drawZigzag(canvas, Offset(termX, cy - 8), Offset(termX, cy + 8), termPaint);

    // Legend
    _drawLabel(
      canvas,
      'CAN-H',
      Offset(size.width / 2 - 30, cy + boxH / 2 + 18),
      traceStyle.copyWith(color: const Color(0xFFFFCC00)),
    );
    _drawLabel(
      canvas,
      'CAN-L',
      Offset(size.width / 2 + 30, cy + boxH / 2 + 18),
      traceStyle.copyWith(color: const Color(0xFF44BB44)),
    );
    _drawLabel(
      canvas,
      '120Ω',
      Offset(termX + 2, cy + 20),
      labelStyle,
    );
  }

  void _drawZigzag(Canvas canvas, Offset top, Offset bottom, Paint paint) {
    final path = Path()..moveTo(top.dx, top.dy);
    final segments = 4;
    final dy = (bottom.dy - top.dy) / segments;
    for (var i = 0; i < segments; i++) {
      final y = top.dy + dy * i;
      final xOff = (i.isEven) ? -4.0 : 4.0;
      path.lineTo(top.dx + xOff, y + dy / 2);
      path.lineTo(top.dx, y + dy);
    }
    canvas.drawPath(path, paint);
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Offset position,
    TextStyle style,
  ) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, position - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _CanWiringPainter old) =>
      textColor != old.textColor || isDark != old.isDark;
}
