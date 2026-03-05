/// Unit tests for the Plant Model Visualizer simulation logic.
///
/// Tests the [runStepResponse] function which drives the existing physics
/// engines with custom feedforward constants and returns chart-ready data.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/mechanisms/mechanism.dart';
import 'package:rev_system_identification/ui/screens/plant_visualizer_screen.dart';

void main() {
  // =========================================================================
  // runStepResponse — basic properties
  // =========================================================================

  group('runStepResponse basic properties', () {
    test('returns non-empty samples for valid flywheel input', () {
      final samples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: 0.14,
        kV: 0.0185,
        kA: 0.003,
        kG: 0.0,
        stepVoltage: 6.0,
        durationS: 2.0,
      );
      expect(samples, isNotEmpty);
      expect(samples.first.time, closeTo(0.0, 0.01));
    });

    test('sample count matches duration / output interval', () {
      final samples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: 0.14,
        kV: 0.0185,
        kA: 0.003,
        kG: 0.0,
        stepVoltage: 6.0,
        durationS: 1.0,
        simDtS: 0.001,
        outputDtS: 0.01,
      );
      // 1.0 / 0.001 = 1000 steps, output every 10 → ~100 samples + 1
      expect(samples.length, greaterThanOrEqualTo(100));
      expect(samples.length, lessThanOrEqualTo(110));
    });

    test('last sample time is close to requested duration', () {
      const dur = 3.0;
      final samples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: 0.14,
        kV: 0.0185,
        kA: 0.003,
        kG: 0.0,
        stepVoltage: 6.0,
        durationS: dur,
      );
      expect(samples.last.time, closeTo(dur, 0.05));
    });

    test('returns empty list when kA <= 0', () {
      final samples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: 0.14,
        kV: 0.0185,
        kA: 0.0,
        kG: 0.0,
        stepVoltage: 6.0,
        durationS: 1.0,
      );
      expect(samples, isEmpty);
    });

    test('returns empty list when kV <= 0', () {
      final samples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: 0.14,
        kV: 0.0,
        kA: 0.003,
        kG: 0.0,
        stepVoltage: 6.0,
        durationS: 1.0,
      );
      expect(samples, isEmpty);
    });

    test('returns empty list when duration <= 0', () {
      final samples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: 0.14,
        kV: 0.0185,
        kA: 0.003,
        kG: 0.0,
        stepVoltage: 6.0,
        durationS: 0.0,
      );
      expect(samples, isEmpty);
    });
  });

  // =========================================================================
  // runStepResponse — flywheel steady-state
  // =========================================================================

  group('Flywheel step response physics', () {
    test('velocity reaches expected steady state', () {
      const kS = 0.14;
      const kV = 0.0185;
      const kA = 0.003;
      const stepV = 6.0;
      // Expected: ω_ss = (V - kS) / kV
      final expectedSS = (stepV - kS) / kV;

      final samples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: kS,
        kV: kV,
        kA: kA,
        kG: 0.0,
        stepVoltage: stepV,
        durationS: 3.0,
      );

      final lastVelocity = samples.last.velocity;
      expect(lastVelocity, closeTo(expectedSS, expectedSS * 0.05));
    });

    test('velocity starts at zero', () {
      final samples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: 0.14,
        kV: 0.0185,
        kA: 0.003,
        kG: 0.0,
        stepVoltage: 6.0,
        durationS: 1.0,
      );
      expect(samples.first.velocity, equals(0.0));
    });

    test('position monotonically increases for positive step', () {
      final samples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: 0.14,
        kV: 0.0185,
        kA: 0.003,
        kG: 0.0,
        stepVoltage: 6.0,
        durationS: 2.0,
      );
      // Skip first few samples while motor overcomes friction.
      for (var i = 10; i < samples.length - 1; i++) {
        expect(samples[i + 1].position,
            greaterThanOrEqualTo(samples[i].position));
      }
    });

    test('zero velocity when step voltage < kS (below deadband)', () {
      final samples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: 0.50,
        kV: 0.0185,
        kA: 0.003,
        kG: 0.0,
        stepVoltage: 0.3, // below kS
        durationS: 1.0,
      );
      for (final s in samples) {
        expect(s.velocity, equals(0.0));
      }
    });

    test('negative step produces negative velocity', () {
      final samples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: 0.14,
        kV: 0.0185,
        kA: 0.003,
        kG: 0.0,
        stepVoltage: -6.0,
        durationS: 2.0,
      );
      final lastV = samples.last.velocity;
      expect(lastV, lessThan(-100));
    });
  });

  // =========================================================================
  // runStepResponse — arm (gravity)
  // =========================================================================

  group('Arm step response physics', () {
    test('arm velocity becomes positive during step response', () {
      const kS = 0.20;
      const kV = 0.018;
      const kA = 0.002;
      const kG = 0.80;
      const stepV = 6.0;

      final armSamples = runStepResponse(
        mechanism: MechanismType.arm,
        kS: kS,
        kV: kV,
        kA: kA,
        kG: kG,
        stepVoltage: stepV,
        durationS: 0.5, // short duration to avoid hitting angle limits
      );

      // Find peak velocity during the run (before hitting hard stop).
      final peakV = armSamples
          .map((s) => s.velocity)
          .reduce((a, b) => a > b ? a : b);
      expect(peakV, greaterThan(0));
    });

    test('returns valid data for arm mechanism', () {
      final samples = runStepResponse(
        mechanism: MechanismType.arm,
        kS: 0.20,
        kV: 0.018,
        kA: 0.002,
        kG: 0.80,
        stepVoltage: 6.0,
        durationS: 1.0,
      );
      expect(samples, isNotEmpty);
      expect(samples.first.velocity, equals(0.0));
    });
  });

  // =========================================================================
  // runStepResponse — elevator (constant gravity)
  // =========================================================================

  group('Elevator step response physics', () {
    test('elevator velocity becomes positive during step response', () {
      const kS = 0.18;
      const kV = 0.12;
      const kA = 0.015;
      const kG = 0.55;
      const stepV = 6.0;

      final samples = runStepResponse(
        mechanism: MechanismType.elevator,
        kS: kS,
        kV: kV,
        kA: kA,
        kG: kG,
        stepVoltage: stepV,
        durationS: 0.5, // short duration to avoid hitting position limits
      );
      // Find peak velocity during the run.
      final peakV = samples
          .map((s) => s.velocity)
          .reduce((a, b) => a > b ? a : b);
      expect(peakV, greaterThan(0));
    });

    test('returns valid data for elevator mechanism', () {
      final samples = runStepResponse(
        mechanism: MechanismType.elevator,
        kS: 0.18,
        kV: 0.12,
        kA: 0.015,
        kG: 0.55,
        stepVoltage: 6.0,
        durationS: 1.0,
      );
      expect(samples, isNotEmpty);
      expect(samples.first.velocity, equals(0.0));
    });
  });

  // =========================================================================
  // Mechanism switching produces different defaults
  // =========================================================================

  group('Mechanism type produces different responses', () {
    test('flywheel and arm produce different steady-state velocities', () {
      final fwSamples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: 0.14,
        kV: 0.0185,
        kA: 0.003,
        kG: 0.0,
        stepVoltage: 6.0,
        durationS: 2.0,
      );
      final armSamples = runStepResponse(
        mechanism: MechanismType.arm,
        kS: 0.20,
        kV: 0.018,
        kA: 0.002,
        kG: 0.80,
        stepVoltage: 6.0,
        durationS: 2.0,
      );

      // The flywheel (no gravity) reaches a higher RPM.
      expect(fwSamples.last.velocity, isNot(equals(armSamples.last.velocity)));
    });

    test('voltage column equals step voltage for all samples', () {
      const stepV = 8.0;
      final samples = runStepResponse(
        mechanism: MechanismType.flywheel,
        kS: 0.14,
        kV: 0.0185,
        kA: 0.003,
        kG: 0.0,
        stepVoltage: stepV,
        durationS: 1.0,
      );
      // After the first step, commandedVoltage should be clamped to stepV.
      for (final s in samples.skip(1)) {
        expect(s.voltage, closeTo(stepV, 0.01));
      }
    });
  });
}
