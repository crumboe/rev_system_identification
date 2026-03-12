/// A text field that accepts simple math expressions and evaluates them.
///
/// Supports: `+`, `-`, `*`, `/`, parentheses, and decimal numbers.
/// Shows a live-evaluated result below the input field.
library;

import 'package:fluent_ui/fluent_ui.dart';

// ---------------------------------------------------------------------------
// Expression evaluator (recursive descent)
// ---------------------------------------------------------------------------

/// Tokenize and evaluate a simple arithmetic expression.
///
/// Grammar:
///   expr   → term (('+' | '-') term)*
///   term   → unary (('*' | '/') unary)*
///   unary  → '-' unary | primary
///   primary → NUMBER | '(' expr ')'
double? evaluateExpression(String input) {
  final tokens = _tokenize(input);
  if (tokens == null) return null;
  final parser = _Parser(tokens);
  final result = parser.parseExpression();
  if (result == null || !parser.isAtEnd) return null;
  if (result.isNaN || result.isInfinite) return null;
  return result;
}

// -- Tokenizer --------------------------------------------------------------

enum _TokenType { number, plus, minus, star, slash, lParen, rParen }

class _Token {
  final _TokenType type;
  final double value; // only meaningful for number tokens
  const _Token(this.type, [this.value = 0]);
}

List<_Token>? _tokenize(String input) {
  final tokens = <_Token>[];
  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (ch == ' ' || ch == '\t') {
      i++;
      continue;
    }
    if (ch == '+') {
      tokens.add(const _Token(_TokenType.plus));
      i++;
    } else if (ch == '-') {
      tokens.add(const _Token(_TokenType.minus));
      i++;
    } else if (ch == '*') {
      tokens.add(const _Token(_TokenType.star));
      i++;
    } else if (ch == '/') {
      tokens.add(const _Token(_TokenType.slash));
      i++;
    } else if (ch == '(') {
      tokens.add(const _Token(_TokenType.lParen));
      i++;
    } else if (ch == ')') {
      tokens.add(const _Token(_TokenType.rParen));
      i++;
    } else if (_isDigitOrDot(ch)) {
      final start = i;
      bool hasDot = ch == '.';
      i++;
      while (i < input.length && _isDigitOrDot(input[i])) {
        if (input[i] == '.') {
          if (hasDot) return null; // two dots
          hasDot = true;
        }
        i++;
      }
      final numStr = input.substring(start, i);
      final value = double.tryParse(numStr);
      if (value == null) return null;
      tokens.add(_Token(_TokenType.number, value));
    } else {
      return null; // unexpected character
    }
  }
  return tokens;
}

bool _isDigitOrDot(String ch) =>
    (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) || ch == '.';

// -- Parser -----------------------------------------------------------------

class _Parser {
  final List<_Token> _tokens;
  int _pos = 0;

  _Parser(this._tokens);

  bool get isAtEnd => _pos >= _tokens.length;

  _Token? _peek() => _pos < _tokens.length ? _tokens[_pos] : null;

  _Token? _advance() {
    if (_pos < _tokens.length) return _tokens[_pos++];
    return null;
  }

  /// expr → term (('+' | '-') term)*
  double? parseExpression() {
    var left = _parseTerm();
    if (left == null) return null;
    while (_peek()?.type == _TokenType.plus ||
        _peek()?.type == _TokenType.minus) {
      final op = _advance()!;
      final right = _parseTerm();
      if (right == null) return null;
      if (op.type == _TokenType.plus) {
        left = left! + right;
      } else {
        left = left! - right;
      }
    }
    return left;
  }

  /// term → unary (('*' | '/') unary)*
  double? _parseTerm() {
    var left = _parseUnary();
    if (left == null) return null;
    while (_peek()?.type == _TokenType.star ||
        _peek()?.type == _TokenType.slash) {
      final op = _advance()!;
      final right = _parseUnary();
      if (right == null) return null;
      if (op.type == _TokenType.star) {
        left = left! * right;
      } else {
        if (right == 0) return null; // division by zero
        left = left! / right;
      }
    }
    return left;
  }

