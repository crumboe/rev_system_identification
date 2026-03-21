/// Non-intrusive tutorial suggestion banner for first-time screen visits.
///
/// Displays an [InfoBar] prompting the user to start a relevant tutorial
/// when they visit a screen for the first time in the session.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/app_state.dart';
import '../tutorial_data.dart';
import '../tutorial_modal.dart';
import '../tutorial_models.dart';

/// Maps screen indices to their introductory tutorial topic IDs.
const _screenTutorialMap = <int, String>{
  1: 'sw_connection_flow', // Device Setup
  3: 'sw_mechanism_type', // Configuration
  4: 'test_first_test', // Run Tests
  5: 'test_data', // Results
  6: 'bp_validation', // Validation
  7: 'bp_export', // Deploy
};

/// A banner that suggests a tutorial when visiting a screen for the first time.
///
/// Usage inside a screen:
/// ```dart
/// ScaffoldPage.scrollable(
///   children: [
///     const TutorialSuggestionBanner(screenIndex: 3),
///     // ... rest of screen content
///   ],
/// )
/// ```
class TutorialSuggestionBanner extends ConsumerWidget {
  /// The navigation index of the screen this banner belongs to.
  final int screenIndex;

  const TutorialSuggestionBanner({super.key, required this.screenIndex});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visited = ref.watch(screenVisitedProvider(screenIndex));
    if (visited) return const SizedBox.shrink();

    final topicId = _screenTutorialMap[screenIndex];
    if (topicId == null) return const SizedBox.shrink();

    final topic = allTutorials.cast<TutorialTopic?>().firstWhere(
          (t) => t!.id == topicId,
          orElse: () => null,
        );
    if (topic == null) return const SizedBox.shrink();

    // Check if already completed this topic
    final completed = ref.watch(tutorialCompletionProvider);
    if (completed.contains(topicId)) {
      // Auto-dismiss if already completed
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(screenVisitedProvider(screenIndex).notifier).state = true;
      });
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InfoBar(
        title: Text('New here? Learn about ${topic.title}'),
        content: Text(
          '${topic.steps.length}-step tutorial for getting started.',
        ),
        severity: InfoBarSeverity.info,
        isLong: true,
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton(
              onPressed: () {
                ref.read(screenVisitedProvider(screenIndex).notifier).state =
                    true;
                startTutorial(ref, topic);
              },
              child: const Text('Start Tutorial'),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(FluentIcons.clear, size: 12),
              onPressed: () {
                ref.read(screenVisitedProvider(screenIndex).notifier).state =
                    true;
              },
            ),
          ],
        ),
      ),
    );
  }
}
