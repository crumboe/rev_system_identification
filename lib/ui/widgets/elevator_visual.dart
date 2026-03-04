/// Animated elevator mechanism visualization for the test screen.
///
/// Shows a side-view of a linear elevator with:
///   - Two vertical rails
///   - A moving carriage/platform
///   - Range indicators from configured soft limits
///   - Current height readout
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

/// A live visualization of an elevator mechanism during testing.
///
/// [currentPositionIn] is the current height in inches.
/// [forwardLimitIn] and [reverseLimitIn] are the soft limits (top/bottom).
/// If [isDraggable] is true, the user can drag the carriage to set position
/// and [onPositionChanged] is called with the new height in inches.
class ElevatorVisual extends StatelessWidget {
  final double currentPositionIn;
  final double? forwardLimitIn;
  final double? reverseLimitIn;
  final bool isDraggable;
  final ValueChanged<double>? onPositionChanged;

  const ElevatorVisual({
    super.key,
    required this.currentPositionIn,
    this.forwardLimitIn,
    this.reverseLimitIn,
    this.isDraggable = false,
    this.onPositionChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Elevator Position',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (isDraggable) ...[
                const SizedBox(width: 6),
                Text(
                  '(drag to set)',
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.inactiveColor,
                  ),
                ),
              ],
              const Spacer(),
              Text(
                '${currentPositionIn.toStringAsFixed(1)} in',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: theme.accentColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                final painter = _ElevatorPainter(
                  positionIn: currentPositionIn,
                  forwardLimitIn: forwardLimitIn,
                  reverseLimitIn: reverseLimitIn,
                  accentColor: theme.accentColor,
                  isDark: theme.brightness == Brightness.dark,
                );

                if (!isDraggable || onPositionChanged == null) {
                  return CustomPaint(size: size, painter: painter);
                }

                return GestureDetector(
                  onPanUpdate: (details) {
                    _handleDrag(details.localPosition, size);
                  },
                  onTapDown: (details) {
                    _handleDrag(details.localPosition, size);
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: CustomPaint(size: size, painter: painter),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _handleDrag(Offset localPos, Size size) {
    // Layout matches _ElevatorPainter.
    final railTop = size.height * 0.06;
    final railBottom = size.height * 0.88;
    final railHeight = railBottom - railTop;

    final minIn = reverseLimitIn ?? 0.0;
    final maxIn = forwardLimitIn ?? 48.0;

    // Map Y to position (top = max, bottom = min).
    final frac = ((railBottom - localPos.dy) / railHeight).clamp(0.0, 1.0);
    final posIn = minIn + frac * (maxIn - minIn);

    onPositionChanged?.call(posIn);
  }
}

class _ElevatorPainter extends CustomPainter {
  final double positionIn;
  final double? forwardLimitIn;
  final double? reverseLimitIn;
  final Color accentColor;
  final bool isDark;

  _ElevatorPainter({
    required this.positionIn,
    this.forwardLimitIn,
    this.reverseLimitIn,
    required this.accentColor,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fgColor = isDark ? const Color(0xFFDDDDDD) : const Color(0xFF333333);
    final dimColor = isDark ? const Color(0xFF666666) : const Color(0xFFAAAAAA);

    // --- Layout dimensions ---
    final railLeft = size.width * 0.35;
    final railRight = size.width * 0.65;
    final railTop = size.height * 0.06;
    final railBottom = size.height * 0.88;
    final railHeight = railBottom - railTop;
    final carriageWidth = railRight - railLeft;

    // Determine range for mapping position to pixels.
    final minIn = reverseLimitIn ?? 0.0;
    final maxIn = forwardLimitIn ?? math.max(48.0, positionIn + 5);
    final rangeIn = (maxIn - minIn).clamp(1.0, double.infinity);

    // Map position to Y (bottom = minIn, top = maxIn).
    double posToY(double inches) {
      final frac = (inches - minIn) / rangeIn;
      return railBottom - frac * railHeight;
    }

    // -- Rails --
    final railPaint = Paint()
      ..color = dimColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawLine(Offset(railLeft, railTop), Offset(railLeft, railBottom), railPaint);
    canvas.drawLine(Offset(railRight, railTop), Offset(railRight, railBottom), railPaint);

    // -- Cross braces (decorative) --
    final bracePaint = Paint()
      ..color = dimColor.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    const braceCount = 6;
    for (var i = 0; i <= braceCount; i++) {
      final y = railTop + (railHeight / braceCount) * i;
      canvas.drawLine(Offset(railLeft, y), Offset(railRight, y), bracePaint);
    }

    // -- Tick marks and labels on the left side --
    final tickPaint = Paint()
      ..color = dimColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Choose a nice tick interval.
    final tickInterval = _niceInterval(rangeIn, 6);
    var tickVal = (minIn / tickInterval).ceil() * tickInterval;
    while (tickVal <= maxIn) {
      final y = posToY(tickVal);
      if (y >= railTop - 2 && y <= railBottom + 2) {
        canvas.drawLine(
          Offset(railLeft - 8, y),
          Offset(railLeft - 2, y),
          tickPaint,
        );
        _drawText(
          canvas,
          '${tickVal.toStringAsFixed(0)}"',
          Offset(railLeft - 36, y - 6),
          dimColor,
          9,
        );
      }
      tickVal += tickInterval;
    }

    // -- Soft limit indicators --
    if (forwardLimitIn != null) {
      final y = posToY(forwardLimitIn!);
      _drawLimitLine(canvas, y, railLeft, railRight, 'MAX', fgColor);
    }
    if (reverseLimitIn != null) {
      final y = posToY(reverseLimitIn!);
      _drawLimitLine(canvas, y, railLeft, railRight, 'MIN', fgColor);
    }

    // -- Range fill --
    if (forwardLimitIn != null && reverseLimitIn != null) {
      final topY = posToY(forwardLimitIn!);
      final botY = posToY(reverseLimitIn!);
      final rangeFill = Paint()
        ..color = accentColor.withValues(alpha: 0.08)
        ..style = PaintingStyle.fill;
      canvas.drawRect(
        Rect.fromLTRB(railLeft, topY, railRight, botY),
        rangeFill,
      );
    }

    // -- Carriage --
    final carriageY = posToY(positionIn);
    const carriageH = 14.0;
    final carriageRect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset((railLeft + railRight) / 2, carriageY),
        width: carriageWidth + 8,
        height: carriageH,
      ),
      const Radius.circular(3),
    );

    final carriageFill = Paint()
      ..color = accentColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(carriageRect, carriageFill);

    final carriageBorder = Paint()
      ..color = fgColor.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(carriageRect, carriageBorder);

    // Carriage grip lines.
    final gripPaint = Paint()
      ..color = (isDark ? Colors.black : Colors.white).withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    for (var dy = -3.0; dy <= 3.0; dy += 3.0) {
      canvas.drawLine(
        Offset(railLeft + 8, carriageY + dy),
        Offset(railRight - 8, carriageY + dy),
        gripPaint,
      );
    }

    // -- Cable from carriage to top --
    final cablePaint = Paint()
      ..color = dimColor.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final cableX = (railLeft + railRight) / 2;
    canvas.drawLine(
      Offset(cableX, carriageY - carriageH / 2),
      Offset(cableX, railTop - 4),
      cablePaint,
    );

    // -- Pulley at top --
    final pulleyPaint = Paint()
      ..color = fgColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cableX, railTop - 4), 4, pulleyPaint);

    // -- Ground hatch below rails --
    final groundPaint = Paint()
      ..color = dimColor.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    final groundY = railBottom + 4;
    canvas.drawLine(
      Offset(railLeft - 10, groundY),
      Offset(railRight + 10, groundY),
      groundPaint,
    );
    for (var x = railLeft - 10; x <= railRight + 10; x += 6.0) {
      canvas.drawLine(
        Offset(x, groundY),
        Offset(x - 4, groundY + 6),
        groundPaint,
      );
    }

    // -- Height label next to carriage --
    _drawText(
      canvas,
      '${positionIn.toStringAsFixed(1)}"',
      Offset(railRight + 12, carriageY - 7),
      accentColor,
      12,
      fontWeight: FontWeight.bold,
    );
  }

