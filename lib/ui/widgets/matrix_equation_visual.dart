/// Interactive visual explanation of the OLS matrix equation for students
/// who have not studied linear algebra.
///
/// Shows the matrix equation V = X·β using color-coded columns, an
/// interactive row selector, and step-by-step "plug and chug" expansion
/// so the audience sees it is just the physics equation repeated for every
/// data point.
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';

import '../../mechanisms/mechanism.dart';
import '../../data/test_data.dart';
import '../../sysid/feedforward_analyzer.dart';

/// Column colors — each column of the design matrix gets a unique hue so
/// students can visually track "this column multiplies this gain".
const _colColors = [
  Color(0xFFE06C75), // sign(ω) → kS — red
  Color(0xFF61AFEF), // ω       → kV — blue
  Color(0xFF98C379), // α       → kA — green
  Color(0xFFD19A66), // g(θ)    → kG — orange
];

const _gainLabels = ['kS', 'kV', 'kA', 'kG'];
const _colLabels = ['sign(ω)', 'ω', 'α', 'g(θ)'];

/// A visual, interactive explanation of the matrix equation.
///
/// If [sampleRows] is provided the widget shows real data from the current
/// test; otherwise it uses small illustrative numbers.
class MatrixEquationVisualizer extends StatefulWidget {
  final MechanismType mechanismType;
  final FeedforwardGains? gains;

  /// A handful of representative data rows (5-6 is ideal).
  final List<DataPoint>? sampleRows;
  final int totalSamples;

  const MatrixEquationVisualizer({
    super.key,
    required this.mechanismType,
    this.gains,
    this.sampleRows,
    this.totalSamples = 0,
  });

  @override
  State<MatrixEquationVisualizer> createState() =>
      _MatrixEquationVisualizerState();
}

class _MatrixEquationVisualizerState extends State<MatrixEquationVisualizer> {
  /// Which row (0-based) the user is hovering / has selected.
  int? _activeRow;

  /// Step-through mode: which multiplication step is highlighted (0..numCols-1)
  int _mulStep = -1; // -1 = show all at once

  bool get _hasGravity => widget.mechanismType.hasGravity;
  int get _numCols => _hasGravity ? 4 : 3;

  // Example data when no real samples available.
  static const _fallbackData = [
    [1.0, 12.3, 0.5, 1.0],
    [1.0, 45.7, 2.1, 0.87],
    [-1.0, -30.0, -1.8, 0.5],
    [1.0, 78.2, 0.1, 0.34],
    [-1.0, -55.1, -3.0, 0.0],
  ];

  List<List<double>> get _rows {
    if (widget.sampleRows != null && widget.sampleRows!.length >= 3) {
      return widget.sampleRows!.take(5).map((p) {
        final vel = p.velocity;
        final acc = (p.velocity) * 0.1; // simplified for display
        final gravTerm = widget.mechanismType == MechanismType.arm
            ? math.cos(p.position * math.pi / 180.0)
            : widget.mechanismType == MechanismType.elevator
                ? 1.0
                : 0.0;
        return [
          vel > 0 ? 1.0 : -1.0,
          vel,
          acc,
          if (_hasGravity) gravTerm,
        ];
      }).toList();
    }
    return _fallbackData
        .map((r) => _hasGravity ? r : r.sublist(0, 3))
        .toList();
  }

