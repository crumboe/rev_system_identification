/// Interactive chart walkthrough overlay for educational graph annotations.
///
/// Provides step-by-step guided explanations of chart features, intended
/// for high-school students learning about system identification.
///
/// This is a thin wrapper around [TutorialOverlay] that preserves the
/// original ChartWalkthrough API for backward compatibility.
library;

import 'package:fluent_ui/fluent_ui.dart';

import '../tutorials/tutorial_models.dart';
import '../tutorials/tutorial_overlay.dart';

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

  /// Convert to the general-purpose [TutorialStep] model.
  TutorialStep toTutorialStep() => TutorialStep(
        title: title,
        description: description,
        cardAlignment: cardAlignment,
        icon: icon,
      );
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
class ChartWalkthrough extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return TutorialOverlay(
      steps: steps.map((s) => s.toTutorialStep()).toList(),
      isActive: isActive,
      onFinish: onDismiss,
      onDismiss: onDismiss,
      child: child,
    );
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
