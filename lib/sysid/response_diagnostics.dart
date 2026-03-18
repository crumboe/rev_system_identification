/// Response diagnostics: detect oscillation, excessive overshoot, and
/// large steady-state error from validation test data, and suggest
/// concrete tuning adjustments.
library;

import 'dart:math' as math;

import '../data/test_data.dart';
import 'validation_runner.dart';

// ---------------------------------------------------------------------------
// Diagnostic issue types
// ---------------------------------------------------------------------------

/// Category of a detected response issue.
enum DiagnosticType {
  oscillation,
  largeOvershoot,
  largeSteadyStateError,
  noisyResponse,
}

/// A single diagnosed issue with a human-readable description and a
/// concrete remediation that the UI can apply with one button press.
class ResponseDiagnostic {
  final DiagnosticType type;

  /// Short title shown on the fix-it button (e.g. "Fix Oscillation").
  final String title;

  /// Longer explanation shown in the InfoBar.
  final String description;

  /// What the fix-it button will do (e.g. "Increase velocity time constant
  /// from 100 ms to 200 ms and retune").
  final String remedy;

  /// The concrete tuning action to apply.
  final TuningAction action;

  const ResponseDiagnostic({
    required this.type,
    required this.title,
    required this.description,
    required this.remedy,
    required this.action,
  });
}

/// A concrete tuning parameter change.
class TuningAction {
  /// New velocity time constant (ms), or null if unchanged.
  final double? velocityTimeConstantMs;

  /// New position bandwidth (Hz), or null if unchanged.
  final double? positionBandwidthHz;

  /// New damping ratio, or null if unchanged.
  final double? dampingRatio;

  /// New allowed closed-loop error, or null if unchanged.
  final double? closedLoopError;

  const TuningAction({
    this.velocityTimeConstantMs,
    this.positionBandwidthHz,
    this.dampingRatio,
    this.closedLoopError,
  });
}

// ---------------------------------------------------------------------------
// Diagnostics engine
// ---------------------------------------------------------------------------

class ResponseDiagnostics {
  /// Oscillation detection thresholds.
  static const _minZeroCrossings = 4; // need at least 4 crossings to call it oscillatory
  static const _oscillationAmplitudeRatio = 0.05; // 5% of step amplitude

  /// Overshoot threshold (%).
  static const _overshootThreshold = 20.0;

  /// Steady-state error threshold (fraction of step amplitude).
  static const _ssErrorFractionThreshold = 0.05; // 5% of step size

  /// How much to multiply the time constant by when fixing velocity oscillation.
  static const _velocityTauMultiplier = 2.0;

  /// How much to divide bandwidth by when fixing position oscillation.
  static const _positionBwDivisor = 1.5;

  /// Damping ratio boost when fixing overshoot.
  static const _dampingBoost = 0.3;

  /// Minimum small-amplitude zero-crossings to flag noise chatter.
  static const _minNoiseCrossings = 4;