  void _drawLimitLine(
    Canvas canvas,
    double y,
    double left,
    double right,
    String label,
    Color color,
  ) {
    final paint = Paint()
      ..color = Colors.warningPrimaryColor.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    // Dashed line.
    const dashLen = 4.0;
    const gapLen = 3.0;
    var x = left - 4;
    while (x < right + 4) {
      final x2 = math.min(x + dashLen, right + 4);
      canvas.drawLine(Offset(x, y), Offset(x2, y), paint);
      x += dashLen + gapLen;
    }

    _drawText(
      canvas,
      label,
      Offset(right + 12, y - 5),
      Colors.warningPrimaryColor,
      8,
      fontWeight: FontWeight.bold,
    );
  }

  /// Choose a "nice" tick interval for [range] given roughly [targetTicks].
  double _niceInterval(double range, int targetTicks) {
    final rough = range / targetTicks;
    final pow10 = math.pow(10, (math.log(rough) / math.ln10).floor());
    final frac = rough / pow10;
    final nice = frac < 1.5
        ? 1.0
        : frac < 3
            ? 2.0
            : frac < 7
                ? 5.0
                : 10.0;
    return nice * pow10;
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
    double fontSize, {
    FontWeight fontWeight = FontWeight.normal,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _ElevatorPainter old) =>
      positionIn != old.positionIn ||
      forwardLimitIn != old.forwardLimitIn ||
      reverseLimitIn != old.reverseLimitIn ||
      isDark != old.isDark;
}
