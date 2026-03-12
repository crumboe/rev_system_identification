/// Unit tests for the Mechanism types, config validation, and test params.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/mechanisms/mechanism.dart';

void main() {
  // =========================================================================
  // MechanismType enum and extensions
  // =========================================================================

  group('MechanismType extensions', () {
    test('displayName returns human-readable names', () {
      expect(MechanismType.arm.displayName, equals('Arm'));
      expect(MechanismType.elevator.displayName, equals('Elevator'));
      expect(MechanismType.flywheel.displayName, equals('Flywheel'));
    });

    test('hasGravity is true for arm and elevator, false for flywheel', () {
      expect(MechanismType.arm.hasGravity, isTrue);
      expect(MechanismType.elevator.hasGravity, isTrue);
      expect(MechanismType.flywheel.hasGravity, isFalse);
    });

    test('requiresSoftLimits is true for arm and elevator', () {
      expect(MechanismType.arm.requiresSoftLimits, isTrue);
      expect(MechanismType.elevator.requiresSoftLimits, isTrue);
      expect(MechanismType.flywheel.requiresSoftLimits, isFalse);
    });

    test('positionUnit and velocityUnit are correct', () {
      expect(MechanismType.arm.positionUnit, equals('degrees'));
      expect(MechanismType.arm.velocityUnit, equals('deg/s'));
      expect(MechanismType.elevator.positionUnit, equals('meters'));
      expect(MechanismType.elevator.velocityUnit, equals('m/s'));
      expect(MechanismType.flywheel.positionUnit, equals('rotations'));
      expect(MechanismType.flywheel.velocityUnit, equals('RPM'));
    });

    test('imperial units for elevator differ', () {
      expect(MechanismType.elevator.positionUnitImperial, equals('inches'));
      expect(MechanismType.elevator.velocityUnitImperial, equals('in/s'));
      // Arm stays degrees regardless of unit system
      expect(MechanismType.arm.positionUnitImperial, equals('degrees'));
    });

    test('gravityDescription matches expected strings', () {
      expect(
          MechanismType.arm.gravityDescription, contains('cos'));
      expect(MechanismType.elevator.gravityDescription,
          contains('constant'));
      expect(MechanismType.flywheel.gravityDescription, equals('None'));
    });
  });

  // =========================================================================
  // MechanismConfig validation
  // =========================================================================

  group('MechanismConfig.validate()', () {
    test('valid flywheel config produces no errors', () {
      const config = MechanismConfig(
        type: MechanismType.flywheel,
        currentLimitAmps: 40.0,
      );
      expect(config.validate(), isEmpty);
    });

    test('arm without soft limits produces error', () {
      const config = MechanismConfig(
        type: MechanismType.arm,
      );
      final errors = config.validate();
      expect(errors.length, greaterThanOrEqualTo(1));
      expect(errors.first, contains('soft limits'));
    });

    test('elevator without soft limits produces error', () {
      const config = MechanismConfig(
        type: MechanismType.elevator,
      );
      final errors = config.validate();
      expect(errors.any((e) => e.contains('soft limits')), isTrue);
    });

    test('arm with valid soft limits passes', () {
      const config = MechanismConfig(
        type: MechanismType.arm,
        forwardSoftLimit: 90.0,
        reverseSoftLimit: -45.0,
        currentLimitAmps: 30.0,
      );
      expect(config.validate(), isEmpty);
    });

    test('forward <= reverse soft limit is an error', () {
      const config = MechanismConfig(
        type: MechanismType.arm,
        forwardSoftLimit: -10.0,
        reverseSoftLimit: 10.0,
        currentLimitAmps: 30.0,
      );
      final errors = config.validate();
      expect(
          errors.any((e) => e.contains('Forward limit must be greater')),
          isTrue);
    });

    test('current limit > 80 is an error', () {
      const config = MechanismConfig(
        type: MechanismType.flywheel,
        currentLimitAmps: 81.0,
      );
      final errors = config.validate();
      expect(errors.any((e) => e.contains('Current limit')), isTrue);
    });

    test('current limit <= 0 is an error', () {
      const config = MechanismConfig(
        type: MechanismType.flywheel,
        currentLimitAmps: 0.0,
      );
      final errors = config.validate();
      expect(errors.any((e) => e.contains('Current limit')), isTrue);
    });
  });

  // =========================================================================
  // MechanismConfig properties + copyWith
  // =========================================================================

  group('MechanismConfig properties', () {
    test('hasSoftLimits requires both forward and reverse', () {
      const noLimits = MechanismConfig(type: MechanismType.flywheel);
      expect(noLimits.hasSoftLimits, isFalse);

      const forwardOnly = MechanismConfig(
        type: MechanismType.arm,
        forwardSoftLimit: 90.0,
      );
      expect(forwardOnly.hasSoftLimits, isFalse);

      const both = MechanismConfig(
        type: MechanismType.arm,
        forwardSoftLimit: 90.0,
        reverseSoftLimit: -45.0,
      );
      expect(both.hasSoftLimits, isTrue);
    });

    test('positionUnit respects useImperialUnits', () {
      const metric = MechanismConfig(
        type: MechanismType.elevator,
        useImperialUnits: false,
      );
      expect(metric.positionUnit, equals('meters'));

      const imperial = MechanismConfig(
        type: MechanismType.elevator,
        useImperialUnits: true,
      );
      expect(imperial.positionUnit, equals('inches'));
    });

    test('copyWith preserves unmodified fields', () {
      const original = MechanismConfig(
        type: MechanismType.arm,
        currentLimitAmps: 30.0,
        motorInverted: true,
      );
      final copy = original.copyWith(currentLimitAmps: 40.0);
      expect(copy.type, equals(MechanismType.arm));
      expect(copy.motorInverted, isTrue);
      expect(copy.currentLimitAmps, equals(40.0));
    });
  });

  // =========================================================================
  // SysIdTestParams
  // =========================================================================

  group('SysIdTestParams', () {
    test('default constructor has expected values', () {
      const params = SysIdTestParams();
      expect(params.quasistaticRampRate, equals(0.25));
      expect(params.dynamicStepVoltage, equals(7.0));
      expect(params.maxTestVoltage, equals(12.0));
      expect(params.currentTripAmps, isNull);
    });

    test('forMechanism returns different configs per type', () {
      final flywheel = SysIdTestParams.forMechanism(MechanismType.flywheel);
      final arm = SysIdTestParams.forMechanism(MechanismType.arm);
      // Arm has lower step voltage and current trip
      expect(arm.dynamicStepVoltage, lessThan(flywheel.dynamicStepVoltage));
      expect(arm.currentTripAmps, isNotNull);
      expect(flywheel.currentTripAmps, isNull);
    });

    test('elevator has current trip amps', () {
      final elevator =
          SysIdTestParams.forMechanism(MechanismType.elevator);
      expect(elevator.currentTripAmps, isNotNull);
    });

    test('copyWith preserves unmodified fields', () {
      const params = SysIdTestParams(
        quasistaticRampRate: 0.5,
        dynamicStepVoltage: 5.0,
      );
      final copy = params.copyWith(dynamicStepVoltage: 6.0);
      expect(copy.quasistaticRampRate, equals(0.5));
      expect(copy.dynamicStepVoltage, equals(6.0));
    });

    test('copyWith can set currentTripAmps to null', () {
      const params = SysIdTestParams(currentTripAmps: 30.0);
      final copy = params.copyWith(currentTripAmps: () => null);
      expect(copy.currentTripAmps, isNull);
    });
  });

  // =========================================================================
  // TestType enum
  // =========================================================================

  group('TestType extensions', () {
    test('isQuasistatic and isDynamic are mutually exclusive', () {
      for (final tt in TestType.values) {
        expect(tt.isQuasistatic != tt.isDynamic, isTrue,
            reason: '${tt.name} should be either quasistatic or dynamic');
      }
    });

    test('isForward matches expected types', () {
      expect(TestType.quasistaticForward.isForward, isTrue);
      expect(TestType.dynamicForward.isForward, isTrue);
      expect(TestType.quasistaticReverse.isForward, isFalse);
      expect(TestType.dynamicReverse.isForward, isFalse);
    });

    test('voltageSign is +1 for forward, -1 for reverse', () {
      expect(TestType.quasistaticForward.voltageSign, equals(1.0));
      expect(TestType.dynamicForward.voltageSign, equals(1.0));
      expect(TestType.quasistaticReverse.voltageSign, equals(-1.0));
      expect(TestType.dynamicReverse.voltageSign, equals(-1.0));
    });

    test('displayName returns human-readable strings', () {
      expect(TestType.quasistaticForward.displayName,
          equals('Quasistatic Forward'));
      expect(TestType.dynamicReverse.displayName,
          equals('Dynamic Reverse'));
    });
  });
}
