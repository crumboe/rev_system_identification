/// Reusable step-by-step tutorial overlay with spotlight highlights.
///
/// Extracted from [ChartWalkthrough] and extended with:
/// - Widget spotlight cutouts via [HighlightTarget]
/// - Custom content area (diagrams, animations) per step
/// - Keyboard navigation (Left/Right arrows, Escape to dismiss)
///
/// Used as the rendering engine for both chart walkthroughs and
/// the full-screen tutorial modal.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart' show KeyDownEvent, LogicalKeyboardKey;

import 'tutorial_models.dart';

/// An overlay widget that displays a series of [TutorialStep]s
/// on top of a child widget, with optional spotlight highlights.
class TutorialOverlay extends StatefulWidget {
  /// The tutorial steps to present.
  final List<TutorialStep> steps;

  /// Called when the user finishes (last step "Got it!") the tutorial.
  final VoidCallback? onFinish;

  /// Called when the user dismisses mid-tutorial (X button or Escape).
  final VoidCallback? onDismiss;

  /// The content widget beneath the overlay. If null, the overlay
  /// is rendered as a standalone full-screen layer (for modal use).
  final Widget? child;

  /// Whether the overlay is currently active.
  final bool isActive;

  /// External step index override. When non-null, the overlay
  /// tracks this value instead of internal state.
  final int? currentStep;

  /// Callback when step changes (for external state management).
  final ValueChanged<int>? onStepChanged;

  const TutorialOverlay({
    super.key,
    required this.steps,
    this.child,
    this.onFinish,
    this.onDismiss,
    this.isActive = true,
    this.currentStep,
    this.onStepChanged,
  });

  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay> {
  int _internalStep = 0;
  final FocusNode _focusNode = FocusNode();

  int get _currentStep => widget.currentStep ?? _internalStep;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive || widget.steps.isEmpty) {
      return widget.child ?? const SizedBox.shrink();
    }

