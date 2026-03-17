/// Pole-Zero Map widget: visualizes closed-loop poles on the s-plane for
/// the identified plant model with PID controller.
///
/// Shows stability regions (left-half-plane = stable, right-half-plane =
/// unstable), poles as X markers, and annotates natural frequency / damping.
library;

import 'dart:math' as math;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart' show Material;

import '../../data/test_data.dart';
import '../../mechanisms/mechanism.dart' show MechanismType;
import '../../sysid/pid_autotuner.dart' show PidAutoTuner;
import 'chart_walkthrough.dart';

// ──────────────────────────────────────────────────────────────────────
// Public widget
// ──────────────────────────────────────────────────────────────────────

/// Whether to show the velocity or position loop.
/// Velocity PI → 2nd-order, Position PD → 2nd-order, Position PID → 3rd-order.
enum PoleZeroMode { velocity, position }

class PoleZeroMap extends StatefulWidget {
  final FeedforwardGains ff;
  final PidResult? velPid;
  final PidResult? posPid;

  /// Mechanism type — needed to compute the velocity-to-position rate factor
  /// (r = 60 for flywheel/simple, 1 for arm/elevator) in position CL poles.
  final MechanismType? mechanismType;

  /// When non-null, overrides the internal mode state.
  final PoleZeroMode? mode;

  /// Called when the user changes the mode selector.
  final ValueChanged<PoleZeroMode>? onModeChanged;

  const PoleZeroMap({
    super.key,
    required this.ff,
    this.velPid,
    this.posPid,
    this.mechanismType,
    this.mode,
    this.onModeChanged,
  });

  @override
  State<PoleZeroMap> createState() => _PoleZeroMapState();
}

class _PoleZeroMapState extends State<PoleZeroMap>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  PoleZeroMode _localMode = PoleZeroMode.velocity;
  bool _walkthroughActive = false;

  PoleZeroMode get _mode => widget.mode ?? _localMode;

  PidResult? get _activePid =>
      _mode == PoleZeroMode.velocity ? widget.velPid : widget.posPid;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final pid = _activePid;
    final poles = _computePoles(widget.ff, pid, _mode, widget.mechanismType);
    final delayPoles = _computeDelayAdjustedPoles(
        widget.ff, pid, _mode, widget.mechanismType);

    final chart = Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              const Icon(FluentIcons.chart_series, size: 16),
              const SizedBox(width: 8),
              const Text(
                'Pole-Zero Map — s-Plane',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              WalkthroughToggle(
                isActive: _walkthroughActive,
                onToggle: () =>
                    setState(() => _walkthroughActive = !_walkthroughActive),
              ),
              const SizedBox(width: 8),
              // Mode selector
              if (widget.velPid != null || widget.posPid != null)
                ComboBox<PoleZeroMode>(
                  value: _mode,
                  items: [
                    if (widget.velPid != null)
                      const ComboBoxItem<PoleZeroMode>(
                        value: PoleZeroMode.velocity,
                        child: Text('Velocity Loop'),
                      ),
                    if (widget.posPid != null)
                      const ComboBoxItem<PoleZeroMode>(
                        value: PoleZeroMode.position,
                        child: Text('Position Loop'),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _localMode = v);
                      widget.onModeChanged?.call(v);
                    }
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),

          // Legend
          _buildLegend(),
          const SizedBox(height: 2),

          // Explanation
          Text(
            _mode == PoleZeroMode.velocity
                ? 'Showing closed-loop poles of the velocity control system '
                  '(plant + PID controller combined). These describe how the '
                  'complete system responds — not the motor alone or the '
                  'controller alone.'
                : 'Showing closed-loop poles of the position control system '
                  '(plant + PID controller combined). These describe how the '
                  'complete system responds — not the motor alone or the '
                  'controller alone.',
            style: TextStyle(
              fontSize: 10,
              color: FluentTheme.of(context)
                  .typography
                  .body
                  ?.color
                  ?.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: 4),

          // s-plane painter
          Expanded(
            child: _SPlaneCanvas(
              poles: poles,
              delayPoles: delayPoles,
              ff: widget.ff,
              pid: pid,
              mode: _mode,
            ),
          ),
        ],
      ),
    );

    return ChartWalkthrough(
      isActive: _walkthroughActive,
      steps: _poleZeroWalkthroughSteps(_mode, poles),
      onDismiss: () => setState(() => _walkthroughActive = false),
      child: chart,
    );
  }

  Widget _buildLegend() {
    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        _legendMarker(color: _stablePoleColor, label: 'Closed-loop pole (ideal)', isX: true),
        _legendMarker(color: _delayPoleColor, label: 'With transport delay', isX: true),
        _legendMarker(color: _openLoopPoleColor, label: 'Open-loop pole', isX: false),
        _colorBox(
            color: _rootLocusColor.withValues(alpha: 0.7),
            label: 'Root locus'),
        _colorBox(
            color: _stableRegionColor.withValues(alpha: 0.25),
            label: 'Stable (LHP)'),
        _colorBox(
            color: _unstableRegionColor.withValues(alpha: 0.25),
            label: 'Unstable (RHP)'),
        _colorBox(
            color: _dampingLineColor.withValues(alpha: 0.5),
            label: 'Damping ratio lines'),
      ],
    );
  }

  Widget _legendMarker(
      {required Color color, required String label, required bool isX}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(isX ? 'X' : 'O',
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    );
  }

  Widget _colorBox({required Color color, required String label}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            border: Border.all(color: color.withValues(alpha: 0.6)),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10)),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────
// Pole computation
// ──────────────────────────────────────────────────────────────────────

class _Complex {
  final double re;
  final double im;
  const _Complex(this.re, this.im);

  bool get isStable => re < 0;
  double get magnitude => math.sqrt(re * re + im * im);

  /// Natural frequency (rad/s).
  double get wn => magnitude;

  /// Damping ratio (only meaningful for conjugate pairs).
  double get zeta => magnitude > 0 ? -re / magnitude : 0.0;

  @override
  String toString() {
    if (im == 0) return re.toStringAsFixed(3);
    final sign = im >= 0 ? '+' : '-';
    return '${re.toStringAsFixed(3)} $sign ${im.abs().toStringAsFixed(3)}j';
  }
}

/// Velocity-to-position rate factor: RPM / (rot/s) = 60 for flywheel/simple,
/// 1 for arm/elevator (velocity unit = d(position unit)/dt).
double _velocityToPositionRateFactor(MechanismType? type) {
  return switch (type) {
    MechanismType.flywheel || MechanismType.simple => 60.0,
    MechanismType.arm || MechanismType.elevator => 1.0,
    null => 1.0,
  };
}

List<_Complex> _computePoles(
    FeedforwardGains ff, PidResult? pid, PoleZeroMode mode,
    [MechanismType? mechanismType]) {
  final kA = ff.kA;
  final kV = ff.kV;

  if (kA <= 0) return [];

  // PID gains from the autotuner are in duty-cycle units (divided by
  // nominalVoltage).  The plant model is in voltage units, so we must
  // scale PID gains back to volts before combining with kV / kA.
  const nomV = 12.0;

  switch (mode) {
    case PoleZeroMode.velocity:
      // C(s)·G(s) = (kP_v·s + kI_v) / (s·(kA·s + kV))
      // Characteristic: kA·s² + (kV + kP_v)·s + kI_v = 0
      final kPv = (pid?.kP ?? 0.0) * nomV;
      final kIv = (pid?.kI ?? 0.0) * nomV;

      if (kIv == 0) {
        // Single real pole: s = -(kV + kPv)/kA
        return [_Complex(-(kV + kPv) / kA, 0)];
      }

      // Quadratic: kA·s² + (kV+kPv)·s + kIv = 0
      return _solveQuadratic(kA, kV + kPv, kIv);

    case PoleZeroMode.position:
      final r = _velocityToPositionRateFactor(mechanismType);
      final kPv = (pid?.kP ?? 0.0) * nomV;
      final kDv = (pid?.kD ?? 0.0) * nomV;
      final kIv = (pid?.kI ?? 0.0) * nomV;

      if (kIv.abs() < 1e-12) {
        return _solveQuadratic(r * kA, r * (kV + kDv), kPv);
      }
      return _solveCubic(r * kA, r * (kV + kDv), kPv, kIv);
  }
}

