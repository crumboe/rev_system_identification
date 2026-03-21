/// Diagram of a power distribution circuit.
///
/// Renders PDB → breaker → SPARK → motor path using [CustomPaint].
library;

import 'package:fluent_ui/fluent_ui.dart';

/// Power distribution schematic from battery to motor.
class PowerDistributionDiagram extends StatelessWidget {
  const PowerDistributionDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return SizedBox(
      height: 140,
      child: CustomPaint(
        painter: _PowerDistPainter(
          textColor: theme.typography.body?.color ?? Colors.white,
          isDark: theme.brightness == Brightness.dark,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _PowerDistPainter extends CustomPainter {
  final Color textColor;
  final bool isDark;

  _PowerDistPainter({required this.textColor, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final stages = ['Battery', 'PDB', 'Breaker', 'SPARK', 'Motor'];
    final stageCount = stages.length;
    final spacing = (size.width - 40) / stageCount;

    final wirePaint = Paint()
      ..color = const Color(0xFFFF4444)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final gndPaint = Paint()
      ..color = textColor.withValues(alpha: 0.4)
      ..strokeWidth = 1.5
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
    final voltageStyle = TextStyle(
      color: const Color(0xFFFF8800),
      fontSize: 9,
      fontWeight: FontWeight.bold,
    );

    for (var i = 0; i < stageCount; i++) {
      final cx = 20 + spacing * i + spacing / 2;
      final boxW = i == 0 ? 50.0 : 55.0;
      const boxH = 40.0;

      // Box
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy), width: boxW, height: boxH),
        const Radius.circular(5),
      );
      canvas.drawRRect(rect, boxPaint);
      canvas.drawRRect(rect, outlinePaint);

      // Label
      _drawLabel(canvas, stages[i], Offset(cx, cy), labelStyle);

      // Wire to next
      if (i < stageCount - 1) {
        final x1 = cx + boxW / 2;
        final nextCx = 20 + spacing * (i + 1) + spacing / 2;
        final nextBoxW = (i + 1 == 0) ? 50.0 : 55.0;
        final x2 = nextCx - nextBoxW / 2;
        // Power (red, top)
        canvas.drawLine(Offset(x1, cy - 6), Offset(x2, cy - 6), wirePaint);
        // Ground (gray, bottom)
        canvas.drawLine(Offset(x1, cy + 6), Offset(x2, cy + 6), gndPaint);
      }
    }

    // Voltage annotations
    final battCx = 20 + spacing / 2;
    _drawLabel(canvas, '12V', Offset(battCx, cy - 30), voltageStyle);

    final sparkCx = 20 + spacing * 3 + spacing / 2;
    _drawLabel(canvas, '0–12V', Offset(sparkCx, cy - 30), voltageStyle);

    // Legend
    _drawLabel(
      canvas,
      'V+ (red)  GND (gray)',
      Offset(size.width / 2, cy + 35),
      labelStyle.copyWith(fontSize: 9),
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
  bool shouldRepaint(covariant _PowerDistPainter old) =>
      textColor != old.textColor || isDark != old.isDark;
}