    // Request focus for keyboard navigation
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_focusNode.canRequestFocus && !_focusNode.hasFocus) {
        _focusNode.requestFocus();
      }
    });

    final step = widget.steps[_currentStep];
    final theme = FluentTheme.of(context);
    final totalSteps = widget.steps.length;

    return KeyboardListener(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: Stack(
        children: [
          // The content beneath the overlay
          if (widget.child != null) widget.child!,

          // Semi-transparent backdrop with spotlight cutouts
          Positioned.fill(
            child: _buildBackdrop(context, step),
          ),

          // Explanation card
          Positioned(
            left: 12,
            right: 12,
            top: 24,
            bottom: 12,
            child: _buildCard(context, step, theme, totalSteps),
          ),
        ],
      ),
    );
  }

  Widget _buildBackdrop(BuildContext context, TutorialStep step) {
    if (step.highlights.isEmpty) {
      return Container(color: const Color(0x40000000));
    }

    // Collect highlight rects for cutout rendering
    final rects = <_HighlightRect>[];
    for (final target in step.highlights) {
      final renderObj =
          target.globalKey.currentContext?.findRenderObject() as RenderBox?;
      if (renderObj == null || !renderObj.attached) continue;
      final offset = renderObj.localToGlobal(Offset.zero);
      final size = renderObj.size;
      rects.add(_HighlightRect(
        rect: Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
        color: target.highlightColor,
        label: target.label,
      ));
    }

    if (rects.isEmpty) {
      return Container(color: const Color(0x40000000));
    }

    return CustomPaint(
      size: Size.infinite,
      painter: _SpotlightPainter(
        rects: rects,
        accentColor: FluentTheme.of(context).accentColor,
      ),
    );
  }

  Widget _buildCard(
    BuildContext context,
    TutorialStep step,
    FluentThemeData theme,
    int totalSteps,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.micaBackgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.accentColor.withValues(alpha: 0.4),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: step counter + icon + title + dismiss
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.accentColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${_currentStep + 1}/$totalSteps',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (step.icon != null) ...[
                Icon(step.icon, size: 16, color: theme.accentColor),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  step.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Semantics(
                label: 'Close tutorial',
                child: IconButton(
                  icon: const Icon(FluentIcons.chrome_close, size: 12),
                  onPressed: _handleDismiss,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Custom content area (diagrams, animations)
          if (step.customContent != null) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: step.customContent!(context),
            ),
            const SizedBox(height: 8),
          ],

          // Description — scrollable
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                step.description,
                style: TextStyle(
                  fontSize: 13,
                  color:
                      theme.typography.body?.color?.withValues(alpha: 0.85),
                  height: 1.5,
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Navigation: Previous | dots | Next/Finish
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Button(
                onPressed: _currentStep > 0 ? _previousStep : null,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.chevron_left, size: 12),
                    SizedBox(width: 4),
                    Text('Previous'),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(totalSteps, (i) {
                  return Container(
                    width: 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _currentStep
                          ? theme.accentColor
                          : theme.accentColor.withValues(alpha: 0.25),
                    ),
                  );
                }),
              ),
              if (_currentStep < totalSteps - 1)
                FilledButton(
                  onPressed: _nextStep,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Next'),
                      SizedBox(width: 4),
                      Icon(FluentIcons.chevron_right, size: 12),
                    ],
                  ),
                )
              else
                FilledButton(
                  onPressed: _handleFinish,
                  child: const Text('Got it!'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Navigation
  // ---------------------------------------------------------------------------

  void _nextStep() {
    if (_currentStep < widget.steps.length - 1) {
      final next = _currentStep + 1;
      if (widget.onStepChanged != null) {
        widget.onStepChanged!(next);
      } else {
        setState(() => _internalStep = next);
      }
    }
  }

  void _previousStep() {
    if (_currentStep > 0) {
      final prev = _currentStep - 1;
      if (widget.onStepChanged != null) {
        widget.onStepChanged!(prev);
      } else {
        setState(() => _internalStep = prev);
      }
    }
  }

  void _handleFinish() {
    widget.onFinish?.call();
  }

  void _handleDismiss() {
    widget.onDismiss?.call();
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _nextStep();
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _previousStep();
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      _handleDismiss();
    }
  }
}

// ---------------------------------------------------------------------------
// Spotlight painting
// ---------------------------------------------------------------------------

class _HighlightRect {
  final Rect rect;
  final Color? color;
  final String? label;
  const _HighlightRect({required this.rect, this.color, this.label});
}

class _SpotlightPainter extends CustomPainter {
  final List<_HighlightRect> rects;
  final Color accentColor;

  _SpotlightPainter({required this.rects, required this.accentColor});

  @override
  void paint(Canvas canvas, Size size) {
    // Draw semi-transparent backdrop
    final bgPaint = Paint()..color = const Color(0x40000000);
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRect(Offset.zero & size, bgPaint);

    // Cut out highlight regions
    final clearPaint = Paint()..blendMode = BlendMode.clear;
    for (final hr in rects) {
      final inflated = hr.rect.inflate(4); // small padding
      canvas.drawRRect(
        RRect.fromRectAndRadius(inflated, const Radius.circular(4)),
        clearPaint,
      );
    }
    canvas.restore();

    // Draw glow border around cutouts
    for (final hr in rects) {
      final inflated = hr.rect.inflate(4);
      final borderPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = (hr.color ?? accentColor).withValues(alpha: 0.7);
      canvas.drawRRect(
        RRect.fromRectAndRadius(inflated, const Radius.circular(4)),
        borderPaint,
      );
    }

    // Draw labels
    for (final hr in rects) {
      if (hr.label == null) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: hr.label,
          style: TextStyle(
            color: hr.color ?? accentColor,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          hr.rect.left,
          hr.rect.top - tp.height - 4,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter oldDelegate) =>
      rects != oldDelegate.rects;
}
