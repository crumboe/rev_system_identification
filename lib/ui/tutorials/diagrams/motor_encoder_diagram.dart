/// Diagram of a NEO motor with built-in encoder.
///
/// Renders a labeled cutaway of a brushless motor and Hall-effect
/// encoder using [CustomPaint].
library;

import 'package:fluent_ui/fluent_ui.dart';

/// A simplified illustration of a NEO motor and its encoder assembly.
class MotorEncoderDiagram extends StatelessWidget {
  const MotorEncoderDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return SizedBox(
      height: 180,
      child: CustomPaint(
        painter: _MotorEncoderPainter(
          textColor: theme.typography.body?.color ?? Colors.white,
          isDark: theme.brightness == Brightness.dark,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _MotorEncoderPainter extends CustomPainter {
  final Color textColor;
  final bool isDark;

  _MotorEncoderPainter({required this.textColor, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // Motor body
    final motorPaint = Paint()
      ..color = isDark
          ? const Color(0xFF3A3A3A)
          : const Color(0xFFD0D0D0)
      ..style = PaintingStyle.fill;
    final motorRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx - 20, cy), width: 120, height: 90),
      const Radius.circular(8),
    );
    canvas.drawRRect(motorRect, motorPaint);

    // Motor outline
    final outlinePaint = Paint()
      ..color = textColor.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(motorRect, outlinePaint);

    // Shaft
    final shaftPaint = Paint()
      ..color = isDark
          ? const Color(0xFF888888)
          : const Color(0xFF666666)
      ..style = PaintingStyle.fill
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(cx + 40, cy),
      Offset(cx + 80, cy),
      shaftPaint..strokeWidth = 6,
    );

    // Encoder housing (rear)
    final encoderPaint = Paint()
      ..color = isDark
          ? const Color(0xFF2255AA)
          : const Color(0xFF4488DD)
      ..style = PaintingStyle.fill;
    final encoderRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx - 90, cy), width: 30, height: 50),
      const Radius.circular(4),
    );
    canvas.drawRRect(encoderRect, encoderPaint);
    canvas.drawRRect(encoderRect, outlinePaint);

    // Phase wires (3)
    final wireColors = [
      const Color(0xFFFF4444),
      const Color(0xFF44FF44),
      const Color(0xFF4488FF),
    ];
    for (var i = 0; i < 3; i++) {
      final wirePaint = Paint()
        ..color = wireColors[i]
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      final startY = cy - 20 + i * 20.0;
      canvas.drawLine(
        Offset(cx - 80, startY),
        Offset(cx - 110, startY),
        wirePaint,
      );
    }

    // Labels
    final labelStyle = TextStyle(
      color: textColor,
      fontSize: 11,
      fontWeight: FontWeight.w500,
    );

    _drawLabel(canvas, 'Motor Body', Offset(cx - 20, cy + 55), labelStyle);
    _drawLabel(canvas, 'Encoder', Offset(cx - 90, cy + 35), labelStyle);
    _drawLabel(canvas, 'Shaft', Offset(cx + 60, cy - 15), labelStyle);
    _drawLabel(
      canvas,
      '3 Phase Wires',
      Offset(cx - 135, cy - 30),
      labelStyle,
    );
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
  bool shouldRepaint(covariant _MotorEncoderPainter old) =>
      textColor != old.textColor || isDark != old.isDark;
}