  List<double> get _voltages {
    if (widget.sampleRows != null && widget.sampleRows!.length >= 3) {
      return widget.sampleRows!.take(5).map((p) => p.voltage).toList();
    }
    return [2.1, 4.8, -3.5, 7.2, -5.9];
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final captionStyle = TextStyle(
      fontSize: 12,
      color: theme.typography.body?.color?.withValues(alpha: 0.75),
      height: 1.5,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Intro text ────────────────────────────────────────────
        Text(
          'The matrix equation is just a shorthand for writing the same '
          'physics formula for every single data point at once. '
          'Think of it like a big spreadsheet — each row is one measurement, '
          'and each column holds one of the values we measured.',
          style: captionStyle,
        ),
        const SizedBox(height: 16),

        // ── Color legend ──────────────────────────────────────────
        _buildLegend(theme),
        const SizedBox(height: 16),

        // ── Visual matrix equation ────────────────────────────────
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: _buildMatrixEquation(theme),
        ),
        const SizedBox(height: 12),

        // ── Row drill-down ────────────────────────────────────────
        if (_activeRow != null) _buildRowExpansion(theme),
        if (_activeRow == null)
          Text(
            '👆 Hover or click a row in the matrix to see how that '
            'one data point turns into an equation.',
            style: TextStyle(
              fontSize: 12,
              fontStyle: FontStyle.italic,
              color: theme.accentColor,
            ),
          ),

        const SizedBox(height: 16),

        // ── "Step through the multiply" mini-animation ────────────
        _buildStepThrough(theme),

        const SizedBox(height: 16),

        // ── Plain-English summary ─────────────────────────────────
        _buildSummary(theme, captionStyle),
      ],
    );
  }

  // ───────────────────────────────────────────────────────────────────
  // Legend
  // ───────────────────────────────────────────────────────────────────
  Widget _buildLegend(FluentThemeData theme) {
    final items = <Widget>[];
    for (var c = 0; c < _numCols; c++) {
      items.add(
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: _colColors[c].withValues(alpha: 0.25),
                  border: Border.all(color: _colColors[c], width: 1.5),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '${_colLabels[c]}  →  ${_gainLabels[c]}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _colColors[c],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Wrap(spacing: 4, runSpacing: 6, children: items);
  }

  // ───────────────────────────────────────────────────────────────────
  // Matrix equation  V = X ∙ β
  // ───────────────────────────────────────────────────────────────────
  Widget _buildMatrixEquation(FluentThemeData theme) {
    final rows = _rows;
    final voltages = _voltages;
    final gains = widget.gains;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // V column vector
        _matrixLabel('V', theme),
        const SizedBox(width: 4),
        _bracketedColumn(
          voltages.asMap().entries.map((e) {
            final i = e.key;
            return _cell(
              e.value.toStringAsFixed(1),
              isActive: _activeRow == i,
              color: theme.typography.body?.color,
              onHover: (h) => setState(() => _activeRow = h ? i : null),
              onTap: () => setState(() =>
                  _activeRow = _activeRow == i ? null : i),
            );
          }).toList(),
          theme,
          label: 'voltages',
        ),

        // =
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text('=', style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: theme.typography.body?.color,
          )),
        ),

        // X matrix
        _matrixLabel('X', theme),
        const SizedBox(width: 4),
        _bracketedMatrix(rows, theme),

        // ×
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text('×', style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: theme.typography.body?.color,
          )),
        ),

        // β column vector
        _matrixLabel('β', theme),
        const SizedBox(width: 4),
        _bracketedColumn(
          List.generate(_numCols, (c) {
            final label = gains != null
                ? [gains.kS, gains.kV, gains.kA, gains.kG][c]
                    .toStringAsFixed(3)
                : _gainLabels[c];
            return _cell(
              label,
              color: _colColors[c],
              bold: true,
            );
          }),
          theme,
          label: 'gains',
        ),
      ],
    );
  }

  Widget _matrixLabel(String label, FluentThemeData theme) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        fontStyle: FontStyle.italic,
        color: theme.accentColor,
      ),
    );
  }

  /// A column vector with bracket decoration.
  Widget _bracketedColumn(
    List<Widget> cells,
    FluentThemeData theme, {
    String? label,
  }) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: theme.typography.body?.color?.withValues(alpha: 0.5) ??
                const Color(0xFF888888),
            width: 2,
          ),
          right: BorderSide(
            color: theme.typography.body?.color?.withValues(alpha: 0.5) ??
                const Color(0xFF888888),
            width: 2,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: cells,
      ),
    );
  }

  /// The design matrix with colored columns and interactive rows.
  Widget _bracketedMatrix(
    List<List<double>> rows,
    FluentThemeData theme,
  ) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: theme.typography.body?.color?.withValues(alpha: 0.5) ??
                const Color(0xFF888888),
            width: 2,
          ),
          right: BorderSide(
            color: theme.typography.body?.color?.withValues(alpha: 0.5) ??
                const Color(0xFF888888),
            width: 2,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Column headers
          Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(_numCols, (c) {
              return _headerCell(_colLabels[c], _colColors[c]);
            }),
          ),
          const SizedBox(height: 2),
          // Data rows
          ...rows.asMap().entries.map((e) {
            final i = e.key;
            final row = e.value;
            final isActive = _activeRow == i;
            return MouseRegion(
              onEnter: (_) => setState(() => _activeRow = i),
              onExit: (_) => setState(() {
                if (_activeRow == i) _activeRow = null;
              }),
              child: GestureDetector(
                onTap: () => setState(
                    () => _activeRow = _activeRow == i ? null : i),
                child: Container(
                  color: isActive
                      ? theme.accentColor.withValues(alpha: 0.12)
                      : null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(row.length, (c) {
                      return _dataCell(
                        row[c],
                        _colColors[c],
                        isActive: isActive,
                        isHighlightedCol:
                            _mulStep >= 0 && _mulStep == c,
                      );
                    }),
                  ),
                ),
              ),
            );
          }),
          // Ellipsis row if there's more data
          if (widget.totalSamples > 5)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '⋮  (${widget.totalSamples - 5} more rows)',
                style: TextStyle(
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  color: theme.typography.body?.color
                      ?.withValues(alpha: 0.5),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _headerCell(String label, Color color) {
    return Container(
      width: 68,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }

  Widget _dataCell(double value, Color color,
      {bool isActive = false, bool isHighlightedCol = false}) {
    final highlight = isActive || isHighlightedCol;
    return Container(
      width: 68,
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      decoration: isHighlightedCol
          ? BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(2),
            )
          : null,
      child: Text(
        _formatNum(value),
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'Consolas',
          fontSize: 11,
          fontWeight: highlight ? FontWeight.w700 : FontWeight.normal,
          color: highlight ? color : color.withValues(alpha: 0.7),
        ),
      ),
    );
  }

  Widget _cell(
    String text, {
    Color? color,
    bool bold = false,
    bool isActive = false,
    void Function(bool)? onHover,
    VoidCallback? onTap,
  }) {
    Widget child = Container(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 6),
      color: isActive ? color?.withValues(alpha: 0.12) : null,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontFamily: 'Consolas',
          fontSize: 12,
          fontWeight: bold || isActive ? FontWeight.w700 : FontWeight.normal,
          color: color,
        ),
      ),
    );
    if (onHover != null || onTap != null) {
      child = MouseRegion(
        onEnter: onHover != null ? (_) => onHover(true) : null,
        onExit: onHover != null ? (_) => onHover(false) : null,
        child: GestureDetector(onTap: onTap, child: child),
      );
    }
    return child;
  }

  // ───────────────────────────────────────────────────────────────────
  // Row expansion — "This row says…"
  // ───────────────────────────────────────────────────────────────────
  Widget _buildRowExpansion(FluentThemeData theme) {
    final i = _activeRow!;
    final rows = _rows;
    if (i >= rows.length) return const SizedBox.shrink();

    final row = rows[i];
    final voltage = _voltages[i];
    final gains = widget.gains;

    // Build the expanded equation string with color spans.
    final parts = <InlineSpan>[];
    parts.add(TextSpan(
      text: '${voltage.toStringAsFixed(1)} V  ≈  ',
      style: TextStyle(
        fontFamily: 'Consolas',
        fontSize: 13,
        color: theme.typography.body?.color,
      ),
    ));

    for (var c = 0; c < row.length; c++) {
      if (c > 0) {
        parts.add(TextSpan(
          text: '  +  ',
          style: TextStyle(
            fontFamily: 'Consolas',
            fontSize: 13,
            color: theme.typography.body?.color?.withValues(alpha: 0.5),
          ),
        ));
      }
      final gainStr = gains != null
          ? [gains.kS, gains.kV, gains.kA, gains.kG][c].toStringAsFixed(3)
          : _gainLabels[c];
      parts.add(TextSpan(
        text: '${_formatNum(row[c])}',
        style: TextStyle(
          fontFamily: 'Consolas',
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: _colColors[c],
        ),
      ));
      parts.add(TextSpan(
        text: ' × $gainStr',
        style: TextStyle(
          fontFamily: 'Consolas',
          fontSize: 13,
          color: _colColors[c].withValues(alpha: 0.8),
        ),
      ));
    }

    // Descriptive label for each term
    final termNames = [
      '(direction × static friction)',
      '(speed × velocity constant)',
      '(acceleration × inertia)',
      if (_hasGravity)
        widget.mechanismType == MechanismType.arm
            ? '(gravity angle × gravity constant)'
            : '(gravity constant)',
    ];

    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.accentColor.withValues(alpha: 0.06),
        border: Border.all(color: theme.accentColor.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FluentIcons.calculator_multiply, size: 14,
                  color: theme.accentColor),
              const SizedBox(width: 6),
              Text(
                'Row ${i + 1} — one measurement, one equation:',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.accentColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          RichText(text: TextSpan(children: parts)),
          const SizedBox(height: 10),
          // Plain-english breakdown
          ...List.generate(row.length, (c) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _colColors[c],
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${_formatNum(row[c])} × ${gains != null ? [gains.kS, gains.kV, gains.kA, gains.kG][c].toStringAsFixed(3) : _gainLabels[c]}  =  '
                    '${c < termNames.length ? termNames[c] : ""}',
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'Consolas',
                      color: theme.typography.body?.color
                          ?.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 8),
          Text(
            'Add those up and you get the predicted voltage for this data '
            'point. The computer finds the gains that make this prediction '
            'as close to the real voltage as possible — for every row at once.',
            style: TextStyle(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: theme.typography.body?.color?.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────
  // Step-through multiplication
  // ───────────────────────────────────────────────────────────────────
  Widget _buildStepThrough(FluentThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: theme.typography.body?.color?.withValues(alpha: 0.1) ??
              const Color(0x1A888888),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'How the multiplication works — step by step',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: theme.typography.body?.color,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Each column of numbers in the table gets multiplied by one gain. '
            'Then all products in a row get added together to predict the '
            'voltage for that measurement. Click a step to highlight it:',
            style: TextStyle(
              fontSize: 12,
              color: theme.typography.body?.color?.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _stepButton(-1, 'All', theme),
              ...List.generate(_numCols, (c) {
                final desc = [
                  'sign(ω) × kS\n"Which direction?"',
                  'ω × kV\n"How fast?"',
                  'α × kA\n"Speeding up or slowing down?"',
                  if (_hasGravity)
                    'g(θ) × kG\n"Fighting gravity"',
                ];
                return _stepButton(c, desc[c], theme);
              }),
            ],
          ),
          const SizedBox(height: 10),
          if (_mulStep >= 0 && _mulStep < _numCols)
            _buildStepExplanation(_mulStep, theme),
        ],
      ),
    );
  }

  Widget _stepButton(int step, String label, FluentThemeData theme) {
    final isActive = _mulStep == step;
    final color =
        step >= 0 ? _colColors[step] : theme.typography.body?.color;
    return GestureDetector(
      onTap: () => setState(() => _mulStep = step),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isActive
              ? (color ?? const Color(0xFF888888)).withValues(alpha: 0.15)
              : theme.cardColor,
          border: Border.all(
            color: isActive
                ? (color ?? const Color(0xFF888888))
                : theme.typography.body?.color?.withValues(alpha: 0.2) ??
                    const Color(0x33888888),
            width: isActive ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.normal,
            color: isActive ? color : color?.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }

  Widget _buildStepExplanation(int col, FluentThemeData theme) {
    final explanations = [
      // kS — sign(ω)
      'The sign(ω) column is always +1 or −1. It tells us which direction '
      'the motor was spinning. Multiplying by kS gives the voltage needed '
      'just to overcome friction — like how you have to push a box hard enough '
      'to start it sliding before it moves at all. This is always the same '
      'amount no matter how fast the motor is spinning.',
      // kV — ω
      'The ω (velocity) column records how fast the motor was spinning at '
      'each moment. Multiplying by kV tells us how much voltage the motor '
      '"eats up" just to maintain that speed — think of it like wind '
      'resistance: the faster you go, the more force (voltage) you need '
      'just to keep going. This is the biggest term for most mechanisms.',
      // kA — α
      'The α (acceleration) column measures how quickly the speed was '
      'changing. Multiplying by kA tells us the extra voltage needed to '
      'speed up or slow down — like how you have to press the gas pedal '
      'harder to accelerate a heavier car. A mechanism with more inertia '
      '(heavier or further from the pivot) needs more voltage to change speed.',
      // kG — gravity
      widget.mechanismType == MechanismType.arm
          ? 'The g(θ) column is cos(θ) — it accounts for how much gravity '
            'is pulling on the arm at its current angle. When the arm is '
            'horizontal, cos(0°) = 1.0 and gravity pulls the hardest. '
            'When vertical, cos(90°) = 0 and gravity has no effect. '
            'Multiplying by kG gives the voltage needed to hold the arm '
            'up against gravity at that angle.'
          : 'The g(θ) column is always 1.0 for an elevator — gravity pulls '
            'with the same force no matter where the carriage is. '
            'Multiplying by kG gives the constant voltage needed to hold '
            'the elevator up against gravity at any height.',
    ];

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _colColors[col].withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _colColors[col].withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            margin: const EdgeInsets.only(top: 1, right: 8),
            decoration: BoxDecoration(
              color: _colColors[col],
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                _gainLabels[col],
                style: const TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFFFFFFFF),
                ),
              ),
            ),
          ),
          Expanded(
            child: Text(
              explanations[col],
              style: TextStyle(
                fontSize: 12,
                color: theme.typography.body?.color?.withValues(alpha: 0.8),
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────
  // Summary
  // ───────────────────────────────────────────────────────────────────
  Widget _buildSummary(FluentThemeData theme, TextStyle captionStyle) {
    final samplesNote = widget.totalSamples > 0
        ? 'In your test, there are ${widget.totalSamples} rows — '
          'one for every moment we recorded data. '
        : '';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.accentColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FluentIcons.lightbulb, size: 14,
                  color: theme.accentColor),
              const SizedBox(width: 6),
              Text(
                'The Big Picture',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.accentColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${samplesNote}'
            'The matrix equation is just a compact way to say:\n\n'
            '"For every data point, the voltage should equal:\n'
            '  (friction) + (speed cost) + (acceleration cost)'
            '${_hasGravity ? " + (gravity cost)" : ""}"\n\n'
            'The computer tries thousands of combinations of kS, kV, kA'
            '${_hasGravity ? ", kG" : ""} and picks the set that makes '
            'the predictions closest to the real voltages across ALL rows. '
            'This is called "least squares" because it minimizes the total '
            'squared error — like finding the best-fit line in your math '
            'class, but with ${_numCols} variables instead of 1.\n\n'
            'That\'s it! No magic, just organized arithmetic.',
            style: captionStyle,
          ),
        ],
      ),
    );
  }

  String _formatNum(double v) {
    if (v == 1.0) return ' 1.0';
    if (v == -1.0) return '-1.0';
    if (v.abs() < 10) return v.toStringAsFixed(1).padLeft(5);
    return v.toStringAsFixed(1);
  }
}
