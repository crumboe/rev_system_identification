/// Unit tests for tutorial data integrity.
///
/// Validates that all tutorials have unique IDs, non-empty steps,
/// valid categories, and consistent structure.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/ui/tutorials/tutorial_data.dart';
import 'package:rev_system_identification/ui/tutorials/tutorial_models.dart';

void main() {
  group('Tutorial data schema', () {
    test('all tutorials have unique IDs', () {
      final ids = allTutorials.map((t) => t.id).toList();
      expect(ids.toSet().length, ids.length,
          reason: 'Duplicate tutorial IDs found');
    });

    test('no tutorial has an empty ID', () {
      for (final t in allTutorials) {
        expect(t.id.isNotEmpty, isTrue,
            reason: 'Tutorial has empty ID: ${t.title}');
      }
    });

    test('all tutorials have a non-empty title', () {
      for (final t in allTutorials) {
        expect(t.title.isNotEmpty, isTrue,
            reason: 'Tutorial "${t.id}" has empty title');
      }
    });

    test('all tutorials have at least one step', () {
      for (final t in allTutorials) {
        expect(t.steps.isNotEmpty, isTrue,
            reason: 'Tutorial "${t.id}" has no steps');
      }
    });

    test('all steps have non-empty title and description', () {
      for (final t in allTutorials) {
        for (var i = 0; i < t.steps.length; i++) {
          final step = t.steps[i];
          expect(step.title.isNotEmpty, isTrue,
              reason: 'Tutorial "${t.id}" step $i has empty title');
          expect(step.description.isNotEmpty, isTrue,
              reason: 'Tutorial "${t.id}" step $i has empty description');
        }
      }
    });

    test('requiredScreenIndex is null or within valid range', () {
      for (final t in allTutorials) {
        if (t.requiredScreenIndex != null) {
          expect(t.requiredScreenIndex, greaterThanOrEqualTo(0),
              reason: 'Tutorial "${t.id}" has negative screen index');
          expect(t.requiredScreenIndex, lessThan(10),
              reason: 'Tutorial "${t.id}" screen index out of range');
        }
      }
    });

    test('every category has at least one tutorial', () {
      for (final category in TutorialCategory.values) {
        final count =
            allTutorials.where((t) => t.category == category).length;
        expect(count, greaterThan(0),
            reason: 'Category "${category.label}" has no tutorials');
      }
    });

    test('expected number of tutorials is 25', () {
      expect(allTutorials.length, 25);
    });

    test('TutorialCategory labels are non-empty', () {
      for (final c in TutorialCategory.values) {
        expect(c.label.isNotEmpty, isTrue);
      }
    });
  });
}