  /// Analyze the validation result and return a list of diagnosed issues
  /// (may be empty if the response looks healthy).
  ///
  /// [currentTauMs] / [currentBwHz] / [currentDamping] are the tuning
  /// parameters that produced this response — used to compute the remedy.
  /// [currentClosedLoopError] is the current allowed CL error (deadband).
  static List<ResponseDiagnostic> analyze({
    required ValidationResult result,
    required double currentTauMs,
    required double currentBwHz,
    required double currentDamping,
    double currentClosedLoopError = 0.0,
  }) {
    if (result.data.isEmpty || result.setpoints.isEmpty) return [];

    final diagnostics = <ResponseDiagnostic>[];
    final isVelocity = result.mode == ValidationMode.velocity;

    // Compute step parameters.
    final target = result.setpoints.first != 0
        ? result.setpoints.first
        : result.setpoints.last;
    final initial = isVelocity
        ? result.data.first.velocity
        : result.data.first.position;
    final stepAmplitude = target - initial;
    if (stepAmplitude.abs() < 1e-9) return [];

    // 1. Oscillation / noise detection
    final detection = _detectOscillation(result, isVelocity, target, stepAmplitude);
    final oscillation = detection?.significant;
    final noiseInfo = detection?.noise;

    // 1a. Noisy response — many small crossings suggest increasing CL error.
    if (noiseInfo != null && noiseInfo.crossings >= _minNoiseCrossings && oscillation == null) {
      final suggestedError = math.max(
        currentClosedLoopError,
        noiseInfo.amplitude * 1.5,
      );
      diagnostics.add(ResponseDiagnostic(
        type: DiagnosticType.noisyResponse,
        title: 'Increase Deadband',
        description: 'Small noise chatter detected '
            '(${noiseInfo.crossings} low-amplitude zero-crossings, '
            'peak ${noiseInfo.amplitude.toStringAsFixed(3)}). '
            'Increase the allowed closed-loop error to filter it out.',
        remedy: 'Set allowed CL error from '
            '${currentClosedLoopError.toStringAsFixed(3)} to '
            '${suggestedError.toStringAsFixed(3)}.',
        action: TuningAction(closedLoopError: suggestedError),
      ));
    }

    // 1b. Real oscillation — large-amplitude swings.
    if (oscillation != null) {
      if (isVelocity) {
        final newTau = (currentTauMs * _velocityTauMultiplier)
            .clamp(20.0, 500.0);
        diagnostics.add(ResponseDiagnostic(
          type: DiagnosticType.oscillation,
          title: 'Fix Oscillation',
          description: 'Oscillatory response detected '
              '(${oscillation.crossings} zero-crossings around setpoint). '
              'The velocity time constant is too aggressive.',
          remedy: 'Increase velocity time constant from '
              '${currentTauMs.toStringAsFixed(0)} ms to '
              '${newTau.toStringAsFixed(0)} ms and retune.',
          action: TuningAction(velocityTimeConstantMs: newTau),
        ));
      } else {
        final newBw = (currentBwHz / _positionBwDivisor).clamp(1.0, 20.0);
        final newDamping = (currentDamping + _dampingBoost).clamp(0.3, 2.0);
        diagnostics.add(ResponseDiagnostic(
          type: DiagnosticType.oscillation,
          title: 'Fix Oscillation',
          description: 'Oscillatory response detected '
              '(${oscillation.crossings} zero-crossings around setpoint). '
              'Position bandwidth is too high or damping too low.',
          remedy: 'Reduce bandwidth from '
              '${currentBwHz.toStringAsFixed(1)} Hz to '
              '${newBw.toStringAsFixed(1)} Hz, increase damping from '
              '${currentDamping.toStringAsFixed(2)} to '
              '${newDamping.toStringAsFixed(2)}, and retune.',
          action: TuningAction(
            positionBandwidthHz: newBw,
            dampingRatio: newDamping,
          ),
        ));
      }
    }

    // 2. Large overshoot (only if not already flagged as oscillation —
    //    oscillation fix addresses overshoot too)
    final overshoot = result.overshootPercent;
    if (overshoot != null &&
        overshoot > _overshootThreshold &&
        oscillation == null) {
      if (isVelocity) {
        final newTau = (currentTauMs * 1.5).clamp(20.0, 500.0);
        diagnostics.add(ResponseDiagnostic(
          type: DiagnosticType.largeOvershoot,
          title: 'Reduce Overshoot',
          description: 'Overshoot is ${overshoot.toStringAsFixed(1)}% '
              '(threshold: ${_overshootThreshold.toStringAsFixed(0)}%). '
              'The velocity response is too aggressive.',
          remedy: 'Increase velocity time constant from '
              '${currentTauMs.toStringAsFixed(0)} ms to '
              '${newTau.toStringAsFixed(0)} ms and retune.',
          action: TuningAction(velocityTimeConstantMs: newTau),
        ));
      } else {
        final newDamping = (currentDamping + _dampingBoost).clamp(0.3, 2.0);
        diagnostics.add(ResponseDiagnostic(
          type: DiagnosticType.largeOvershoot,
          title: 'Reduce Overshoot',
          description: 'Overshoot is ${overshoot.toStringAsFixed(1)}% '
              '(threshold: ${_overshootThreshold.toStringAsFixed(0)}%). '
              'Position damping ratio is too low.',
          remedy: 'Increase damping ratio from '
              '${currentDamping.toStringAsFixed(2)} to '
              '${newDamping.toStringAsFixed(2)} and retune.',
          action: TuningAction(dampingRatio: newDamping),
        ));
      }
    }

    // 3. Large steady-state error
    final ssError = result.steadyStateError;
    if (ssError != null && ssError > stepAmplitude.abs() * _ssErrorFractionThreshold) {
      final errorPercent = (ssError / stepAmplitude.abs()) * 100.0;
      diagnostics.add(ResponseDiagnostic(
        type: DiagnosticType.largeSteadyStateError,
        title: 'Fix Steady-State Error',
        description: 'Steady-state error is '
            '${ssError.toStringAsFixed(3)} '
            '(${errorPercent.toStringAsFixed(1)}% of step). '
            'Feedforward gains may be inaccurate or integral action is needed.',
        remedy: isVelocity
            ? 'Increase velocity time constant from '
                '${currentTauMs.toStringAsFixed(0)} ms to '
                '${(currentTauMs * 1.5).clamp(20.0, 500.0).toStringAsFixed(0)} ms '
                '(slower loop allows better tracking) and retune.'
            : 'Reduce position bandwidth from '
                '${currentBwHz.toStringAsFixed(1)} Hz to '
                '${(currentBwHz / 1.3).clamp(1.0, 20.0).toStringAsFixed(1)} Hz '
                'and retune.',
        action: isVelocity
            ? TuningAction(
                velocityTimeConstantMs:
                    (currentTauMs * 1.5).clamp(20.0, 500.0))
            : TuningAction(
                positionBandwidthHz:
                    (currentBwHz / 1.3).clamp(1.0, 20.0)),
      ));
    }

    return diagnostics;
  }

