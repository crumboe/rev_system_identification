/// Unit tests for the expression evaluator in expression_field.dart.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/ui/widgets/expression_field.dart';

void main() {
  group('Basic arithmetic', () {
    test('simple number', () {
      expect(evaluateExpression('42'), closeTo(42.0, 1e-9));
    });

    test('decimal number', () {
      expect(evaluateExpression('3.14'), closeTo(3.14, 1e-9));
    });

    test('addition', () {
      expect(evaluateExpression('1 + 2'), closeTo(3.0, 1e-9));
    });

    test('subtraction', () {
      expect(evaluateExpression('10 - 4'), closeTo(6.0, 1e-9));
    });

    test('multiplication', () {
      expect(evaluateExpression('3 * 5'), closeTo(15.0, 1e-9));
    });

    test('division', () {
      expect(evaluateExpression('10 / 4'), closeTo(2.5, 1e-9));
    });
  });

  group('Operator precedence', () {
    test('multiplication before addition', () {
      expect(evaluateExpression('2 + 3 * 4'), closeTo(14.0, 1e-9));
    });

    test('division before subtraction', () {
      expect(evaluateExpression('10 - 6 / 3'), closeTo(8.0, 1e-9));
    });

    test('parentheses override precedence', () {
      expect(evaluateExpression('(2 + 3) * 4'), closeTo(20.0, 1e-9));
    });

    test('nested parentheses', () {
      expect(evaluateExpression('((1 + 2) * (3 + 4))'), closeTo(21.0, 1e-9));
    });
  });

  group('Unary minus', () {
    test('negative number', () {
      expect(evaluateExpression('-5'), closeTo(-5.0, 1e-9));
    });

    test('double negation', () {
      expect(evaluateExpression('--5'), closeTo(5.0, 1e-9));
    });

    test('negative in expression', () {
      expect(evaluateExpression('3 + -2'), closeTo(1.0, 1e-9));
    });

    test('negative in parentheses', () {
      expect(evaluateExpression('(-3) * 2'), closeTo(-6.0, 1e-9));
    });
  });

  group('Gear ratio expressions', () {
    test('1/50 gear ratio', () {
      expect(evaluateExpression('1/50'), closeTo(0.02, 1e-9));
    });

    test('360/20 for arm with gear reduction', () {
      expect(evaluateExpression('360/20'), closeTo(18.0, 1e-9));
    });

    test('1/(4*3.14159)', () {
      final result = evaluateExpression('1/(4*3.14159)');
      expect(result, isNotNull);
      expect(result!, closeTo(1.0 / (4.0 * 3.14159), 1e-6));
    });

    test('(16/48) * (18/72)', () {
      final result = evaluateExpression('(16/48) * (18/72)');
      expect(result, isNotNull);
      expect(result!, closeTo((16.0 / 48.0) * (18.0 / 72.0), 1e-9));
    });
  });

  group('Edge cases and errors', () {
    test('empty string returns null', () {
      expect(evaluateExpression(''), isNull);
    });

    test('whitespace only returns null', () {
      expect(evaluateExpression('   '), isNull);
    });

    test('division by zero returns null', () {
      expect(evaluateExpression('1/0'), isNull);
    });

    test('invalid characters return null', () {
      expect(evaluateExpression('2 ^ 3'), isNull);
    });

    test('unmatched parenthesis returns null', () {
      expect(evaluateExpression('(2 + 3'), isNull);
    });

    test('trailing operator returns null', () {
      expect(evaluateExpression('2 +'), isNull);
    });

    test('leading operator (non-unary) returns null', () {
      expect(evaluateExpression('* 3'), isNull);
    });

    test('double dot returns null', () {
      expect(evaluateExpression('3..14'), isNull);
    });
  });
}