  /// unary → '-' unary | primary
  double? _parseUnary() {
    if (_peek()?.type == _TokenType.minus) {
      _advance();
      final val = _parseUnary();
      return val != null ? -val : null;
    }
    return _parsePrimary();
  }

  /// primary → NUMBER | '(' expr ')'
  double? _parsePrimary() {
    final token = _peek();
    if (token == null) return null;

    if (token.type == _TokenType.number) {
      _advance();
      return token.value;
    }

    if (token.type == _TokenType.lParen) {
      _advance(); // consume '('
      final val = parseExpression();
      if (val == null) return null;
      if (_peek()?.type != _TokenType.rParen) return null;
      _advance(); // consume ')'
      return val;
    }

    return null;
  }
}

// ---------------------------------------------------------------------------
// ExpressionField widget
// ---------------------------------------------------------------------------

/// A text field that accepts simple math expressions (e.g. `360/50`) and
/// evaluates them live, showing the result below the input.
///
/// When the expression evaluates to a valid number, [onChanged] is called
/// with the result.  The parent stores the evaluated double, not the
/// expression string.
class ExpressionField extends StatefulWidget {
  /// The current numeric value (used to initialise the field if no expression
  /// has been typed yet).
  final double value;

  /// Called with the evaluated result whenever the expression is valid.
  final ValueChanged<double>? onChanged;

  /// Optional minimum allowed evaluated value.
  final double? min;

  /// Optional maximum allowed evaluated value.
  final double? max;

  /// Placeholder text shown when the field is empty.
  final String? placeholder;

  const ExpressionField({
    super.key,
    required this.value,
    this.onChanged,
    this.min,
    this.max,
    this.placeholder,
  });

  @override
  State<ExpressionField> createState() => _ExpressionFieldState();
}

class _ExpressionFieldState extends State<ExpressionField> {
  late final TextEditingController _controller;
  double? _evaluatedValue;
  bool _isValid = true;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _formatValue(widget.value));
    _evaluatedValue = widget.value;
    _initialized = true;
  }

  @override
  void didUpdateWidget(ExpressionField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only update the text if the value changed externally and the field
    // currently shows a plain number (not an expression).
    if (oldWidget.value != widget.value && _initialized) {
      final currentEval = evaluateExpression(_controller.text);
      if (currentEval == null || (currentEval - widget.value).abs() > 1e-9) {
        _controller.text = _formatValue(widget.value);
        _evaluatedValue = widget.value;
        _isValid = true;
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    final result = evaluateExpression(text);
    setState(() {
      if (result != null) {
        var clamped = result;
        if (widget.min != null && clamped < widget.min!) clamped = widget.min!;
        if (widget.max != null && clamped > widget.max!) clamped = widget.max!;
        _evaluatedValue = clamped;
        _isValid = true;
        widget.onChanged?.call(clamped);
      } else {
        _isValid = text.isEmpty;
        _evaluatedValue = null;
      }
    });
  }

  static String _formatValue(double v) {
    // Show as integer if it's a whole number.
    if (v == v.roundToDouble() && v.abs() < 1e12) {
      return v.toInt().toString();
    }
    return v.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextBox(
          controller: _controller,
          onChanged: _onChanged,
          placeholder: widget.placeholder ?? 'e.g. 360/50',
          style: TextStyle(
            color: _isValid ? null : Colors.red,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          _evaluatedValue != null
              ? '= ${_evaluatedValue!.toStringAsFixed(10).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '')}'
              : _controller.text.isEmpty
                  ? ''
                  : 'Invalid expression',
          style: TextStyle(
            fontSize: 11,
            color: _isValid
                ? theme.typography.caption?.color?.withAlpha(153)
                : Colors.red,
          ),
        ),
      ],
    );
  }
}