/// Compute closed-loop poles WITH a first-order Padé transport delay.
///
/// The Padé approximation e^{-sT} ≈ (1 − sT/2) / (1 + sT/2) adds one
/// pole and one zero to the loop gain, raising the characteristic equation
/// order by one.  This reveals oscillatory behaviour that the ideal
/// (delay-free) poles miss.
///
/// For example, the position PD loop (normally 2nd-order) becomes
/// 3rd-order, and the additional pole may have a complex part — exactly
/// the oscillation the user observes on real hardware.
List<_Complex> _computeDelayAdjustedPoles(
    FeedforwardGains ff, PidResult? pid, PoleZeroMode mode,
    [MechanismType? mechanismType,
    double transportDelaySec = PidAutoTuner.defaultTransportDelaySec]) {
  final kA = ff.kA;
  final kV = ff.kV;
  if (kA <= 0 || transportDelaySec <= 0) return [];
  if (pid == null) return [];

  const nomV = 12.0;
  final h = transportDelaySec / 2.0; // half-delay for Padé

  switch (mode) {
    case PoleZeroMode.velocity:
      // Ideal: kA·s + kV + kPv = 0 (1st order, single real pole)
      // With Padé delay on the controller:
      //   (kA·s + kV)(1 + hs) + kPv(1 - hs) = 0
      //   kA·h·s² + (kA + kV·h - kPv·h)·s + (kV + kPv) = 0
      final kPv = pid.kP * nomV;
      return _solveQuadratic(
        kA * h,
        kA + kV * h - kPv * h,
        kV + kPv,
      );

    case PoleZeroMode.position:
      final r = _velocityToPositionRateFactor(mechanismType);
      final kPv = pid.kP * nomV;
      final kDv = pid.kD * nomV;
      final kIv = pid.kI * nomV;

      if (kIv.abs() < 1e-12) {
        // PD case: ideal is 2nd-order → delay makes 3rd-order
        // (r·kA·s² + r·kV·s)(1 + hs) + (kPv + kDv·s)(1 - hs) = 0
        // s³: r·kA·h
        // s²: r·kA + r·kV·h − kDv·h
        // s¹: r·kV − kPv·h + kDv
        // s⁰: kPv
        return _solveCubic(
          r * kA * h,
          r * kA + r * kV * h - kDv * h,
          r * kV - kPv * h + kDv,
          kPv,
        );
      }
      // PID case: ideal is 3rd-order → delay makes 4th-order
      // (r·kA·s³ + r·(kV+kDv)·s² + kPv·s + kIv)(1 + hs)
      //   but we need the full closed-loop expansion with Padé.
      // Plant denominator: D(s) = r·kA·s² + r·kV·s
      // Controller: C(s) = kPv + kDv·s + kIv/s
      // With Padé: 1 + C(s)/D(s) · (1-hs)/(1+hs) = 0
      // → D(s)(1+hs) + [kPv·s + kDv·s² + kIv](1-hs) = 0
      // s⁴: r·kA·h
      // s³: r·kA + r·kV·h − kDv·h
      // s²: r·kV − kPv·h + kDv
      // s¹: kPv − kIv·h
      // s⁰: kIv
      return _solveQuartic(
        r * kA * h,
        r * kA + r * kV * h - kDv * h,
        r * kV - kPv * h + kDv,
        kPv - kIv * h,
        kIv,
      );
  }
}

List<_Complex> _solveQuadratic(double a, double b, double c) {
  if (a == 0) {
    if (b == 0) return [];
    return [_Complex(-c / b, 0)];
  }
  final disc = b * b - 4 * a * c;
  if (disc >= 0) {
    final sqrtDisc = math.sqrt(disc);
    return [
      _Complex((-b + sqrtDisc) / (2 * a), 0),
      _Complex((-b - sqrtDisc) / (2 * a), 0),
    ];
  } else {
    final realPart = -b / (2 * a);
    final imagPart = math.sqrt(-disc) / (2 * a);
    return [
      _Complex(realPart, imagPart),
      _Complex(realPart, -imagPart),
    ];
  }
}

/// Cube root that handles negative values.
double _cbrt(double x) =>
    x >= 0 ? math.pow(x, 1.0 / 3.0).toDouble() : -math.pow(-x, 1.0 / 3.0).toDouble();

/// Solve a cubic equation ax³ + bx² + cx + d = 0 using Cardano / trigonometric method.
List<_Complex> _solveCubic(double a, double b, double c, double d) {
  if (a.abs() < 1e-15) return _solveQuadratic(b, c, d);

  // Normalize: x³ + px² + qx + r = 0
  final p = b / a;
  final q = c / a;
  final r = d / a;

  // Depressed cubic: t³ + At + B = 0 where x = t - p/3
  final A = q - p * p / 3;
  final B = r - p * q / 3 + 2 * p * p * p / 27;

  final disc = -4 * A * A * A - 27 * B * B;

  if (disc > 1e-10) {
    // Three distinct real roots – trigonometric method
    final m = 2 * math.sqrt(-A / 3);
    final theta = math.acos(3 * B / (A * m)) / 3;
    return [
      _Complex(m * math.cos(theta) - p / 3, 0),
      _Complex(m * math.cos(theta - 2 * math.pi / 3) - p / 3, 0),
      _Complex(m * math.cos(theta - 4 * math.pi / 3) - p / 3, 0),
    ];
  } else if (disc < -1e-10) {
    // One real root + conjugate pair – Cardano
    final sqrtD = math.sqrt(B * B / 4 + A * A * A / 27);
    final u = _cbrt(-B / 2 + sqrtD);
    final v = _cbrt(-B / 2 - sqrtD);
    final realRoot = u + v - p / 3;
    final complexRe = -(u + v) / 2 - p / 3;
    final complexIm = (u - v) * math.sqrt(3) / 2;
    return [
      _Complex(realRoot, 0),
      _Complex(complexRe, complexIm),
      _Complex(complexRe, -complexIm),
    ];
  } else {
    // Repeated roots
    if (B.abs() < 1e-15) {
      return [
        _Complex(-p / 3, 0),
        _Complex(-p / 3, 0),
        _Complex(-p / 3, 0),
      ];
    }
    final u = _cbrt(-B / 2);
    return [
      _Complex(2 * u - p / 3, 0),
      _Complex(-u - p / 3, 0),
      _Complex(-u - p / 3, 0),
    ];
  }
}

