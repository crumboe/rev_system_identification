/// Interactive chart walkthrough overlay for educational graph annotations.
///
/// Provides step-by-step guided explanations of chart features, intended
/// for high-school students learning about system identification.
library;

import 'package:fluent_ui/fluent_ui.dart';

/// A single step in a chart walkthrough.
class WalkthroughStep {
  /// Short title shown in the step header.
  final String title;

  /// Longer explanation (supports multiple sentences).
  final String description;

  /// Optional alignment hint for the explanation card relative to the chart.
  /// Defaults to bottom-center.
  final Alignment cardAlignment;

  /// Optional icon to display alongside the title.
  final IconData? icon;

  const WalkthroughStep({
    required this.title,
    required this.description,
    this.cardAlignment = Alignment.bottomCenter,
    this.icon,
  });
}

/// An overlay widget that displays a series of [WalkthroughStep]s
/// on top of a chart widget.
///
/// Usage:
/// ```dart
/// ChartWalkthrough(
///   steps: [...],
///   onDismiss: () => markAsSeen(),
///   child: MyChart(),
/// )
/// ```
class ChartWalkthrough extends StatefulWidget {
  /// The walkthrough steps to present.
  final List<WalkthroughStep> steps;

  /// Called when the user finishes or dismisses the walkthrough.
  final VoidCallback? onDismiss;

  /// The chart widget to overlay.
  final Widget child;

  /// Whether the walkthrough is currently active.
  final bool isActive;

  const ChartWalkthrough({
    super.key,
    required this.steps,
    required this.child,
    this.onDismiss,
    this.isActive = true,
  });

  @override
  State<ChartWalkthrough> createState() => _ChartWalkthroughState();
}

class _ChartWalkthroughState extends State<ChartWalkthrough> {
  int _currentStep = 0;

  @override
  Widget build(BuildContext context) {
    if (!widget.isActive || widget.steps.isEmpty) {
      return widget.child;
    }

    final step = widget.steps[_currentStep];
    final theme = FluentTheme.of(context);
    final totalSteps = widget.steps.length;

    return Stack(
      children: [
        // The chart itself
        widget.child,

        // Semi-transparent overlay
        Positioned.fill(
          child: Container(
            color: const Color(0x40000000),
          ),
        ),

        // Explanation card — sized to fill most of the chart area
        Positioned(
          left: 12,
          right: 12,
          top: 24,
          bottom: 12,
          child: Container(
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
                // Step counter and title
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
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
                    // Dismiss button
                    IconButton(
                      icon: const Icon(FluentIcons.chrome_close, size: 12),
                      onPressed: _dismiss,
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // Description — scrollable for longer educational content
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(
                      step.description,
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.typography.body?.color
                            ?.withValues(alpha: 0.85),
                        height: 1.5,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Navigation buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Previous
                    Button(
                      onPressed:
                          _currentStep > 0 ? _previousStep : null,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(FluentIcons.chevron_left, size: 12),
                          SizedBox(width: 4),
                          Text('Previous'),
                        ],
                      ),
                    ),

                    // Progress dots
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
                                : theme.accentColor
                                    .withValues(alpha: 0.25),
                          ),
                        );
                      }),
                    ),

                    // Next / Finish
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
                        onPressed: _dismiss,
                        child: const Text('Got it!'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _nextStep() {
    if (_currentStep < widget.steps.length - 1) {
      setState(() => _currentStep++);
    }
  }

  void _previousStep() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
    }
  }

  void _dismiss() {
    widget.onDismiss?.call();
  }
}

/// A small button that toggles a chart walkthrough on/off.
class WalkthroughToggle extends StatelessWidget {
  final bool isActive;
  final VoidCallback onToggle;

  const WalkthroughToggle({
    super.key,
    required this.isActive,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: isActive ? 'Hide walkthrough' : 'Show chart guide',
      child: IconButton(
        icon: Icon(
          FluentIcons.lightbulb,
          size: 14,
          color: isActive
              ? FluentTheme.of(context).accentColor
              : null,
        ),
        onPressed: onToggle,
      ),
    );
  }
}
