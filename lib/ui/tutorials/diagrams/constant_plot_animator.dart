/// Animated mini-graph visualizers for feedforward constants.
///
/// Each [ConstantType] renders an animated FL-Chart-style plot
/// using [CustomPaint] + [AnimationController] to illustrate
/// what the constant physically represents.
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

/// Which feedforward constant to visualize.
enum ConstantType { kS, kV, kA, kG }

/// Animated mini-plot for a feedforward constant.
class ConstantPlotAnimator extends StatefulWidget {
  final ConstantType type;

  const ConstantPlotAnimator({super.key, required this.type});

  @override
  State<ConstantPlotAnimator> createState() => _ConstantPlotAnimatorState();
}

class _ConstantPlotAnimatorState extends State<ConstantPlotAnimator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
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
    final accentColor = theme.accentColor;
    final isDark = theme.brightness == Brightness.dark;

    return SizedBox(
      height: 150,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _ConstantPlotPainter(
            type: widget.type,
            progress: _controller.value,
            textColor: textColor,
            accentColor: accentColor,
            isDark: isDark,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _ConstantPlotPainter extends CustomPainter {
  final ConstantType type;
  final double progress;
  final Color textColor;
  final Color accentColor;
  final bool isDark;

  _ConstantPlotPainter({
    required this.type,
    required this.progress,
    required this.textColor,
    required this.accentColor,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final axisPaint = Paint()
      ..color = textColor.withValues(alpha: 0.3)
      ..strokeWidth = 1;
    final plotPaint = Paint()
      ..color = accentColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final fillPaint = Paint()
      ..color = accentColor.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;

    // Plotting area with margins
    const ml = 40.0; // left margin for Y label
    const mb = 24.0; // bottom margin for X label
    const mt = 8.0;
    const mr = 12.0;
    final plotW = size.width - ml - mr;
    final plotH = size.height - mt - mb;

    // Axes
    canvas.drawLine(Offset(ml, mt), Offset(ml, mt + plotH), axisPaint);
    canvas.drawLine(
      Offset(ml, mt + plotH),
      Offset(ml + plotW, mt + plotH),
      axisPaint,
    );

    switch (type) {
      case ConstantType.kS:
        _paintKs(canvas, ml, mt, plotW, plotH, plotPaint, fillPaint);
      case ConstantType.kV:
        _paintKv(canvas, ml, mt, plotW, plotH, plotPaint);
      case ConstantType.kA:
        _paintKa(canvas, ml, mt, plotW, plotH, plotPaint);
      case ConstantType.kG:
        _paintKg(canvas, ml, mt, plotW, plotH, plotPaint);
    }

    // Axis labels
    final labelStyle = TextStyle(color: textColor, fontSize: 9);
    switch (type) {
      case ConstantType.kS:
        _drawLabel(canvas, 'Voltage', Offset(ml - 5, mt + plotH / 2), labelStyle, rotate: true);
        _drawLabel(canvas, 'Time', Offset(ml + plotW / 2, mt + plotH + 14), labelStyle);
        _drawLabel(canvas, 'kS = static friction voltage', Offset(ml + plotW / 2, mt - 2), labelStyle);
      case ConstantType.kV:
        _drawLabel(canvas, 'Voltage', Offset(ml - 5, mt + plotH / 2), labelStyle, rotate: true);
        _drawLabel(canvas, 'Velocity', Offset(ml + plotW / 2, mt + plotH + 14), labelStyle);
        _drawLabel(canvas, 'kV × velocity', Offset(ml + plotW / 2, mt - 2), labelStyle);
      case ConstantType.kA:
        _drawLabel(canvas, 'Voltage', Offset(ml - 5, mt + plotH / 2), labelStyle, rotate: true);
        _drawLabel(canvas, 'Acceleration', Offset(ml + plotW / 2, mt + plotH + 14), labelStyle);
        _drawLabel(canvas, 'kA × acceleration', Offset(ml + plotW / 2, mt - 2), labelStyle);
      case ConstantType.kG:
        _drawLabel(canvas, 'Voltage', Offset(ml - 5, mt + plotH / 2), labelStyle, rotate: true);
        _drawLabel(canvas, 'Angle', Offset(ml + plotW / 2, mt + plotH + 14), labelStyle);
        _drawLabel(canvas, 'kG × cos(θ)', Offset(ml + plotW / 2, mt - 2), labelStyle);
    }
  }

  /// kS: horizontal line at friction voltage with dead zone shaded below.
  void _paintKs(
    Canvas canvas,
    double ml,
    double mt,
    double plotW,
    double plotH,
    Paint linePaint,
    Paint fillPaint,
  ) {
    final ksY = mt + plotH * 0.35; // kS level
    final animX = ml + plotW * progress;

    // Dead zone fill
    final deadZone = Rect.fromLTRB(ml, ksY, ml + plotW, mt + plotH);
    canvas.drawRect(deadZone, fillPaint);

    // kS line (dashed effect: draw up to animated point)
    final dashPaint = Paint()
      ..color = linePaint.color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(ml, ksY), Offset(animX, ksY), dashPaint);

    // Moving dot
    canvas.drawCircle(
      Offset(animX, ksY),
      4,
      Paint()..color = linePaint.color,
    );
  }

  /// kV: linear voltage vs velocity — animated dot travelling along the line.
  void _paintKv(
    Canvas canvas,
    double ml,
    double mt,
    double plotW,
    double plotH,
    Paint linePaint,
  ) {
    final origin = Offset(ml, mt + plotH);
    final endPt = Offset(ml + plotW, mt + plotH * 0.1);

    canvas.drawLine(origin, endPt, linePaint);

    // Animated dot
    final t = progress;
    final dotX = origin.dx + (endPt.dx - origin.dx) * t;
    final dotY = origin.dy + (endPt.dy - origin.dy) * t;
    canvas.drawCircle(
      Offset(dotX, dotY),
      4,
      Paint()..color = linePaint.color,
    );
  }

  /// kA: steeper linear voltage vs acceleration.
  void _paintKa(
    Canvas canvas,
    double ml,
    double mt,
    double plotW,
    double plotH,
    Paint linePaint,
  ) {
    final origin = Offset(ml, mt + plotH);
    final endPt = Offset(ml + plotW * 0.6, mt + plotH * 0.05);

    canvas.drawLine(origin, endPt, linePaint);

    final t = progress;
    final dotX = origin.dx + (endPt.dx - origin.dx) * t;
    final dotY = origin.dy + (endPt.dy - origin.dy) * t;
    canvas.drawCircle(
      Offset(dotX, dotY),
      4,
      Paint()..color = linePaint.color,
    );

    // Extend dashed plateau
    final dashPaint = Paint()
      ..color = linePaint.color.withValues(alpha: 0.4)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(endPt, Offset(ml + plotW, endPt.dy), dashPaint);
  }

  /// kG: cosine curve for arm gravity compensation.
  void _paintKg(
    Canvas canvas,
    double ml,
    double mt,
    double plotW,
    double plotH,
    Paint linePaint,
  ) {
    final path = Path();
    final midY = mt + plotH / 2;
    final amp = plotH * 0.4;

    for (var i = 0; i <= 100; i++) {
      final t = i / 100.0;
      final x = ml + plotW * t;
      final y = midY - amp * math.cos(t * 2 * math.pi);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, linePaint);

    // Animated dot along curve
    final x = ml + plotW * progress;
    final y = midY - amp * math.cos(progress * 2 * math.pi);
    canvas.drawCircle(
      Offset(x, y),
      4,
      Paint()..color = linePaint.color,
    );
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
  bool shouldRepaint(covariant _ConstantPlotPainter old) =>
      progress != old.progress ||
      type != old.type ||
      textColor != old.textColor;
}
