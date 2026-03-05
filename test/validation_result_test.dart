/// Unit tests for ValidationResult metric getters (riseTime, steadyStateError,
/// overshootPercent).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/mechanisms/mechanism.dart';
import 'package:rev_system_identification/sysid/validation_runner.dart';

void main() {
  // =========================================================================
  // Helper: generate a step response
  // =========================================================================

  /// Generate a simple first-order step response for testing metrics.
  /// Returns data & setpoints for a velocity step test.
  ({List<DataPoint> data, List<double> setpoints}) _generateStepResponse({
    double setpoint = 100.0,
    double timeConstant = 0.5,
    double duration = 5.0,
    double dt = 0.01,
    double overshootFraction = 0.0,
  }) {
    final data = <DataPoint>[];
    final setpoints = <double>[];

    for (var t = 0.0; t < duration; t += dt) {
      final normalised = 1.0 - _exp(-t / timeConstant);
      var velocity = setpoint * normalised;

      // Add overshoot as a decaying sine
      if (overshootFraction > 0 && t > timeConstant) {
        velocity += setpoint * overshootFraction *
            _exp(-(t - timeConstant) / timeConstant) *
            _sin(2 * 3.14159 * (t - timeConstant) / timeConstant);
      }

      data.add(DataPoint(
        timestamp: t,
        voltage: 6.0,
        velocity: velocity,
        position: 0,
        current: 1.0,
      ));
      setpoints.add(setpoint);
    }

    return (data: data, setpoints: setpoints);
  }

  // =========================================================================
  // riseTime
  // =========================================================================

  group('ValidationResult.riseTime', () {
    test('computes rise time for a first-order response', () {
      final resp = _generateStepResponse(
          setpoint: 100.0, timeConstant: 0.5);
      final result = ValidationResult(
        data: resp.data,
        setpoints: resp.setpoints,
        durationSeconds: 5.0,
        completed: true,
        mode: ValidationMode.velocity,
      );

      final rt = result.riseTime;
      expect(rt, isNotNull);
      // For a first-order system with tau=0.5:
      //   10% at t = -tau*ln(0.9) ≈ 0.053s
      //   90% at t = -tau*ln(0.1) ≈ 1.152s
      //   rise time ≈ 1.099s
      expect(rt!, closeTo(1.1, 0.2));
    });

    test('returns null for empty data', () {
      final result = ValidationResult(
        data: [],
        setpoints: [],
        durationSeconds: 0,
        completed: true,
        mode: ValidationMode.velocity,
      );
      expect(result.riseTime, isNull);
    });

    test('returns null for zero setpoint', () {
      final data = [
        const DataPoint(
            timestamp: 0, voltage: 0, velocity: 0, position: 0, current: 0),
      ];
      final result = ValidationResult(
        data: data,
        setpoints: [0.0],
        durationSeconds: 0.01,
        completed: true,
        mode: ValidationMode.velocity,
      );
      expect(result.riseTime, isNull);
    });
  });

  // =========================================================================
  // steadyStateError
  // =========================================================================

  group('ValidationResult.steadyStateError', () {
    test('is near zero for a well-converged response', () {
      final resp = _generateStepResponse(
          setpoint: 100.0, timeConstant: 0.2, duration: 10.0);
      final result = ValidationResult(
        data: resp.data,
        setpoints: resp.setpoints,
        durationSeconds: 10.0,
        completed: true,
        mode: ValidationMode.velocity,
      );

      final sse = result.steadyStateError;
      expect(sse, isNotNull);
      expect(sse!, lessThan(2.0)); // < 2% of setpoint
    });

    test('is larger for slow convergence within test window', () {
      // Very slow time constant so it hasn't converged
      final resp = _generateStepResponse(
          setpoint: 100.0, timeConstant: 10.0, duration: 5.0);
      final result = ValidationResult(
        data: resp.data,
        setpoints: resp.setpoints,
        durationSeconds: 5.0,
        completed: true,
        mode: ValidationMode.velocity,
      );

      final sse = result.steadyStateError;
      expect(sse, isNotNull);
      expect(sse!, greaterThan(10.0));
    });

    test('returns null for empty data', () {
      final result = ValidationResult(
        data: [],
        setpoints: [],
        durationSeconds: 0,
        completed: true,
        mode: ValidationMode.velocity,
      );
      expect(result.steadyStateError, isNull);
    });
  });

  // =========================================================================
  // overshootPercent
  // =========================================================================

  group('ValidationResult.overshootPercent', () {
    test('returns 0 for no overshoot', () {
      // First-order with no overshoot
      final resp = _generateStepResponse(
          setpoint: 100.0, timeConstant: 0.5, overshootFraction: 0.0);
      final result = ValidationResult(
        data: resp.data,
        setpoints: resp.setpoints,
        durationSeconds: 5.0,
        completed: true,
        mode: ValidationMode.velocity,
      );

      expect(result.overshootPercent, closeTo(0.0, 1.0));
    });

    test('returns null for zero setpoint', () {
      final result = ValidationResult(
        data: [
          const DataPoint(
              timestamp: 0,
              voltage: 0,
              velocity: 0,
              position: 0,
              current: 0),
        ],
        setpoints: [0.0],
        durationSeconds: 0.01,
        completed: true,
        mode: ValidationMode.velocity,
      );
      expect(result.overshootPercent, isNull);
    });

    test('returns null for empty data', () {
      final result = ValidationResult(
        data: [],
        setpoints: [],
        durationSeconds: 0,
        completed: true,
        mode: ValidationMode.velocity,
      );
      expect(result.overshootPercent, isNull);
    });
  });

  // =========================================================================
  // ValidationParams
  // =========================================================================

  group('ValidationParams', () {
    test('defaults are sensible', () {
      const params = ValidationParams();
      expect(params.velocitySetpoint, equals(1000.0));
      expect(params.positionSetpoint, equals(0.5));
      expect(params.holdDuration, equals(3.0));
    });

    test('forMechanism returns different defaults per type', () {
      final flywheel =
          ValidationParams.forMechanism(MechanismType.flywheel);
      final arm = ValidationParams.forMechanism(MechanismType.arm);

      expect(flywheel.velocitySetpoint, equals(1000.0));
      expect(arm.velocitySetpoint, equals(90.0));
    });

    test('copyWith preserves unmodified fields', () {
      const params = ValidationParams(
        velocitySetpoint: 500.0,
        holdDuration: 5.0,
      );
      final copy = params.copyWith(velocitySetpoint: 600.0);
      expect(copy.holdDuration, equals(5.0));
      expect(copy.velocitySetpoint, equals(600.0));
    });
  });

  // =========================================================================
  // MAXMotionConfig
  // =========================================================================

  group('MAXMotionConfig', () {
    test('default jerk and allowed error', () {
      const config = MAXMotionConfig(
        cruiseVelocity: 600,
        maxAcceleration: 1200,
      );
      expect(config.maxJerk, equals(0.0));
      expect(config.allowedError, equals(0.0));
      expect(config.positionMode, equals(0));
    });

    test('copyWith modifies specified fields', () {
      const config = MAXMotionConfig(
        cruiseVelocity: 600,
        maxAcceleration: 1200,
      );
      final copy = config.copyWith(maxJerk: 500.0, positionMode: 1);
      expect(copy.cruiseVelocity, equals(600));
      expect(copy.maxJerk, equals(500.0));
      expect(copy.positionMode, equals(1));
    });
  });

  // =========================================================================
  // ValidationProgress
  // =========================================================================

  group('ValidationProgress', () {
    test('all fields are accessible', () {
      const vp = ValidationProgress(
        elapsedSeconds: 1.5,
        setpoint: 100,
        measured: 95,
        velocity: 95,
        position: 2.5,
        voltage: 6.0,
        current: 3.0,
        sampleCount: 150,
        message: 'test',
      );
      expect(vp.elapsedSeconds, equals(1.5));
      expect(vp.setpoint, equals(100));
      expect(vp.measured, equals(95));
      expect(vp.velocity, equals(95));
      expect(vp.position, equals(2.5));
      expect(vp.sampleCount, equals(150));
      expect(vp.message, equals('test'));
    });
  });
}

// ---------------------------------------------------------------------------
// Math helpers (avoid dart:math import in tests where not needed)
// ---------------------------------------------------------------------------

double _exp(double x) {
  // Taylor series approximation (sufficient for test values)
  if (x.abs() > 10) return x > 0 ? 22026.0 : 0.0;
  double sum = 1.0;
  double term = 1.0;
  for (var i = 1; i <= 20; i++) {
    term *= x / i;
    sum += term;
  }
  return sum;
}

double _sin(double x) {
  const pi = 3.14159265358979;
  x = x % (2 * pi);
  if (x > pi) x -= 2 * pi;
  if (x < -pi) x += 2 * pi;
  final x2 = x * x;
  return x - x * x2 / 6 + x * x2 * x2 / 120 - x * x2 * x2 * x2 / 5040;
}
