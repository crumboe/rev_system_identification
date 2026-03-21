/// Data models for the in-app tutorial system.
///
/// Defines the structure for tutorial topics, steps, categories,
/// and highlight targets used throughout the tutorial overlay.
library;

import 'package:fluent_ui/fluent_ui.dart';

/// Categories for grouping tutorial topics.
enum TutorialCategory {
  hardware('Hardware'),
  software('Software'),
  electrical('Electrical'),
  testing('Testing Workflow'),
  constants('Constants Deep Dive'),
  bestPractices('Best Practices');

  final String label;
  const TutorialCategory(this.label);
}

/// A region of the UI to spotlight during a tutorial step.
class HighlightTarget {
  /// The key attached to the widget to highlight.
  final GlobalKey globalKey;

  /// Optional label to display near the highlight.
  final String? label;

  /// Optional override for the highlight border color.
  final Color? highlightColor;

  const HighlightTarget({
    required this.globalKey,
    this.label,
    this.highlightColor,
  });
}

/// A single step within a tutorial topic.
class TutorialStep {
  /// Short title shown in the step header.
  final String title;

  /// Longer explanation text (plain text, multiple sentences OK).
  final String description;

  /// Optional icon displayed alongside the title.
  final IconData? icon;

  /// Optional alignment hint for the explanation card.
  final Alignment cardAlignment;

  /// Widget keys to spotlight on the current screen during this step.
  /// If the widget is not mounted, the highlight is silently skipped.
  final List<HighlightTarget> highlights;

  /// Optional builder for custom content (diagrams, animations)
  /// displayed above the description text in the tutorial card.
  final Widget Function(BuildContext context)? customContent;

  const TutorialStep({
    required this.title,
    required this.description,
    this.icon,
    this.cardAlignment = Alignment.bottomCenter,
    this.highlights = const [],
    this.customContent,
  });
}

/// A complete tutorial topic containing one or more steps.
class TutorialTopic {
  /// Unique identifier (used for completion tracking).
  final String id;

  /// Display title shown in the tutorial browser and modal header.
  final String title;

  /// Grouping category.
  final TutorialCategory category;

  /// If set, the tutorial navigates to this screen index when started.
  final int? requiredScreenIndex;

  /// Ordered list of steps in this tutorial.
  final List<TutorialStep> steps;

  const TutorialTopic({
    required this.id,
    required this.title,
    required this.category,
    required this.steps,
    this.requiredScreenIndex,
  });
}
