/// Tutorial browser dialog for browsing and launching tutorials.
///
/// Displays all tutorial topics grouped by category inside a
/// [ContentDialog]. Users can search, see completion status, and
/// launch tutorials directly.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_state.dart';
import 'tutorial_data.dart';
import 'tutorial_models.dart';
import 'tutorial_modal.dart' show startTutorial;

/// A dialog that lists all tutorials grouped by category.
///
/// Shows completion badges, supports text search filtering,
/// and lets users reset progress or launch any tutorial.
class TutorialBrowser extends ConsumerStatefulWidget {
  const TutorialBrowser({super.key});

  @override
  ConsumerState<TutorialBrowser> createState() => _TutorialBrowserState();
}

class _TutorialBrowserState extends ConsumerState<TutorialBrowser> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<TutorialTopic> get _filteredTopics {
    if (_query.isEmpty) return allTutorials;
    final q = _query.toLowerCase();
    return allTutorials.where((t) {
      return t.title.toLowerCase().contains(q) ||
          t.category.label.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final completedIds = ref.watch(tutorialCompletionProvider);
    final theme = FluentTheme.of(context);
    final filtered = _filteredTopics;

    // Group by category, preserving enum order.
    final grouped = <TutorialCategory, List<TutorialTopic>>{};
    for (final topic in filtered) {
      grouped.putIfAbsent(topic.category, () => []).add(topic);
    }

    return ContentDialog(
      title: Row(
        children: [
          const Icon(FluentIcons.education, size: 20),
          const SizedBox(width: 8),
          const Text('Tutorials'),
          const Spacer(),
          SizedBox(
            width: 200,
            child: TextBox(
              controller: _searchController,
              placeholder: 'Search tutorials…',
              prefix: const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(FluentIcons.search, size: 14),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
        ],
      ),
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
      content: filtered.isEmpty
          ? Center(
              child: Text(
                'No tutorials match "$_query".',
                style: theme.typography.body,
              ),
            )
          : ListView(
              children: [
                for (final category in TutorialCategory.values)
                  if (grouped.containsKey(category)) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 4),
                      child: Text(
                        category.label,
                        style: theme.typography.subtitle,
                      ),
                    ),
                    ...grouped[category]!.map((topic) {
                      final done = completedIds.contains(topic.id);
                      return ListTile.selectable(
                        leading: Icon(
                          done
                              ? FluentIcons.completed_solid
                              : FluentIcons.circle_ring,
                          color: done ? Colors.green : null,
                          size: 16,
                        ),
                        title: Text(topic.title),
                        trailing: Text(
                          '${topic.steps.length} steps',
                          style: theme.typography.caption,
                        ),
                        onPressed: () {
                          Navigator.of(context).pop();
                          startTutorial(ref, topic);
                        },
                      );
                    }),
                  ],
              ],
            ),
      actions: [
        Button(
          child: const Text('Reset Progress'),
          onPressed: () {
            ref.read(tutorialCompletionProvider.notifier).reset();
          },
        ),
        FilledButton(
          child: const Text('Close'),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
