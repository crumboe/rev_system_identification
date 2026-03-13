/// Animated flywheel mechanism visualization for simulated testing.
///
/// Shows a profile-view FRC style wheel with a fixed index marker and a
/// rotating black notch that indicates the start of each revolution.
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

/// A live visualization of a flywheel or simple rotating mechanism.
///
/// [currentRotations] is the current position in user units (rotations).
/// If [isDraggable] is true, the user can drag around the wheel face to
/// set the rotation and [onRotationChanged] is called with the new value.
class FlywheelVisual extends StatelessWidget {
  final double currentRotations;
  final bool isDraggable;
  final ValueChanged<double>? onRotationChanged;

  const FlywheelVisual({
    super.key,
    required this.currentRotations,
    this.isDraggable = false,
    this.onRotationChanged,
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
                'Flywheel Position',
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
                '${currentRotations.toStringAsFixed(2)} rev',
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
                final painter = _FlywheelPainter(
                  rotations: currentRotations,
                  accentColor: theme.accentColor,
                  isDark: theme.brightness == Brightness.dark,
                );

                if (!isDraggable || onRotationChanged == null) {
                  return CustomPaint(size: size, painter: painter);
                }

                return GestureDetector(
                  onPanUpdate: (details) =>
                      _handleDrag(details.localPosition, size),
                  onTapDown: (details) =>
                      _handleDrag(details.localPosition, size),
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
    final center = Offset(size.width * 0.5, size.height * 0.58);
    final dx = localPos.dx - center.dx;
    final dy = localPos.dy - center.dy;
    if (dx.abs() + dy.abs() < 1e-3) return;

    final angle = math.atan2(dy, dx);
    var frac = (angle + math.pi / 2.0) / (2.0 * math.pi);
    frac = frac % 1.0;
    if (frac < 0) frac += 1.0;

    final baseTurns = currentRotations.floorToDouble();
    onRotationChanged?.call(baseTurns + frac);
  }
}

class _FlywheelPainter extends CustomPainter {
  final double rotations;
  final Color accentColor;
  final bool isDark;

  _FlywheelPainter({
    required this.rotations,
    required this.accentColor,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fgColor = isDark ? const Color(0xFFDDDDDD) : const Color(0xFF222222);
    final dimColor = isDark ? const Color(0xFF666666) : const Color(0xFF999999);
    final hubColor = isDark ? const Color(0xFF8A8F98) : const Color(0xFFDDE2EA);

    final center = Offset(size.width * 0.5, size.height * 0.58);
    final outerR = math.min(size.width * 0.34, size.height * 0.34);
    final innerR = outerR * 0.58;

    // Profile stand / frame behind the wheel.
    final framePaint = Paint()
      ..color = dimColor.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final frameRect = Rect.fromCenter(
      center: Offset(center.dx, center.dy + outerR * 0.15),
      width: outerR * 2.4,
      height: outerR * 1.6,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(frameRect, const Radius.circular(10)),
      framePaint,
    );

    // Fixed revolution-start index marker at top center.
    final markerPaint = Paint()
      ..color = fgColor
      ..style = PaintingStyle.fill;
    final markerY = center.dy - outerR - 10;
    final markerPath = Path()
      ..moveTo(center.dx - 7, markerY)
      ..lineTo(center.dx + 7, markerY)
      ..lineTo(center.dx, markerY + 11)
      ..close();
    canvas.drawPath(markerPath, markerPaint);

    // Wheel outer tire.
    final tirePaint = Paint()
      ..color = isDark ? const Color(0xFF78A9D6) : const Color(0xFF9FD3FF)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, outerR, tirePaint);

    // Wheel face.
    final facePaint = Paint()
      ..color = hubColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, innerR, facePaint);

    // Spokes rotate with wheel.
    final frac = rotations - rotations.floorToDouble();
    final wheelPhase = -math.pi / 2 + frac * 2.0 * math.pi;
    final spokePaint = Paint()
      ..color = isDark ? const Color(0xFFC7CDD6) : const Color(0xFFB8BEC7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6;
    for (var i = 0; i < 6; i++) {
      final a = wheelPhase + i * (2.0 * math.pi / 6.0);
      final p1 = Offset(center.dx + math.cos(a) * (innerR * 0.35),
          center.dy + math.sin(a) * (innerR * 0.35));
      final p2 = Offset(center.dx + math.cos(a) * (innerR * 0.93),
          center.dy + math.sin(a) * (innerR * 0.93));
      canvas.drawLine(p1, p2, spokePaint);
    }

    // Center bore.
    canvas.drawCircle(
      center,
      innerR * 0.2,
      Paint()..color = isDark ? const Color(0xFF303030) : const Color(0xFFB0B0B0),
    );

    // Rotating black notch (lines up with marker at each full revolution).
    final notchAngle = wheelPhase;
    final notchCenter = Offset(
      center.dx + math.cos(notchAngle) * (outerR * 0.86),
      center.dy + math.sin(notchAngle) * (outerR * 0.86),
    );
    final tangent = notchAngle + math.pi / 2.0;
    final notchHalfLen = outerR * 0.08;
    final notchWidth = outerR * 0.04;
    final pA = Offset(
      notchCenter.dx + math.cos(tangent) * notchHalfLen,
      notchCenter.dy + math.sin(tangent) * notchHalfLen,
    );
    final pB = Offset(
      notchCenter.dx - math.cos(tangent) * notchHalfLen,
      notchCenter.dy - math.sin(tangent) * notchHalfLen,
    );
    final notchPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = notchWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(pA, pB, notchPaint);

    // Tread grooves for visual style.
    final groovePaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    for (var i = 0; i < 16; i++) {
      final a = i * (2.0 * math.pi / 16.0);
      final g1 = Offset(center.dx + math.cos(a) * (outerR * 0.92),
          center.dy + math.sin(a) * (outerR * 0.92));
      final g2 = Offset(center.dx + math.cos(a) * (outerR * 1.00),
          center.dy + math.sin(a) * (outerR * 1.00));
      canvas.drawLine(g1, g2, groovePaint);
    }

    // Label.
    final textStyle = TextStyle(
      color: dimColor,
      fontSize: 10,
      fontWeight: FontWeight.w500,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: 'Index notch aligns at 0.00 rev',
        style: textStyle,
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy + outerR + 10));
  }

  @override
  bool shouldRepaint(covariant _FlywheelPainter oldDelegate) {
    return oldDelegate.rotations != rotations ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.isDark != isDark;
  }
}
