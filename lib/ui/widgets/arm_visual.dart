/// Animated arm mechanism visualization for the test screen.
///
/// Shows a side-view of a rotating arm with:
///   - Pivot point
///   - Current angle indication
///   - Range-of-motion arc from configured soft limits
///   - 0° horizontal reference line
///   - Zero/offset guidance tooltip
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

/// A live visualization of an arm mechanism during testing.
///
/// [currentAngleDeg] is the current arm angle in degrees (0 = horizontal).
/// [forwardLimitDeg] and [reverseLimitDeg] are the soft limits.
/// If [isDraggable] is true, the user can drag the arm to set position
/// and [onAngleChanged] is called with the new angle in degrees.
class ArmVisual extends StatelessWidget {
  final double currentAngleDeg;
  final double? forwardLimitDeg;
  final double? reverseLimitDeg;
  final bool showZeroTooltip;
  final bool isDraggable;
  final ValueChanged<double>? onAngleChanged;

  const ArmVisual({
    super.key,
    required this.currentAngleDeg,
    this.forwardLimitDeg,
    this.reverseLimitDeg,
    this.showZeroTooltip = true,
    this.isDraggable = false,
    this.onAngleChanged,
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
                'Arm Position',
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
                '${currentAngleDeg.toStringAsFixed(1)}°',
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
                final painter = _ArmPainter(
                  angleDeg: currentAngleDeg,
                  forwardLimitDeg: forwardLimitDeg,
                  reverseLimitDeg: reverseLimitDeg,
                  accentColor: theme.accentColor,
                  isDark: theme.brightness == Brightness.dark,
                );

                if (!isDraggable || onAngleChanged == null) {
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
          if (showZeroTooltip) ...[
            const SizedBox(height: 4),
            const InfoBar(
              title: Text('Zero your arm'),
              content: Text(
                'Before testing, position the arm so it is perfectly '
                'horizontal, then zero / offset the encoder. '
                '0° = horizontal to the ground.',
              ),
              severity: InfoBarSeverity.warning,
              isLong: true,
            ),
          ],
        ],
      ),
    );
  }

  void _handleDrag(Offset localPos, Size size) {
    // Pivot is at (0.25 * width, 0.55 * height) — same as _ArmPainter.
    final pivotX = size.width * 0.25;
    final pivotY = size.height * 0.55;
    final dx = localPos.dx - pivotX;
    final dy = -(localPos.dy - pivotY); // flip Y for math coords

    var angleDeg = math.atan2(dy, dx) * 180.0 / math.pi;

    // Clamp to soft limits if set.
    final minDeg = reverseLimitDeg ?? -90.0;
    final maxDeg = forwardLimitDeg ?? 90.0;
    angleDeg = angleDeg.clamp(minDeg, maxDeg);

    onAngleChanged?.call(angleDeg);
  }
}

class _ArmPainter extends CustomPainter {
  final double angleDeg;
  final double? forwardLimitDeg;
  final double? reverseLimitDeg;
  final Color accentColor;
  final bool isDark;

  _ArmPainter({
    required this.angleDeg,
    this.forwardLimitDeg,
    this.reverseLimitDeg,
    required this.accentColor,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fgColor = isDark ? const Color(0xFFDDDDDD) : const Color(0xFF333333);
    final dimColor = isDark ? const Color(0xFF666666) : const Color(0xFFAAAAAA);
    final bgColor =
        isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF5F5F5);

    // Layout: pivot at left-center, arm extends right.
    final pivotX = size.width * 0.25;
    final pivotY = size.height * 0.55;
    final pivot = Offset(pivotX, pivotY);
    final armLength = math.min(size.width * 0.55, size.height * 0.40);

    // -- Background circle (subtle) --
    final bgPaint = Paint()
      ..color = bgColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pivot, armLength + 4, bgPaint);

    // -- Range of motion arc with safety zones --
    if (forwardLimitDeg != null && reverseLimitDeg != null) {
      // Convert to radians (positive angle = CCW from horizontal-right).
      // On screen: positive angle sweeps upward (negative y).
      final fwdRad = -forwardLimitDeg! * math.pi / 180.0;
      final revRad = -reverseLimitDeg! * math.pi / 180.0;
      final totalSweep = revRad - fwdRad;
      final arcRect = Rect.fromCircle(center: pivot, radius: armLength);

      // Safety zone boundaries (fraction of total range).
      const redFrac = 0.10;
      const yellowFrac = 0.20;

      // Draw zones: red (0-10%), yellow (10-20%), green (20-80%),
      //             yellow (80-90%), red (90-100%).
      final zones = <_ZoneSpec>[
        _ZoneSpec(0.0, redFrac, const Color(0x30FF4444)),
        _ZoneSpec(redFrac, yellowFrac, const Color(0x30FFAA00)),
        _ZoneSpec(yellowFrac, 1.0 - yellowFrac, const Color(0x2044BB44)),
        _ZoneSpec(1.0 - yellowFrac, 1.0 - redFrac, const Color(0x30FFAA00)),
        _ZoneSpec(1.0 - redFrac, 1.0, const Color(0x30FF4444)),
      ];
      for (final z in zones) {
        final zStart = fwdRad + totalSweep * z.start;
        final zSweep = totalSweep * (z.end - z.start);
        final zPaint = Paint()
          ..color = z.color
          ..style = PaintingStyle.fill;
        canvas.drawArc(arcRect, zStart, zSweep, true, zPaint);
      }

      // Arc border.
      final arcBorderPaint = Paint()
        ..color = accentColor.withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawArc(arcRect, fwdRad, totalSweep, false, arcBorderPaint);

      // Limit labels.
      _drawLimitLabel(
        canvas,
        pivot,
        armLength,
        forwardLimitDeg!,
        '${forwardLimitDeg!.toStringAsFixed(0)}°',
        dimColor,
      );
      _drawLimitLabel(
        canvas,
        pivot,
        armLength,
        reverseLimitDeg!,
        '${reverseLimitDeg!.toStringAsFixed(0)}°',
        dimColor,
      );
    }

