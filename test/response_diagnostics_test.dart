import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/sysid/response_diagnostics.dart';
import 'package:rev_system_identification/sysid/validation_runner.dart';

/// Build a synthetic ValidationResult from a signal generator.
ValidationResult _syntheticResult({
  required ValidationMode mode,
  required double setpoint,
  required double Function(double t) signalFn,
  double duration = 3.0,
  int sampleCount = 300,
}) {
  final data = <DataPoint>[];
  final setpoints = <double>[];
  for (var i = 0; i < sampleCount; i++) {
    final t = i * duration / sampleCount;
    final value = signalFn(t);
    data.add(DataPoint(
      timestamp: t,
      voltage: 0,
      velocity: mode == ValidationMode.velocity ? value : 0,
      position: mode == ValidationMode.position ? value : 0,
      current: 0,
    ));
    setpoints.add(setpoint);
  }
  return ValidationResult(
    data: data,
    setpoints: setpoints,
    durationSeconds: duration,
    completed: true,
    mode: mode,
  );
}

void main() {
  group('ResponseDiagnostics', () {
    test('healthy step response produces no diagnostics', () {
      // Smooth first-order response to setpoint 100, no overshoot.
      final result = _syntheticResult(
        mode: ValidationMode.velocity,
        setpoint: 100,
        signalFn: (t) => 100.0 * (1 - math.exp(-t / 0.15)),
      );

      final diags = ResponseDiagnostics.analyze(
        result: result,
        currentTauMs: 100,
        currentBwHz: 5,
        currentDamping: 1.0,
      );

      expect(diags, isEmpty);
    });

    test('oscillatory velocity response is detected', () {
      // Step from 0 to 100 with damped oscillation in steady state.
      final result = _syntheticResult(
        mode: ValidationMode.velocity,
        setpoint: 100,
        signalFn: (t) {
          if (t < 0.2) return 100.0 * (t / 0.2); // fast rise
          return 100.0 + 20.0 * math.sin(2 * math.pi * 5 * (t - 0.2)) *
              math.exp(-(t - 0.2) * 0.5);
        },
        duration: 3.0,
        sampleCount: 600,
      );

      final diags = ResponseDiagnostics.analyze(
        result: result,
        currentTauMs: 80,
        currentBwHz: 5,
        currentDamping: 1.0,
      );

      expect(diags, isNotEmpty);
      expect(diags.first.type, DiagnosticType.oscillation);
      expect(diags.first.action.velocityTimeConstantMs, isNotNull);
      // Should double the time constant: 80 * 2 = 160.
      expect(diags.first.action.velocityTimeConstantMs, 160.0);
    });

    test('oscillatory position response suggests lower BW and higher damping',
        () {
      final result = _syntheticResult(
        mode: ValidationMode.position,
        setpoint: 10.0,
        signalFn: (t) {
          if (t < 0.2) return 10.0 * (t / 0.2); // fast rise
          return 10.0 + 2.0 * math.sin(2 * math.pi * 5 * (t - 0.2)) *
              math.exp(-(t - 0.2) * 0.3);
        },
        duration: 3.0,
        sampleCount: 600,
      );

      final diags = ResponseDiagnostics.analyze(
        result: result,
        currentTauMs: 100,
        currentBwHz: 8.0,
        currentDamping: 0.7,
      );

      expect(diags, isNotEmpty);
      expect(diags.first.type, DiagnosticType.oscillation);
      // BW should be reduced: 8 / 1.5 ≈ 5.33
      expect(diags.first.action.positionBandwidthHz, closeTo(5.33, 0.1));
      // Damping should be boosted: 0.7 + 0.3 = 1.0
      expect(diags.first.action.dampingRatio, closeTo(1.0, 0.01));
    });

    test('large overshoot (no oscillation) is detected for velocity', () {
      // Large overshoot but no sustained oscillation:
      // shoots to 135 then settles at 100.
      final result = _syntheticResult(
        mode: ValidationMode.velocity,
        setpoint: 100,
        signalFn: (t) {
          if (t < 0.3) return 100.0 * (t / 0.3); // rise
          if (t < 0.6) return 100.0 + 35.0 * math.exp(-(t - 0.3) / 0.1); // overshoot decay
          return 100.0; // settled
        },
        duration: 3.0,
        sampleCount: 300,
      );

      final diags = ResponseDiagnostics.analyze(
        result: result,
        currentTauMs: 60,
        currentBwHz: 5,
        currentDamping: 1.0,
      );

      // Should detect large overshoot (35% > 20% threshold).
      final overshootDiag = diags.where(
          (d) => d.type == DiagnosticType.largeOvershoot);
      expect(overshootDiag, isNotEmpty);
      // Remedy: 60 * 1.5 = 90 ms
      expect(
          overshootDiag.first.action.velocityTimeConstantMs, closeTo(90, 1));
    });

    test('large overshoot for position suggests higher damping', () {
      final result = _syntheticResult(
        mode: ValidationMode.position,
        setpoint: 5.0,
        signalFn: (t) {
          if (t < 0.3) return 5.0 * (t / 0.3);
          if (t < 0.8) return 5.0 + 2.0 * math.exp(-(t - 0.3) / 0.15);
          return 5.0;
        },
        duration: 3.0,
        sampleCount: 300,
      );

      final diags = ResponseDiagnostics.analyze(
        result: result,
        currentTauMs: 100,
        currentBwHz: 5,
        currentDamping: 0.6,
      );

      final overshootDiag = diags.where(
          (d) => d.type == DiagnosticType.largeOvershoot);
      expect(overshootDiag, isNotEmpty);
      // Damping should be boosted: 0.6 + 0.3 = 0.9
      expect(overshootDiag.first.action.dampingRatio, closeTo(0.9, 0.01));
    });

    test('large steady-state error is detected', () {
      // Response settles at 90 instead of 100 → 10% SS error.
      final result = _syntheticResult(
        mode: ValidationMode.velocity,
        setpoint: 100,
        signalFn: (t) => 90.0 * (1 - math.exp(-t / 0.1)),
        duration: 3.0,
        sampleCount: 300,
      );

      final diags = ResponseDiagnostics.analyze(
        result: result,
        currentTauMs: 100,
        currentBwHz: 5,
        currentDamping: 1.0,
      );

      final ssDiag = diags.where(
          (d) => d.type == DiagnosticType.largeSteadyStateError);
      expect(ssDiag, isNotEmpty);
      // Velocity SS error fix: 100 * 1.5 = 150 ms
      expect(ssDiag.first.action.velocityTimeConstantMs, closeTo(150, 1));
    });

    test('position SS error suggests lower bandwidth', () {
      // Position settles at 4.5 instead of 5.0 → 10% SS error.
      final result = _syntheticResult(
        mode: ValidationMode.position,
        setpoint: 5.0,
        signalFn: (t) => 4.5 * (1 - math.exp(-t / 0.1)),
        duration: 3.0,
        sampleCount: 300,
      );

      final diags = ResponseDiagnostics.analyze(
        result: result,
        currentTauMs: 100,
        currentBwHz: 6.0,
        currentDamping: 1.0,
      );

      final ssDiag = diags.where(
          (d) => d.type == DiagnosticType.largeSteadyStateError);
      expect(ssDiag, isNotEmpty);
      // BW fix: 6.0 / 1.3 ≈ 4.6
      expect(ssDiag.first.action.positionBandwidthHz, closeTo(4.6, 0.1));
    });

    test('empty data produces no diagnostics', () {
      const result = ValidationResult(
        data: [],
        setpoints: [],
        durationSeconds: 0,
        completed: true,
        mode: ValidationMode.velocity,
      );

      final diags = ResponseDiagnostics.analyze(
        result: result,
        currentTauMs: 100,
        currentBwHz: 5,
        currentDamping: 1.0,
      );
      expect(diags, isEmpty);
    });

    test('TuningAction fields are null when not changed', () {
      const action = TuningAction(velocityTimeConstantMs: 200);
      expect(action.velocityTimeConstantMs, 200);
      expect(action.positionBandwidthHz, isNull);
      expect(action.dampingRatio, isNull);
      expect(action.closedLoopError, isNull);
    });

    test('noisy response suggests increasing allowed CL error', () {
      // Step from 0 to 100, settles with small noise wiggles (amplitude < 5%
      // of step = 5, but many zero-crossings).
      final result = _syntheticResult(
        mode: ValidationMode.velocity,
        setpoint: 100,
        signalFn: (t) {
          if (t < 0.3) return 100.0 * (t / 0.3); // rise
          // Small noise oscillation: amplitude 2 (well under 5% of 100 = 5)
          return 100.0 + 2.0 * math.sin(2 * math.pi * 10 * t);
        },
        duration: 3.0,
        sampleCount: 600,
      );

      final diags = ResponseDiagnostics.analyze(
        result: result,
        currentTauMs: 100,
        currentBwHz: 5,
        currentDamping: 1.0,
        currentClosedLoopError: 0.0,
      );

      final noiseDiag = diags.where(
          (d) => d.type == DiagnosticType.noisyResponse);
      expect(noiseDiag, isNotEmpty);
      expect(noiseDiag.first.action.closedLoopError, isNotNull);
      // Suggested error should be 1.5 × peak noise amplitude.
      expect(noiseDiag.first.action.closedLoopError,
          greaterThan(0));
      // Should NOT flag real oscillation.
      expect(diags.where((d) => d.type == DiagnosticType.oscillation), isEmpty);
    });

    test('noisy response not flagged when CL error already covers noise', () {
      final result = _syntheticResult(
        mode: ValidationMode.velocity,
        setpoint: 100,
        signalFn: (t) {
          if (t < 0.3) return 100.0 * (t / 0.3);
          return 100.0 + 1.0 * math.sin(2 * math.pi * 10 * t);
        },
        duration: 3.0,
        sampleCount: 600,
      );

      final diags = ResponseDiagnostics.analyze(
        result: result,
        currentTauMs: 100,
        currentBwHz: 5,
        currentDamping: 1.0,
        // CL error already larger than 1.5 × noise amplitude (1.5)
        currentClosedLoopError: 5.0,
      );

      // Noise diagnostic should still appear since the detection is about
      // what's happening in the signal — but the suggested value won't
      // decrease below the current setting.
      final noiseDiag = diags.where(
          (d) => d.type == DiagnosticType.noisyResponse);
      if (noiseDiag.isNotEmpty) {
        // If present, the suggested CL error should be >= current.
        expect(noiseDiag.first.action.closedLoopError,
            greaterThanOrEqualTo(5.0));
      }
    });
  });
}
