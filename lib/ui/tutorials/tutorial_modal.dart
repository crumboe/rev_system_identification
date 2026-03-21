/// Full-screen tutorial modal that renders on top of the app.
///
/// Reads [activeTutorialProvider] and [activeTutorialStepProvider]
/// to display the current tutorial. Invisible when no tutorial is active.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import 'tutorial_models.dart';
import 'tutorial_overlay.dart';

/// Starts a tutorial, setting the active topic and navigating to the
/// required screen if specified.
void startTutorial(WidgetRef ref, TutorialTopic topic) {
  ref.read(activeTutorialProvider.notifier).state = topic;
  ref.read(activeTutorialStepProvider.notifier).state = 0;
  if (topic.requiredScreenIndex != null) {
    ref.read(selectedPageProvider.notifier).state =
        topic.requiredScreenIndex!;
  }
}

/// Full-screen overlay that displays the active tutorial.
///
/// Place this in a [Stack] on top of the main app content.
/// When [activeTutorialProvider] is null, this renders nothing.
class TutorialModal extends ConsumerWidget {
  const TutorialModal({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final topic = ref.watch(activeTutorialProvider);
    if (topic == null) return const SizedBox.shrink();

    final stepIndex = ref.watch(activeTutorialStepProvider);

    return TutorialOverlay(
      steps: topic.steps,
      isActive: true,
      currentStep: stepIndex.clamp(0, topic.steps.length - 1),
      onStepChanged: (newStep) {
        ref.read(activeTutorialStepProvider.notifier).state = newStep;
      },
      onFinish: () {
        // Mark complete and close
        ref
            .read(tutorialCompletionProvider.notifier)
            .markComplete(topic.id);
        ref.read(activeTutorialProvider.notifier).state = null;
        ref.read(activeTutorialStepProvider.notifier).state = 0;
      },
      onDismiss: () {
        // Close without marking complete
        ref.read(activeTutorialProvider.notifier).state = null;
        ref.read(activeTutorialStepProvider.notifier).state = 0;
      },
    );
  }
}