  /// Detect oscillation by counting zero-crossings of the error signal
  /// after the initial rise time.
  static _OscillationDetection? _detectOscillation(
    ValidationResult result,
    bool isVelocity,
    double target,
    double stepAmplitude,
  ) {
    final data = result.data;
    final n = data.length;
    if (n < 20) return null;

    // Skip the initial transient (first 30% of data = rise phase).
    final startIdx = (n * 0.3).toInt();

    final ampThreshold = stepAmplitude.abs() * _oscillationAmplitudeRatio;

    // Track both large-amplitude (real oscillation) and small-amplitude
    // (noise chatter) crossings separately.
    int significantCrossings = 0;
    int noiseCrossings = 0;
    double maxAmplitude = 0;
    double maxNoiseAmplitude = 0;
    double prevError = 0;
    double peakSinceLast = 0;

    for (var i = startIdx; i < n; i++) {
      final measured = isVelocity ? data[i].velocity : data[i].position;
      final setpoint = i < result.setpoints.length
          ? result.setpoints[i]
          : target;
      final error = measured - setpoint;

      final absError = error.abs();
      if (absError > peakSinceLast) peakSinceLast = absError;

      if (i > startIdx && prevError * error < 0) {
        if (peakSinceLast > ampThreshold) {
          significantCrossings++;
          if (absError > maxAmplitude) maxAmplitude = peakSinceLast;
        } else {
          noiseCrossings++;
          if (peakSinceLast > maxNoiseAmplitude) {
            maxNoiseAmplitude = peakSinceLast;
          }
        }
        peakSinceLast = 0;
      }

      prevError = error;
    }

    final significant = significantCrossings >= _minZeroCrossings
        ? _OscillationInfo(crossings: significantCrossings, amplitude: maxAmplitude)
        : null;
    final noise = noiseCrossings >= _minNoiseCrossings
        ? _OscillationInfo(crossings: noiseCrossings, amplitude: maxNoiseAmplitude)
        : null;

    if (significant == null && noise == null) return null;
    return _OscillationDetection(significant: significant, noise: noise);
  }
}

class _OscillationDetection {
  /// Large-amplitude oscillation (real instability), or null.
  final _OscillationInfo? significant;
  /// Small-amplitude noise chatter, or null.
  final _OscillationInfo? noise;
  const _OscillationDetection({this.significant, this.noise});
}

class _OscillationInfo {
  final int crossings;
  final double amplitude;
  const _OscillationInfo({required this.crossings, required this.amplitude});
}