/// Solve a quartic equation ax⁴ + bx³ + cx² + dx + e = 0.
///
/// Uses the companion-matrix eigenvalue approach via the cubic resolvent
/// (Ferrari's method).  Falls back to cubic/quadratic for degenerate cases.
List<_Complex> _solveQuartic(
    double a, double b, double c, double d, double e) {
  if (a.abs() < 1e-15) return _solveCubic(b, c, d, e);

  // Normalize: x⁴ + Bx³ + Cx² + Dx + E = 0
  final B = b / a;
  final C = c / a;
  final D = d / a;
  final E = e / a;

  // Depressed quartic via substitution x = t - B/4:
  //   t⁴ + pt² + qt + r = 0
  final p = C - 3 * B * B / 8;
  final q = D - B * C / 2 + B * B * B / 8;
  final r = E - B * D / 4 + B * B * C / 16 - 3 * B * B * B * B / 256;

  // Resolvent cubic: y³ + (p/2)y² + ((p²-4r)/16)y - q²/64 = 0
  // We need one real root y₁ to factor the depressed quartic.
  final cubicRoots = _solveCubic(
    1.0,
    p / 2,
    (p * p - 4 * r) / 16,
    -q * q / 64,
  );

  // Pick the largest real root from the cubic resolvent.
  double y1 = 0;
  for (final root in cubicRoots) {
    if (root.im.abs() < 1e-10 && root.re > y1) {
      y1 = root.re;
    }
  }
  // Ensure y1 is non-negative for the sqrt (numerical guard).
  if (y1 < 0) y1 = 0;

  final sqrtY1 = math.sqrt(y1);
  final shift = -B / 4;

  // Factor into two quadratics:
  //   t² + sqrt(2y₁)·t + (y₁ + p/2 + q/(4·sqrt(2y₁))) = 0
  //   t² - sqrt(2y₁)·t + (y₁ + p/2 - q/(4·sqrt(2y₁))) = 0
  // (guard against sqrtY1 ≈ 0)
  final s2y = math.sqrt(2) * sqrtY1;
  final qTerm = (s2y.abs() > 1e-12) ? q / (4 * s2y) : 0.0;

  final c1 = y1 + p / 2 + qTerm;
  final c2 = y1 + p / 2 - qTerm;

  final roots1 = _solveQuadratic(1, s2y, c1);
  final roots2 = _solveQuadratic(1, -s2y, c2);

  // Shift back from depressed form.
  return [
    for (final root in [...roots1, ...roots2])
      _Complex(root.re + shift, root.im),
  ];
}

// ──────────────────────────────────────────────────────────────────────
// s-plane CustomPainter
// ──────────────────────────────────────────────────────────────────────

const Color _stableRegionColor = Color(0xFF44AA44);
const Color _unstableRegionColor = Color(0xFFAA4444);
const Color _stablePoleColor = Color(0xFF22BB22);
const Color _unstablePoleColor = Color(0xFFDD3333);
const Color _delayPoleColor = Color(0xFFDDAA00);
const Color _delayPoleUnstableColor = Color(0xFFFF6622);
const Color _rootLocusColor = Color(0xFFFF8800);
const Color _openLoopPoleColor = Color(0xFF6688CC);
const Color _dampingLineColor = Color(0xFF888888);
const Color _wnCircleColor = Color(0xFF666666);
const Color _gridColor = Color(0xFF555555);
const Color _axisColor = Color(0xFFBBBBBB);
const Color _labelColor = Color(0xFFDDDDDD);

class _SPlaneCanvas extends StatefulWidget {
  final List<_Complex> poles;
  final List<_Complex> delayPoles;
  final FeedforwardGains ff;
  final PidResult? pid;
  final PoleZeroMode mode;

  const _SPlaneCanvas({
    required this.poles,
    this.delayPoles = const [],
    required this.ff,
    this.pid,
    required this.mode,
  });

  @override
  State<_SPlaneCanvas> createState() => _SPlaneCanvasState();
}

/// Describes a hoverable element on the s-plane (pole or open-loop pole).
class _HoverableElement {
  final _Complex value;
  final bool isClosedLoop;
  final bool isDelayAdjusted;
  final int multiplicity;
  const _HoverableElement({
    required this.value,
    required this.isClosedLoop,
    this.isDelayAdjusted = false,
    this.multiplicity = 1,
  });
}

class _SPlaneCanvasState extends State<_SPlaneCanvas> {
  Offset? _mousePosition;
  _HoverableElement? _hoveredElement;
  OverlayEntry? _overlayEntry;

  // ── Zoom & pan state ──────────────────────────────────────────────
  double _zoomLevel = 1.0; // 1.0 = auto-fit
  Offset _panOffset = Offset.zero; // world-space (Re, Im) offset
  bool _isPanning = false;
  Offset? _panStartPixel;
  Offset? _panOffsetStart;

  @override
  void didUpdateWidget(covariant _SPlaneCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Auto-reset view when poles change, unless user has manually zoomed.
    if (_zoomLevel == 1.0 && _panOffset == Offset.zero) return;
    final polesChanged = widget.poles.length != oldWidget.poles.length ||
        widget.delayPoles.length != oldWidget.delayPoles.length;
    if (polesChanged && _zoomLevel == 1.0) {
      _panOffset = Offset.zero;
    }
  }

