/// Unit tests for tutorial completion state management.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/state/app_state.dart';

void main() {
  group('TutorialCompletionNotifier', () {
    late TutorialCompletionNotifier notifier;

    setUp(() {
      notifier = TutorialCompletionNotifier();
    });

    test('starts empty', () {
      expect(notifier.state, isEmpty);
    });

    test('markComplete adds topic ID', () {
      notifier.markComplete('test_topic_1');
      expect(notifier.isComplete('test_topic_1'), isTrue);
      expect(notifier.isComplete('test_topic_2'), isFalse);
    });

    test('markComplete is idempotent', () {
      notifier.markComplete('t1');
      notifier.markComplete('t1');
      expect(notifier.state.length, 1);
    });

    test('multiple completions tracked', () {
      notifier.markComplete('a');
      notifier.markComplete('b');
      notifier.markComplete('c');
      expect(notifier.isComplete('a'), isTrue);
      expect(notifier.isComplete('b'), isTrue);
      expect(notifier.isComplete('c'), isTrue);
      expect(notifier.state.length, 3);
    });

    test('reset clears all completions', () {
      notifier.markComplete('a');
      notifier.markComplete('b');
      notifier.reset();
      expect(notifier.state, isEmpty);
      expect(notifier.isComplete('a'), isFalse);
    });
  });
}
