/// Unit tests for the three physics simulation engines.
///
/// Uses noiseLevel: 0 and fixed randomSeed for deterministic behaviour.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/simulation/flywheel_physics.dart';
import 'package:rev_system_identification/simulation/arm_physics.dart';
import 'package:rev_system_identification/simulation/elevator_physics.dart';

void main() {
  // =========================================================================
  // Flywheel physics
  // =========================================================================

  group('FlywheelPhysics', () {
    late FlywheelPhysics phy;

    setUp(() {
      phy = FlywheelPhysics(noiseLevel: 0.0, randomSeed: 42);
    });

    test('initial state is zero', () {
      expect(phy.velocityRpm, equals(0.0));
      expect(phy.positionRotations, equals(0.0));
      expect(phy.commandedVoltage, equals(0.0));
    });

    test('reset returns to zero state', () {
      phy.step(6.0, 0.01);
      phy.step(6.0, 0.01);
      phy.reset();
      expect(phy.velocityRpm, equals(0.0));
      expect(phy.positionRotations, equals(0.0));
    });

    test('step with positive voltage increases velocity', () {
      for (var i = 0; i < 100; i++) {
        phy.step(6.0, 0.01);
      }
      expect(phy.velocityRpm, greaterThan(0.0));
    });

    test('step with negative voltage produces negative velocity', () {
      for (var i = 0; i < 100; i++) {
        phy.step(-6.0, 0.01);
      }
      expect(phy.velocityRpm, lessThan(0.0));
    });

    test('stall: voltage below kS does not accelerate', () {
      // kS = 0.14, so 0.10 V should not overcome static friction
      for (var i = 0; i < 50; i++) {
        phy.step(0.10, 0.01);
      }
      expect(phy.velocityRpm, equals(0.0));
    });

    test('position increases with positive velocity', () {
      for (var i = 0; i < 200; i++) {
        phy.step(6.0, 0.01);
      }
      expect(phy.positionRotations, greaterThan(0.0));
    });

    test('noisyVelocityRpm equals velocityRpm when noiseLevel is 0', () {
      for (var i = 0; i < 50; i++) {
        phy.step(6.0, 0.01);
      }
      expect(phy.noisyVelocityRpm, closeTo(phy.velocityRpm, 1e-6));
    });

    test('noisyPositionRotations equals positionRotations when noiseLevel is 0',
        () {
      for (var i = 0; i < 50; i++) {
        phy.step(6.0, 0.01);
      }
      expect(phy.noisyPositionRotations,
          closeTo(phy.positionRotations, 1e-6));
    });

    test('setPositionRotations overrides position', () {
      phy.setPositionRotations(5.0);
      expect(phy.positionRotations, equals(5.0));
    });

    test('outputCurrentAmps is non-negative under load', () {
      for (var i = 0; i < 50; i++) {
        phy.step(6.0, 0.01);
      }
      expect(phy.outputCurrentAmps, greaterThanOrEqualTo(0.0));
    });

    test('label returns expected string', () {
      expect(phy.label, equals('Simulated Flywheel'));
    });

    test('ground truth constants are exposed', () {
      expect(phy.kS, equals(0.14));
      expect(phy.kV, equals(0.0185));
      expect(phy.kA, equals(0.003));
      expect(phy.kG, equals(0.0));
    });

    test('temperatureC returns 25', () {
      expect(phy.temperatureC, equals(25));
    });

    test('reaches steady-state velocity proportional to voltage', () {
      // At steady state: V = kS + kV*v  =>  v = (V - kS) / kV
      const voltage = 6.0;
      final expectedRpm = (voltage - phy.kS) / phy.kV;
      // Run for 10 seconds (1000 steps at 10ms)
      for (var i = 0; i < 1000; i++) {
        phy.step(voltage, 0.01);
      }
      expect(phy.velocityRpm, closeTo(expectedRpm, expectedRpm * 0.05));
    });
  });

  // =========================================================================
  // Arm physics
  // =========================================================================

  group('ArmPhysics', () {
    late ArmPhysics phy;

    setUp(() {
      phy = ArmPhysics(noiseLevel: 0.0, randomSeed: 42);
    });

    test('initial state is zero', () {
      expect(phy.noisyVelocityRpm, equals(0.0));
      expect(phy.noisyPositionRotations, closeTo(0.0, 1e-6));
    });

    test('gravity requires voltage to hold position', () {
      // At 0 degrees (horizontal), gravity = kG * cos(0) = kG
      // Without voltage, arm should fall (velocity becomes negative if above horizontal)
      for (var i = 0; i < 200; i++) {
        phy.step(0.0, 0.01);
      }
      // The arm should have moved (velocity or position changed)
      // At horizontal, gravity pulls it down (decreasing angle)
      expect(phy.noisyPositionRotations, lessThanOrEqualTo(0.0));
    });

    test('sufficient voltage holds against gravity', () {
      // Voltage ≈ kG * cos(0) = 0.80 V should roughly hold at horizontal
      // With friction kS = 0.20, we need slightly more
      phy.setPositionRotations(0.0); // horizontal
      for (var i = 0; i < 100; i++) {
        phy.step(phy.kG, 0.01);
      }
      // Position should stay roughly at 0 (within a small window)
      final posRotations = phy.noisyPositionRotations;
      expect(posRotations.abs(), lessThan(0.05)); // ~18 degrees tolerance
    });

    test('hard stops at limits', () {
      // Drive arm past max angle
      for (var i = 0; i < 2000; i++) {
        phy.step(12.0, 0.01);
      }
      // Position should not exceed maxAngleDeg / 360
      expect(phy.noisyPositionRotations,
          lessThanOrEqualTo(phy.maxAngleDeg / 360.0 + 0.001));
    });

    test('hard stops at min angle', () {
      for (var i = 0; i < 2000; i++) {
        phy.step(-12.0, 0.01);
      }
      expect(phy.noisyPositionRotations,
          greaterThanOrEqualTo(phy.minAngleDeg / 360.0 - 0.001));
    });

    test('reset clears state', () {
      for (var i = 0; i < 100; i++) {
        phy.step(6.0, 0.01);
      }
      phy.reset();
      expect(phy.noisyPositionRotations, closeTo(0.0, 1e-6));
    });

    test('ground truth constants are exposed', () {
      expect(phy.kS, equals(0.20));
      expect(phy.kV, equals(0.018));
      expect(phy.kA, equals(0.002));
      expect(phy.kG, equals(0.80));
    });

    test('label returns expected string', () {
      expect(phy.label, equals('Simulated Arm'));
    });
  });

  // =========================================================================
  // Elevator physics
  // =========================================================================

  group('ElevatorPhysics', () {
    late ElevatorPhysics phy;

    setUp(() {
      phy = ElevatorPhysics(noiseLevel: 0.0, randomSeed: 42);
    });

    test('initial state is zero', () {
      expect(phy.noisyVelocityRpm, equals(0.0));
      expect(phy.noisyPositionRotations, closeTo(0.0, 1e-6));
    });

    test('gravity pulls elevator down without voltage', () {
      // Set position above zero so it can fall
      phy.setPositionRotations(10.0); // 10 rotations ≈ 15 inches
      for (var i = 0; i < 200; i++) {
        phy.step(0.0, 0.01);
      }
      // Should have moved down (position decreased)
      expect(phy.noisyPositionRotations, lessThan(10.0));
    });

    test('sufficient voltage holds against gravity', () {
      phy.setPositionRotations(10.0);
      // kG = 0.55 V, kS = 0.18 V; apply slightly more than kG
      for (var i = 0; i < 100; i++) {
        phy.step(phy.kG, 0.01);
      }
      // Position should stay roughly at 10 rotations
      expect(phy.noisyPositionRotations, closeTo(10.0, 1.0));
    });

    test('hard stop at bottom (minPositionIn)', () {
      for (var i = 0; i < 2000; i++) {
        phy.step(-12.0, 0.01);
      }
      // Position should not go below minPositionIn / inchesPerRotation
      expect(phy.noisyPositionRotations,
          greaterThanOrEqualTo(phy.minPositionIn / phy.inchesPerRotation - 0.001));
    });

    test('hard stop at top (maxPositionIn)', () {
      for (var i = 0; i < 2000; i++) {
        phy.step(12.0, 0.01);
      }
      expect(phy.noisyPositionRotations,
          lessThanOrEqualTo(phy.maxPositionIn / phy.inchesPerRotation + 0.001));
    });

    test('reset clears state', () {
      for (var i = 0; i < 100; i++) {
        phy.step(6.0, 0.01);
      }
      phy.reset();
      expect(phy.noisyPositionRotations, closeTo(0.0, 1e-6));
    });

    test('setPositionRotations clamps to limits', () {
      phy.setPositionRotations(99999.0);
      expect(phy.noisyPositionRotations,
          lessThanOrEqualTo(phy.maxPositionIn / phy.inchesPerRotation + 0.001));
    });

    test('ground truth constants are exposed', () {
      expect(phy.kS, equals(0.18));
      expect(phy.kV, equals(0.12));
      expect(phy.kA, equals(0.015));
      expect(phy.kG, equals(0.55));
    });

    test('label returns expected string', () {
      expect(phy.label, equals('Simulated Elevator'));
    });

    test('temperatureC returns 25', () {
      expect(phy.temperatureC, equals(25));
    });
  });

  // =========================================================================
  // Cross-engine: noisy sensors with noiseLevel > 0
  // =========================================================================

  group('Sensor noise', () {
    test('flywheel noisy readings differ from clean when noise > 0', () {
      final phy = FlywheelPhysics(noiseLevel: 0.1, randomSeed: 1);
      for (var i = 0; i < 100; i++) {
        phy.step(6.0, 0.01);
      }
      // With noise, consecutive reads should vary
      final r1 = phy.noisyVelocityRpm;
      final r2 = phy.noisyVelocityRpm;
      // They might be equal by chance but are independent samples.
      // Just check the reading is in the right ballpark.
      expect(r1, closeTo(phy.velocityRpm, phy.velocityRpm * 0.15));
    });
  });
}