  @override
  void dispose() {
    _removeOverlay();
    super.dispose();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _showOverlayTooltip(BuildContext context) {
    _removeOverlay();
    if (_hoveredElement == null || _mousePosition == null) return;

    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final globalPos = renderBox.localToGlobal(_mousePosition!);
    final screenSize = MediaQuery.of(context).size;
    final theme = FluentTheme.of(context);

    const tooltipWidth = 320.0;
    const tooltipMaxHeight = 300.0;

    // Position: to right of cursor, or left if near right edge
    double left = globalPos.dx + 14;
    if (left + tooltipWidth > screenSize.width - 8) {
      left = globalPos.dx - tooltipWidth - 14;
    }
    // Above cursor if near bottom, else below
    double top = globalPos.dy + 14;
    if (top + tooltipMaxHeight > screenSize.height - 8) {
      top = globalPos.dy - tooltipMaxHeight - 14;
      if (top < 8) top = 8;
    }

    final element = _hoveredElement!;
    final description = _describeElement(element);
    final borderColor = element.isDelayAdjusted
        ? (element.value.isStable ? _delayPoleColor : _delayPoleUnstableColor)
        : element.isClosedLoop
            ? (element.value.isStable ? _stablePoleColor : _unstablePoleColor)
            : _openLoopPoleColor;

    _overlayEntry = OverlayEntry(
      builder: (_) => Positioned(
        left: left,
        top: top,
        child: IgnorePointer(
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(
                  maxWidth: tooltipWidth, maxHeight: tooltipMaxHeight),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.micaBackgroundColor,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: borderColor, width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                child: Text(
                  description,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    color: theme.typography.body?.color,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  double _autoFitMaxAbs() {
    // Collect the extent (max of |Re|, |Im|) of every pole.
    final extents = <double>[];
    for (final p in widget.poles) {
      extents.add(math.max(p.re.abs(), p.im.abs()));
    }
    for (final p in widget.delayPoles) {
      extents.add(math.max(p.re.abs(), p.im.abs()));
    }
    if (extents.isEmpty) return 50.0;

    extents.sort();

    // Use the median pole extent as the "dominant" reference.  If a pole is
    // more than 4× the median, it's an outlier (much faster pole that would
    // waste screen space) and is excluded from the auto-fit range.
    final median = extents[extents.length ~/ 2];
    final threshold = math.max(median * 4.0, 50.0);

    double maxAbs = 50.0;
    for (final e in extents) {
      final clamped = math.min(e, threshold);
      if (clamped * 1.3 > maxAbs) maxAbs = clamped * 1.3;
    }
    return (maxAbs * 1.2).ceilToDouble();
  }

  /// Compute the visible world extents, applying zoom and pan.
  ({double realMin, double realMax, double imagMin, double imagMax})
      _viewExtents() {
    final baseMaxAbs = _autoFitMaxAbs();
    final halfRange = baseMaxAbs / _zoomLevel;
    final cx = _panOffset.dx;
    final cy = _panOffset.dy;
    return (
      realMin: cx - halfRange,
      realMax: cx + halfRange,
      imagMin: cy - halfRange,
      imagMax: cy + halfRange,
    );
  }

  _HoverableElement? _hitTest(Offset localPosition, Size size) {
    final ext = _viewExtents();

    double toX(double re) =>
        (re - ext.realMin) / (ext.realMax - ext.realMin) * size.width;
    double toY(double im) =>
        (1 - (im - ext.imagMin) / (ext.imagMax - ext.imagMin)) * size.height;

    const hitRadius = 12.0;

    // Check closed-loop poles first (higher priority)
    final clDrawn = <int>{};
    for (int i = 0; i < widget.poles.length; i++) {
      if (clDrawn.contains(i)) continue;
      final pole = widget.poles[i];
      int mult = 1;
      for (int j = i + 1; j < widget.poles.length; j++) {
        if (!clDrawn.contains(j) &&
            (pole.re - widget.poles[j].re).abs() < 1e-3 &&
            (pole.im - widget.poles[j].im).abs() < 1e-3) {
          mult++;
          clDrawn.add(j);
        }
      }
      clDrawn.add(i);

      final px = toX(pole.re);
      final py = toY(pole.im);
      if ((localPosition - Offset(px, py)).distance < hitRadius) {
        return _HoverableElement(
          value: pole,
          isClosedLoop: true,
          multiplicity: mult,
        );
      }
    }

    // Check open-loop poles
    final olPoles = _computeOpenLoopPolesFor(widget.ff, widget.pid, widget.mode);
    final olDrawn = <int>{};
    for (int i = 0; i < olPoles.length; i++) {
      if (olDrawn.contains(i)) continue;
      final olp = olPoles[i];
      int mult = 1;
      for (int j = i + 1; j < olPoles.length; j++) {
        if (!olDrawn.contains(j) &&
            (olp.re - olPoles[j].re).abs() < 1e-3 &&
            (olp.im - olPoles[j].im).abs() < 1e-3) {
          mult++;
          olDrawn.add(j);
        }
      }
      olDrawn.add(i);

      final px = toX(olp.re);
      final py = toY(olp.im);
      if ((localPosition - Offset(px, py)).distance < hitRadius) {
        return _HoverableElement(
          value: olp,
          isClosedLoop: false,
          multiplicity: mult,
        );
      }
    }

    // Check delay-adjusted poles
    final dpDrawn = <int>{};
    for (int i = 0; i < widget.delayPoles.length; i++) {
      if (dpDrawn.contains(i)) continue;
      final dp = widget.delayPoles[i];
      int mult = 1;
      for (int j = i + 1; j < widget.delayPoles.length; j++) {
        if (!dpDrawn.contains(j) &&
            (dp.re - widget.delayPoles[j].re).abs() < 1e-3 &&
            (dp.im - widget.delayPoles[j].im).abs() < 1e-3) {
          mult++;
          dpDrawn.add(j);
        }
      }
      dpDrawn.add(i);

      final px = toX(dp.re);
      final py = toY(dp.im);
      if ((localPosition - Offset(px, py)).distance < hitRadius) {
        return _HoverableElement(
          value: dp,
          isClosedLoop: true,
          isDelayAdjusted: true,
          multiplicity: mult,
        );
      }
    }

    return null;
  }

  String _describeElement(_HoverableElement el) {
    final p = el.value;
    final multStr = el.multiplicity > 1 ? ' (×${el.multiplicity})' : '';
    final buf = StringBuffer();

    if (el.isClosedLoop) {
      if (el.isDelayAdjusted) {
        buf.writeln('Delay-Adjusted Pole$multStr');
        buf.writeln('s = $p');
        buf.writeln('');
        buf.writeln('This pole includes the effect of ~${(PidAutoTuner.defaultTransportDelaySec * 1000).round()} ms on-controller '
            'transport delay (sensor → PID → PWM) using a first-order '
            'Padé approximation. This is what the REAL system sees.');
        buf.writeln('');
      } else {
        buf.writeln('Closed-Loop Pole$multStr (ideal, no delay)');
        buf.writeln('s = $p');
        buf.writeln('');
      }

      if (!p.isStable) {
        buf.writeln('This pole is in the RIGHT half-plane (Re > 0), '
            'meaning it causes the output to GROW exponentially. '
            'Your system is UNSTABLE. Reduce kP or kI to pull '
            'this pole back into the stable region.');
      } else if (p.im.abs() < 1e-6) {
        // Real stable pole
        final timeConst = p.re != 0 ? (-1.0 / p.re) : double.infinity;
        buf.writeln('Real pole at ${p.re.toStringAsFixed(2)}.');
        buf.writeln('');
        buf.writeln('Time constant: ${timeConst.toStringAsFixed(3)} s');
        buf.writeln('This pole contributes a pure exponential decay '
            'with no oscillation. It takes about ${(3 * timeConst).toStringAsFixed(2)}s '
            '(3τ) to mostly settle and ${(5 * timeConst).toStringAsFixed(2)}s '
            '(5τ) to fully settle.');
        if (p.re > -5) {
          buf.writeln('');
          buf.writeln('This is a relatively slow pole — it will make '
              'the system sluggish. Increasing kP moves it further left '
              '(faster response).');
        } else if (p.re < -100) {
          buf.writeln('');
          buf.writeln('This is a fast pole — it settles almost instantly '
              'and has little effect on the visible response. The slower '
              'poles dominate behavior.');
        }
      } else if (p.im > 0) {
        // Complex conjugate pair (show info for upper one)
        final wn = p.wn;
        final zeta = p.zeta;
        final dampedFreq = wn * math.sqrt(1 - zeta * zeta);
        final oscPeriod = dampedFreq > 0 ? 2 * math.pi / dampedFreq : double.infinity;
        final envelope = p.re != 0 ? (-1.0 / p.re) : double.infinity;

        buf.writeln('Complex conjugate pair:');
        buf.writeln('  ωn = ${wn.toStringAsFixed(2)} rad/s (natural frequency)');
        buf.writeln('  ζ = ${zeta.toStringAsFixed(3)} (damping ratio)');
        buf.writeln('');

        if (zeta < 0.3) {
          buf.writeln('Very underdamped — this pole pair causes significant '
              'oscillation (ringing) at ${dampedFreq.toStringAsFixed(1)} rad/s '
              '(period ≈ ${oscPeriod.toStringAsFixed(3)}s). '
              'You will see large overshoot and many cycles before settling. '
              'Increase kD or reduce kP to add damping.');
        } else if (zeta < 0.5) {
          buf.writeln('Underdamped — the response oscillates at '
              '${dampedFreq.toStringAsFixed(1)} rad/s with moderate ringing. '
              'Expect noticeable overshoot (roughly '
              '${(100 * math.exp(-math.pi * zeta / math.sqrt(1 - zeta * zeta))).toStringAsFixed(0)}%). '
              'Adding more kD can reduce this.');
        } else if (zeta < 0.8) {
          buf.writeln('Well-damped — good balance of speed and stability. '
              'Oscillation at ${dampedFreq.toStringAsFixed(1)} rad/s damps out '
              'quickly (envelope τ ≈ ${envelope.toStringAsFixed(3)}s). '
              'Overshoot ≈ '
              '${(100 * math.exp(-math.pi * zeta / math.sqrt(1 - zeta * zeta))).toStringAsFixed(0)}%. '
              'ζ ≈ 0.707 is often considered optimal.');
        } else {
          buf.writeln('Heavily damped — minimal oscillation, almost no '
              'overshoot (~${(100 * math.exp(-math.pi * zeta / math.sqrt(1 - zeta * zeta))).toStringAsFixed(0)}%), '
              'but the response is slower than optimal. '
              'Settling in ≈ ${(3 * envelope).toStringAsFixed(2)}s.');
        }
      }
    } else {
      // Open-loop pole
      buf.writeln('Open-Loop Pole$multStr');
      buf.writeln('s = $p');
      buf.writeln('');

      if (p.re.abs() < 1e-6 && p.im.abs() < 1e-6) {
        if (el.multiplicity >= 2) {
          buf.writeln('Double integrator at the origin — the plant has two '
              'free integrators (position = ∫∫acceleration). This makes '
              'the system inherently harder to stabilize. The PID controller '
              'must provide enough damping (kD) to keep the closed-loop '
              'poles stable.');
        } else {
          buf.writeln('Integrator at the origin — this means the plant '
              'accumulates its input over time (e.g., velocity integrates '
              'to position). Without a controller, the output drifts '
              'indefinitely. The PID controller reshapes this into a '
              'stable closed-loop pole.');
        }
      } else if (p.im.abs() < 1e-6) {
        final timeConst = p.re != 0 ? (-1.0 / p.re) : double.infinity;
        buf.writeln('Plant pole at ${p.re.toStringAsFixed(2)} (τ = '
            '${timeConst.toStringAsFixed(3)}s).');
        buf.writeln('');
        buf.writeln('This represents the motor\'s natural time constant '
            '(τ = kA/kV). It determines how quickly the motor responds '
            'to voltage changes WITHOUT any controller. The PID '
            'controller moves this pole to achieve the desired '
            'closed-loop speed.');
      }

      buf.writeln('');
      buf.writeln('The root locus (orange) shows where this pole '
          'migrates as controller gain increases.');
    }

    return buf.toString().trimRight();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // Find the canvas RenderBox to get size for coordinate conversion.
      final renderBox = context.findRenderObject() as RenderBox?;
      if (renderBox == null) return;
      final size = renderBox.size;
      final local = renderBox.globalToLocal(event.position);

      final ext = _viewExtents();

      // World coordinate under the cursor BEFORE zoom.
      final worldReBefore =
          ext.realMin + (local.dx / size.width) * (ext.realMax - ext.realMin);
      final worldImBefore =
          ext.imagMax - (local.dy / size.height) * (ext.imagMax - ext.imagMin);

      // Apply zoom.
      final factor = event.scrollDelta.dy > 0 ? 0.85 : 1.18;
      final newZoom = (_zoomLevel * factor).clamp(0.25, 50.0);

      // World coordinate under the cursor AFTER zoom (with old panOffset).
      final baseMaxAbs = _autoFitMaxAbs();
      final newHalf = baseMaxAbs / newZoom;
      final worldReAfter =
          (_panOffset.dx - newHalf) + (local.dx / size.width) * 2.0 * newHalf;
      final worldImAfter =
          (_panOffset.dy + newHalf) - (local.dy / size.height) * 2.0 * newHalf;

      // Shift pan so the world point under cursor doesn't move.
      setState(() {
        _zoomLevel = newZoom;
        _panOffset = Offset(
          _panOffset.dx + (worldReBefore - worldReAfter),
          _panOffset.dy + (worldImBefore - worldImAfter),
        );
      });
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    // Middle button (4) or right button (2) start panning.
    if (event.buttons == 4 || event.buttons == 2) {
      _isPanning = true;
      _panStartPixel = event.localPosition;
      _panOffsetStart = _panOffset;
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_isPanning || _panStartPixel == null || _panOffsetStart == null) {
      return;
    }
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final size = renderBox.size;

    final ext = _viewExtents();
    final worldPerPixelX = (ext.realMax - ext.realMin) / size.width;
    final worldPerPixelY = (ext.imagMax - ext.imagMin) / size.height;

    final dx = event.localPosition.dx - _panStartPixel!.dx;
    final dy = event.localPosition.dy - _panStartPixel!.dy;

    setState(() {
      _panOffset = Offset(
        _panOffsetStart!.dx - dx * worldPerPixelX,
        _panOffsetStart!.dy + dy * worldPerPixelY,
      );
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    _isPanning = false;
    _panStartPixel = null;
    _panOffsetStart = null;
  }

  void _resetView() {
    setState(() {
      _zoomLevel = 1.0;
      _panOffset = Offset.zero;
    });
  }

  bool get _isViewModified => _zoomLevel != 1.0 || _panOffset != Offset.zero;

  @override
  Widget build(BuildContext context) {
    final ext = _viewExtents();

    return SizedBox.expand(
      child: Listener(
        onPointerSignal: _onPointerSignal,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        child: MouseRegion(
          onHover: (event) {
            if (_isPanning) return;
            setState(() {
              _mousePosition = event.localPosition;
            });
            // Refresh overlay on next frame after setState hit-tests
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _showOverlayTooltip(context);
            });
          },
          onExit: (_) {
            setState(() {
              _mousePosition = null;
              _hoveredElement = null;
            });
            _removeOverlay();
          },
          cursor: _isPanning
              ? SystemMouseCursors.grabbing
              : _hoveredElement != null
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, constraints.maxHeight);

              // Update hovered element based on current mouse position
              if (_mousePosition != null && !_isPanning) {
                _hoveredElement = _hitTest(_mousePosition!, size);
              } else {
                _hoveredElement = null;
              }

              return Stack(
                children: [
                  CustomPaint(
                    size: size,
                    painter: _SPlanePainter(
                      poles: widget.poles,
                      delayPoles: widget.delayPoles,
                      ff: widget.ff,
                      pid: widget.pid,
                      mode: widget.mode,
                      realMin: ext.realMin,
                      realMax: ext.realMax,
                      imagMin: ext.imagMin,
                      imagMax: ext.imagMax,
                    ),
                  ),
                  if (_isViewModified)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: IconButton(
                        icon: const Icon(FluentIcons.reset, size: 14),
                        onPressed: _resetView,
                      ),
                    ),
                  if (!_isViewModified)
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: Text(
                        'Shift+Scroll to zoom · Right-click to pan',
                        style: TextStyle(
                          fontSize: 11,
                          color: FluentTheme.of(context)
                              .typography
                              .caption
                              ?.color
                              ?.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Compute open-loop poles (shared between painter and hit-test).
List<_Complex> _computeOpenLoopPolesFor(
    FeedforwardGains ff, PidResult? pid, PoleZeroMode mode) {
  final kA = ff.kA;
  final kV = ff.kV;
  if (kA <= 0) return [];

  final hasIntegrator = (pid?.kI ?? 0.0).abs() > 1e-12;

  switch (mode) {
    case PoleZeroMode.velocity:
      if (hasIntegrator) {
        return [const _Complex(0, 0), _Complex(-kV / kA, 0)];
      }
      return [_Complex(-kV / kA, 0)];
    case PoleZeroMode.position:
      if (hasIntegrator) {
        return [
          const _Complex(0, 0),
          const _Complex(0, 0),
          _Complex(-kV / kA, 0),
        ];
      }
      return [const _Complex(0, 0), _Complex(-kV / kA, 0)];
  }
}

class _SPlanePainter extends CustomPainter {
  final List<_Complex> poles;
  final List<_Complex> delayPoles;
  final FeedforwardGains ff;
  final PidResult? pid;
  final PoleZeroMode mode;
  final double realMin;
  final double realMax;
  final double imagMin;
  final double imagMax;

  const _SPlanePainter({
    required this.poles,
    this.delayPoles = const [],
    required this.ff,
    this.pid,
    required this.mode,
    required this.realMin,
    required this.realMax,
    required this.imagMin,
    required this.imagMax,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);

    // Coordinate helpers
    double toX(double re) =>
        (re - realMin) / (realMax - realMin) * size.width;
    double toY(double im) =>
        (1 - (im - imagMin) / (imagMax - imagMin)) * size.height;

    final originX = toX(0);
    final originY = toY(0);

    // ── Background stability regions ──────────────────────────────────
    final stablePaint = Paint()
      ..color = _stableRegionColor.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;
    final unstablePaint = Paint()
      ..color = _unstableRegionColor.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;

    canvas.drawRect(
        Rect.fromLTRB(0, 0, originX, size.height), stablePaint);
    canvas.drawRect(
        Rect.fromLTRB(originX, 0, size.width, size.height), unstablePaint);

    // ── Grid lines ────────────────────────────────────────────────────
    final gridPaint = Paint()
      ..color = _gridColor.withValues(alpha: 0.35)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    final halfRange = (realMax - realMin) / 2.0;
    final step = _niceStep(halfRange);
    // Find grid-aligned start/end for visible range.
    final gridStartRe = (realMin / step).floor() * step;
    final gridEndRe = (realMax / step).ceil() * step;
    final gridStartIm = (imagMin / step).floor() * step;
    final gridEndIm = (imagMax / step).ceil() * step;
    for (double v = gridStartRe; v <= gridEndRe + step * 0.1; v += step) {
      final px = toX(v);
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), gridPaint);
    }
    for (double v = gridStartIm; v <= gridEndIm + step * 0.1; v += step) {
      final py = toY(v);
      canvas.drawLine(Offset(0, py), Offset(size.width, py), gridPaint);
    }

    // ── Imaginary axis (stability boundary) ──────────────────────────
    final axisPaint = Paint()
      ..color = _axisColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
        Offset(originX, 0), Offset(originX, size.height), axisPaint);
    canvas.drawLine(
        Offset(0, originY), Offset(size.width, originY), axisPaint);

    // ── Axis labels ───────────────────────────────────────────────────
    final labelStyle = TextStyle(
        color: _labelColor, fontSize: 9, fontFamily: 'monospace');
    // Label format: use decimals when zoomed in enough
    String fmtLabel(double v) {
      if (halfRange < 2) return v.toStringAsFixed(1);
      return v.toStringAsFixed(0);
    }
    for (double v = gridStartRe; v <= gridEndRe + step * 0.1; v += step) {
      if (v.abs() < step * 0.1) continue; // skip zero
      final py = originY.clamp(0.0, size.height - 12);
      _drawLabel(canvas, fmtLabel(v),
          Offset(toX(v), py + 4), labelStyle, TextAlign.center);
    }
    for (double v = gridStartIm; v <= gridEndIm + step * 0.1; v += step) {
      if (v.abs() < step * 0.1) continue;
      final px = originX.clamp(0.0, size.width - 30);
      _drawLabel(canvas, fmtLabel(v),
          Offset(px + 4, toY(v)), labelStyle, TextAlign.left);
    }

    // Axis name labels
    final axisNameStyle =
        TextStyle(color: _labelColor, fontSize: 10, fontStyle: FontStyle.italic);
    _drawLabel(
        canvas, 'Re', Offset(size.width - 16, originY - 14), axisNameStyle,
        TextAlign.right);
    _drawLabel(
        canvas, 'Im', Offset(originX + 6, 4), axisNameStyle, TextAlign.left);

    // Stability boundary label
    final boundaryStyle = TextStyle(
        color: _axisColor.withValues(alpha: 0.7),
        fontSize: 9,
        fontStyle: FontStyle.italic);
    _drawLabel(canvas, 'Stability\nboundary',
        Offset(originX + 4, size.height * 0.08), boundaryStyle, TextAlign.left);

    // ── Constant damping ratio lines ──────────────────────────────────
    final dampingPaint = Paint()
      ..color = _dampingLineColor.withValues(alpha: 0.35)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    final dampingLabelStyle = TextStyle(
        color: _dampingLineColor.withValues(alpha: 0.6),
        fontSize: 8,
        fontStyle: FontStyle.italic);
    // Use diagonal extent to ensure lines reach corners when panned.
    final diagExtent = math.sqrt(halfRange * halfRange * 2) * 1.2;
    for (final zeta in [0.3, 0.5, 0.707, 0.9]) {
      // ζ = cos(θ) where θ is angle from negative real axis
      final theta = math.acos(zeta);
      // Draw line from origin at angle π-θ and π+θ (both upper and lower)
      final lineLen = diagExtent;
      final reEnd = -lineLen * math.cos(theta);
      final imEnd = lineLen * math.sin(theta);
      // Upper half (only in LHP)
      canvas.drawLine(
          Offset(originX, originY),
          Offset(toX(reEnd), toY(imEnd)),
          dampingPaint);
      // Lower half
      canvas.drawLine(
          Offset(originX, originY),
          Offset(toX(reEnd), toY(-imEnd)),
          dampingPaint);
      // Label near the end
      final labelRe = reEnd * 0.75;
      final labelIm = imEnd * 0.75;
      final zetaStr = zeta == 0.707 ? '0.707' : zeta.toString();
      _drawLabel(canvas, 'z=$zetaStr',
          Offset(toX(labelRe) - 4, toY(labelIm) - 10),
          dampingLabelStyle, TextAlign.left);
    }

    // ── Natural frequency arcs (LHP only) ─────────────────────────────
    final wnPaint = Paint()
      ..color = _wnCircleColor.withValues(alpha: 0.2)
      ..strokeWidth = 0.6
      ..style = PaintingStyle.stroke;
    final wnStep = _niceStep(halfRange);
    // Draw arcs for natural frequency values in the visible range.
    final maxVisibleWn = diagExtent;
    for (double wn = wnStep; wn < maxVisibleWn; wn += wnStep) {
      // Convert wn (world radius) to pixel radius.
      final rPx = wn / halfRange * (size.width / 2);
      // Draw arc only in LHP (from 90° to 270° i.e. left semicircle)
      canvas.drawArc(
        Rect.fromCircle(center: Offset(originX, originY), radius: rPx),
        math.pi / 2, // start at bottom of LHP
        math.pi,     // sweep 180° through LHP
        false,
        wnPaint,
      );
    }

    // ── Root locus ────────────────────────────────────────────────────
    _drawRootLocus(canvas, size, toX, toY);

    // ── Open-loop poles ───────────────────────────────────────────────
    final olPoles = _computeOpenLoopPolesFor(ff, pid, mode);
    // ── Open-loop poles (with multiplicity) ─────────────────────────
    final olDrawn = <int>{};
    for (int i = 0; i < olPoles.length; i++) {
      if (olDrawn.contains(i)) continue;
      final olp = olPoles[i];
      int mult = 1;
      for (int j = i + 1; j < olPoles.length; j++) {
        if (!olDrawn.contains(j) &&
            (olp.re - olPoles[j].re).abs() < 1e-3 &&
            (olp.im - olPoles[j].im).abs() < 1e-3) {
          mult++;
          olDrawn.add(j);
        }
      }
      olDrawn.add(i);
      final px = toX(olp.re);
      final py = toY(olp.im);
      _drawOMarker(canvas, Offset(px, py), _openLoopPoleColor);
      if (mult > 1) {
        _drawLabel(
          canvas,
          '×$mult',
          Offset(px + 8, py - 10),
          TextStyle(
              color: _openLoopPoleColor.withValues(alpha: 0.85), fontSize: 9),
          TextAlign.left,
        );
      }
    }

    // ── Closed-loop poles (with multiplicity detection) ─────────────
    // Group poles that are at (nearly) the same location.
    final drawn = <int>{};
    for (int i = 0; i < poles.length; i++) {
      if (drawn.contains(i)) continue;
      final pole = poles[i];
      int mult = 1;
      for (int j = i + 1; j < poles.length; j++) {
        if (!drawn.contains(j) &&
            (pole.re - poles[j].re).abs() < 1e-3 &&
            (pole.im - poles[j].im).abs() < 1e-3) {
          mult++;
          drawn.add(j);
        }
      }
      drawn.add(i);

      final px = toX(pole.re);
      final py = toY(pole.im);
      final color = pole.isStable ? _stablePoleColor : _unstablePoleColor;
      _drawXMarker(canvas, Offset(px, py), color);

      // Annotate natural frequency (wn) and damping ratio (zeta) for complex poles
      if (pole.im.abs() > 1e-6 && pole.im > 0) {
        final naturalFrequency = pole.wn; // rad/s
        final dampingRatio = pole.zeta;
        final multStr = mult > 1 ? ' (×$mult)' : '';
        final annotation =
            'wn=${naturalFrequency.toStringAsFixed(1)}$multStr\nz=${dampingRatio.toStringAsFixed(2)}';
        final annotStyle = TextStyle(
            color: color.withValues(alpha: 0.85), fontSize: 9);
        _drawLabel(canvas, annotation, Offset(px + 8, py - 18), annotStyle,
            TextAlign.left);
      } else if (pole.im.abs() <= 1e-6) {
        // Real pole: label the value + multiplicity
        final multStr = mult > 1 ? ' (×$mult)' : '';
        _drawLabel(
            canvas,
            '${pole.re.toStringAsFixed(1)}$multStr',
            Offset(px + 8, py - 12),
            TextStyle(color: color.withValues(alpha: 0.85), fontSize: 9),
            TextAlign.left);
      }
    }

    // ── Delay-adjusted poles ──────────────────────────────────────────
    final dpDrawn = <int>{};
    for (int i = 0; i < delayPoles.length; i++) {
      if (dpDrawn.contains(i)) continue;
      final dp = delayPoles[i];
      int mult = 1;
      for (int j = i + 1; j < delayPoles.length; j++) {
        if (!dpDrawn.contains(j) &&
            (dp.re - delayPoles[j].re).abs() < 1e-3 &&
            (dp.im - delayPoles[j].im).abs() < 1e-3) {
          mult++;
          dpDrawn.add(j);
        }
      }
      dpDrawn.add(i);

      final px = toX(dp.re);
      final py = toY(dp.im);
      final color =
          dp.isStable ? _delayPoleColor : _delayPoleUnstableColor;
      _drawXMarker(canvas, Offset(px, py), color, dashed: true);

      if (dp.im.abs() > 1e-6 && dp.im > 0) {
        final dampingRatio = dp.zeta;
        final multStr = mult > 1 ? ' (×$mult)' : '';
        final annotation = 'delay$multStr\nz=${dampingRatio.toStringAsFixed(2)}';
        final annotStyle = TextStyle(
            color: color.withValues(alpha: 0.85), fontSize: 9);
        _drawLabel(canvas, annotation, Offset(px + 8, py + 4), annotStyle,
            TextAlign.left);
      } else if (dp.im.abs() <= 1e-6) {
        final multStr = mult > 1 ? ' (×$mult)' : '';
        _drawLabel(
            canvas,
            'delay$multStr ${dp.re.toStringAsFixed(1)}',
            Offset(px + 8, py + 4),
            TextStyle(color: color.withValues(alpha: 0.85), fontSize: 9),
            TextAlign.left);
      }
    }

    canvas.restore();
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  void _drawXMarker(Canvas canvas, Offset center, Color color,
      {bool dashed = false}) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = dashed ? 2.0 : 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const r = 6.0;
    canvas.drawLine(center + const Offset(-r, -r), center + const Offset(r, r),
        paint);
    canvas.drawLine(center + const Offset(r, -r), center + const Offset(-r, r),
        paint);
    // Draw a small circle around dashed markers to distinguish them.
    if (dashed) {
      final ringPaint = Paint()
        ..color = color.withValues(alpha: 0.5)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;
      canvas.drawCircle(center, r + 3, ringPaint);
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset offset, TextStyle style,
      TextAlign align) {
    final span = TextSpan(text: text, style: style);
    final tp = TextPainter(
        text: span, textAlign: align, textDirection: TextDirection.ltr);
    tp.layout(maxWidth: 80);
    Offset pos = offset;
    if (align == TextAlign.center) {
      pos = offset - Offset(tp.width / 2, 0);
    } else if (align == TextAlign.right) {
      pos = offset - Offset(tp.width, 0);
    }
    tp.paint(canvas, pos);
  }

  /// Choose a nice round grid step for the given max value.
  double _niceStep(double maxAbs) {
    if (maxAbs <= 5) return 1;
    if (maxAbs <= 20) return 5;
    if (maxAbs <= 100) return 25;
    if (maxAbs <= 500) return 100;
    return (maxAbs / 4).roundToDouble();
  }

  // Uses shared _computeOpenLoopPolesFor() top-level function.

  /// Draw root locus: sweep an overall gain K and trace pole movement.
  void _drawRootLocus(
    Canvas canvas,
    Size size,
    double Function(double) toX,
    double Function(double) toY,
  ) {
    final kA = ff.kA;
    final kV = ff.kV;
    if (kA <= 0) return;

    const steps = 200;

    final locusPaint = Paint()
      ..color = _rootLocusColor.withValues(alpha: 0.6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final branch1 = <Offset>[];
    final branch2 = <Offset>[];
    final branch3 = <Offset>[];

    double gainMax;
    final hasIntegrator = (pid?.kI ?? 0.0).abs() > 1e-12;

    switch (mode) {
      case PoleZeroMode.velocity:
        // Sweep K in kA·s² + kV·s + K = 0 (2 branches from {0, -kV/kA})
        gainMax = (kV * kV / kA) * 2.0;
        if (gainMax < 1) gainMax = 100;
        for (int i = 0; i <= steps; i++) {
          final k = gainMax * i / steps;
          final roots = _solveQuadratic(kA, kV, k);
          if (roots.isNotEmpty) branch1.add(Offset(toX(roots[0].re), toY(roots[0].im)));
          if (roots.length > 1) branch2.add(Offset(toX(roots[1].re), toY(roots[1].im)));
        }

      case PoleZeroMode.position:
        if (hasIntegrator) {
          // PID: 3 OL poles {0, 0, -kV/kA}. Sweep K in kA·s³ + kV·s² + K = 0
          gainMax = kV * kV * kV / (kA * kA) * 0.5;
          if (gainMax < 1) gainMax = 100;
          for (int i = 0; i <= steps; i++) {
            final k = gainMax * i / steps;
            final roots = _solveCubic(kA, kV, 0, k);
            if (roots.isNotEmpty) branch1.add(Offset(toX(roots[0].re), toY(roots[0].im)));
            if (roots.length > 1) branch2.add(Offset(toX(roots[1].re), toY(roots[1].im)));
            if (roots.length > 2) branch3.add(Offset(toX(roots[2].re), toY(roots[2].im)));
          }
        } else {
          // PD: 2 OL poles {0, -kV/kA}. Sweep K in kA·s² + kV·s + K = 0
          gainMax = (kV * kV / kA) * 2.0;
          if (gainMax < 1) gainMax = 100;
          for (int i = 0; i <= steps; i++) {
            final k = gainMax * i / steps;
            final roots = _solveQuadratic(kA, kV, k);
            if (roots.isNotEmpty) branch1.add(Offset(toX(roots[0].re), toY(roots[0].im)));
            if (roots.length > 1) branch2.add(Offset(toX(roots[1].re), toY(roots[1].im)));
          }
        }
    }

    // Draw the locus paths
    for (final branch in [branch1, branch2, branch3]) {
      if (branch.length > 1) {
        final path = Path()..moveTo(branch.first.dx, branch.first.dy);
        for (int i = 1; i < branch.length; i++) {
          path.lineTo(branch[i].dx, branch[i].dy);
        }
        canvas.drawPath(path, locusPaint);
      }
    }
  }

  void _drawOMarker(Canvas canvas, Offset center, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, 6.0, paint);
  }

  @override
  bool shouldRepaint(_SPlanePainter old) =>
      old.poles != poles || old.delayPoles != delayPoles ||
      old.ff != ff || old.pid != pid || old.mode != mode ||
      old.realMin != realMin || old.realMax != realMax ||
      old.imagMin != imagMin || old.imagMax != imagMax;
}

// ──────────────────────────────────────────────────────────────────────
// Walkthrough steps
// ──────────────────────────────────────────────────────────────────────

List<WalkthroughStep> _poleZeroWalkthroughSteps(
    PoleZeroMode mode, List<_Complex> poles) {
  final steps = <WalkthroughStep>[
    const WalkthroughStep(
      title: 'What is the s-plane?',
      description:
          'The s-plane is a 2D map of complex numbers s = sigma + j*omega. '
          'The horizontal axis (Re) represents growth or decay rate. '
          'The vertical axis (Im) represents oscillation frequency.\n\n'
          'This map reveals how your closed-loop system behaves after you '
          'apply PID control.',
      icon: FluentIcons.chart_series,
    ),
    const WalkthroughStep(
      title: 'Left vs Right Half-Plane',
      description:
          'GREEN region (left half): poles here decay over time -- the system '
          'is STABLE. The further left, the faster it settles.\n\n'
          'RED region (right half): poles here grow over time -- the system '
          'is UNSTABLE and will oscillate uncontrollably.',
      icon: FluentIcons.warning,
    ),
    const WalkthroughStep(
      title: 'Open-Loop vs Closed-Loop Poles',
      description:
          'BLUE circles (O) = open-loop poles: where the plant\'s poles '
          'sit before any controller is applied.\n\n'
          'GREEN/RED crosses (X) = closed-loop poles: where the poles '
          'move to after applying your PID gains. The PID controller '
          'shifts the poles to control speed and stability.\n\n'
          'YELLOW/ORANGE ringed crosses = delay-adjusted poles: where '
          'the poles actually end up when transport delay (~10 ms from '
          'CAN bus, PWM, current loop) is included. These are what the '
          'real hardware experiences.',
      icon: FluentIcons.trending12,
    ),
    const WalkthroughStep(
      title: 'Root Locus (orange trace)',
      description:
          'The orange curve shows how the closed-loop poles MOVE as gain '
          'increases from 0 to infinity. It starts at the open-loop poles '
          'and traces a path.\n\n'
          'If the path crosses into the right half-plane, the system '
          'becomes unstable at that gain level. Your current poles (X) '
          'are one point on this curve.',
      icon: FluentIcons.chart_series,
    ),
    const WalkthroughStep(
      title: 'Damping Ratio Lines',
      description:
          'The diagonal guide lines show constant damping ratio (zeta):\n\n'
          'z=0.3: very oscillatory (lots of ringing)\n'
          'z=0.5: underdamped\n'
          'z=0.707: optimal (fast + minimal overshoot)\n'
          'z=0.9: well-damped (slightly slower)\n\n'
          'Poles on the real axis have z=1.0 (critically damped, no oscillation).',
      icon: FluentIcons.trending12,
    ),];

  if (poles.isNotEmpty) {
    final allStable = poles.every((p) => p.isStable);
    steps.add(WalkthroughStep(
      title: 'Your System\'s Poles',
      description: allStable
          ? 'All ${poles.length} pole(s) are in the left half-plane -- '
              'your closed-loop system is STABLE with the current PID gains.\n\n'
              'The distance from the imaginary axis controls settling speed.'
          : 'WARNING: One or more poles are in the right half-plane! '
              'Your system is UNSTABLE. Try reducing kP or kI.',
      icon: allStable ? FluentIcons.accept : FluentIcons.warning,
    ));

    // Natural frequency / damping annotation for complex poles
    final complexPoles = poles.where((p) => p.im.abs() > 1e-6).toList();
    if (complexPoles.isNotEmpty) {
      final p = complexPoles.first;
      steps.add(WalkthroughStep(
        title: 'Natural Frequency & Damping',
        description:
            'Your poles have natural frequency wn = '
            '${p.wn.toStringAsFixed(2)} rad/s and damping ratio '
            'zeta = ${p.zeta.toStringAsFixed(3)}.\n\n'
            'zeta < 1: underdamped (oscillatory), '
            'zeta = 1: critically damped, '
            'zeta > 1: overdamped (sluggish).\n\n'
            'Aim for zeta around 0.7 for a good balance.',
        icon: FluentIcons.chart_series,
      ));
    }
  }

  if (mode == PoleZeroMode.velocity) {
    steps.add(const WalkthroughStep(
      title: 'Velocity Loop Math',
      description:
          'Plant: G(s) = 1 / (kA*s + kV)\n'
          'Controller: C(s) = kP + kI/s\n'
          'Characteristic eq: kA*s^2 + (kV+kP)*s + kI = 0\n\n'
          'Increasing kP moves poles left (faster). '
          'Increasing kI adds a pole at origin (integrator).',
      icon: FluentIcons.trending12,
    ));
  } else {
    steps.add(const WalkthroughStep(
      title: 'Position Loop Math',
      description:
          'Plant: G(s) = 1 / (kA·s² + kV·s)\n'
          'Controller: C(s) = kP + kD·s + kI/s\n\n'
          'PD (kI=0): kA·s² + (kV+kD)·s + kP = 0 → 2 poles\n'
          'PID (kI≠0): kA·s³ + (kV+kD)·s² + kP·s + kI = 0 → 3 poles\n\n'
          'Increasing kD adds damping. '
          'Increasing kP increases natural frequency. '
          'Adding kI eliminates steady-state error but adds a 3rd pole.',
      icon: FluentIcons.trending12,
    ));
  }

  return steps;
}

// ──────────────────────────────────────────────────────────────────────
// Public API — used by the PDF report generator
// ──────────────────────────────────────────────────────────────────────

/// A closed-loop pole on the s-plane, exposed for external consumers
/// (e.g. the PDF report generator).
class PolePlotData {
  final double re;
  final double im;
  const PolePlotData(this.re, this.im);

  bool get isStable => re < 0;
  double get magnitude => math.sqrt(re * re + im * im);
  double get wn => magnitude;
  double get zeta => magnitude > 0 ? -re / magnitude : 0.0;

  @override
  String toString() {
    if (im == 0) return re.toStringAsFixed(3);
    final sign = im >= 0 ? '+' : '-';
    return '${re.toStringAsFixed(3)} $sign ${im.abs().toStringAsFixed(3)}j';
  }
}

/// Compute closed-loop poles for the given plant model and PID gains.
List<PolePlotData> computeClosedLoopPoles(
    FeedforwardGains ff, PidResult? pid, PoleZeroMode mode,
    [MechanismType? mechanismType]) {
  return _computePoles(ff, pid, mode, mechanismType)
      .map((c) => PolePlotData(c.re, c.im))
      .toList();
}

/// Compute open-loop poles (plant poles + controller integrators).
List<PolePlotData> computeOpenLoopPoles(
    FeedforwardGains ff, PidResult? pid, PoleZeroMode mode) {
  final kA = ff.kA;
  final kV = ff.kV;
  if (kA <= 0) return [];

  final hasIntegrator = (pid?.kI ?? 0.0).abs() > 1e-12;

  switch (mode) {
    case PoleZeroMode.velocity:
      if (hasIntegrator) {
        return [const PolePlotData(0, 0), PolePlotData(-kV / kA, 0)];
      }
      return [PolePlotData(-kV / kA, 0)];
    case PoleZeroMode.position:
      if (hasIntegrator) {
        return [
          const PolePlotData(0, 0),
          const PolePlotData(0, 0),
          PolePlotData(-kV / kA, 0),
        ];
      }
      return [const PolePlotData(0, 0), PolePlotData(-kV / kA, 0)];
  }
}