    // -- Horizontal reference line (0° = horizontal) --
    final refPaint = Paint()
      ..color = dimColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Dashed line.
    const dashLen = 5.0;
    const gapLen = 4.0;
    var dx = 0.0;
    while (dx < armLength + 10) {
      final x1 = pivotX + dx;
      final x2 = math.min(x1 + dashLen, pivotX + armLength + 10);
      canvas.drawLine(Offset(x1, pivotY), Offset(x2, pivotY), refPaint);
      dx += dashLen + gapLen;
    }

    // "0°" label at end of reference.
    _drawText(
      canvas,
      '0°',
      Offset(pivotX + armLength + 14, pivotY - 6),
      dimColor,
      10,
    );

    // -- Ground line --
    final groundPaint = Paint()
      ..color = dimColor.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    final groundY = pivotY;
    // Small ground hatch marks below pivot.
    for (var x = pivotX - 20; x <= pivotX + 20; x += 6.0) {
      canvas.drawLine(
        Offset(x, groundY + 12),
        Offset(x - 4, groundY + 18),
        groundPaint,
      );
    }
    canvas.drawLine(
      Offset(pivotX - 22, groundY + 12),
      Offset(pivotX + 22, groundY + 12),
      groundPaint,
    );

    // -- Arm --
    final angleRad = -angleDeg * math.pi / 180.0; // negative for screen coords
    final endX = pivotX + armLength * math.cos(angleRad);
    final endY = pivotY + armLength * math.sin(angleRad);
    final armEnd = Offset(endX, endY);

    // Determine arm color based on position within safety zone.
    Color armColor = accentColor;
    if (forwardLimitDeg != null && reverseLimitDeg != null) {
      final range = forwardLimitDeg! - reverseLimitDeg!;
      if (range > 0) {
        final frac = (angleDeg - reverseLimitDeg!) / range;
        if (frac < 0.10 || frac > 0.90) {
          armColor = const Color(0xFFDD3333); // red
        } else if (frac < 0.20 || frac > 0.80) {
          armColor = const Color(0xFFDD8800); // yellow/orange
        } else {
          armColor = const Color(0xFF44AA44); // green
        }
      }
    }

    final armPaint = Paint()
      ..color = armColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(pivot, armEnd, armPaint);

    // -- Weight at end of arm --
    final weightPaint = Paint()
      ..color = armColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(armEnd, 7, weightPaint);

    final weightBorderPaint = Paint()
      ..color = fgColor.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(armEnd, 7, weightBorderPaint);

    // -- Pivot point --
    final pivotFill = Paint()
      ..color = fgColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pivot, 5, pivotFill);

    final pivotRing = Paint()
      ..color = accentColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(pivot, 5, pivotRing);

    // -- Angle arc indicator --
    if (angleDeg.abs() > 0.5) {
      final indicatorRadius = armLength * 0.3;
      final indicatorPaint = Paint()
        ..color = accentColor.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      final indicatorRect =
          Rect.fromCircle(center: pivot, radius: indicatorRadius);
      // Sweep from 0 to current angle.
      final sweepAngle = -angleDeg * math.pi / 180.0;
      canvas.drawArc(indicatorRect, 0, sweepAngle, false, indicatorPaint);

      // Angle text near the arc.
      final labelAngle = sweepAngle / 2;
      final labelRadius = indicatorRadius + 12;
      _drawText(
        canvas,
        '${angleDeg.toStringAsFixed(1)}°',
        Offset(
          pivotX + labelRadius * math.cos(labelAngle) - 12,
          pivotY + labelRadius * math.sin(labelAngle) - 6,
        ),
        accentColor,
        11,
        fontWeight: FontWeight.bold,
      );
    }
  }

  void _drawLimitLabel(
    Canvas canvas,
    Offset pivot,
    double armLength,
    double limitDeg,
    String label,
    Color color,
  ) {
    final rad = -limitDeg * math.pi / 180.0;
    final endX = pivot.dx + (armLength + 16) * math.cos(rad);
    final endY = pivot.dy + (armLength + 16) * math.sin(rad);

    // Limit line (thin).
    final limitPaint = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawLine(
      pivot,
      Offset(
        pivot.dx + armLength * math.cos(rad),
        pivot.dy + armLength * math.sin(rad),
      ),
      limitPaint,
    );

    _drawText(canvas, label, Offset(endX - 10, endY - 6), color, 9);
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
  bool shouldRepaint(covariant _ArmPainter old) =>
      angleDeg != old.angleDeg ||
      forwardLimitDeg != old.forwardLimitDeg ||
      reverseLimitDeg != old.reverseLimitDeg ||
      isDark != old.isDark;
}

/// Describes a colored zone within a range (fraction 0..1).
class _ZoneSpec {
  final double start;
  final double end;
  final Color color;
  const _ZoneSpec(this.start, this.end, this.color);
}
