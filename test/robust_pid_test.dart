/// Tests for the robust PID pipeline: mass-to-voltage conversion,
/// blended feedforward, robust velocity/position PID, tagged TestRun
/// round-trip, and PidResult iZone serialization.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/mechanisms/mechanism.dart';
import 'package:rev_system_identification/simulation/arm_physics.dart';
import 'package:rev_system_identification/simulation/elevator_physics.dart';
import 'package:rev_system_identification/simulation/flywheel_physics.dart';
import 'package:rev_system_identification/simulation/project_physics_factory.dart';
import 'package:rev_system_identification/simulation/simulated_device.dart';
import 'package:rev_system_identification/sysid/pid_autotuner.dart';

void main() {
  // =========================================================================
  // Mass → voltage conversion
  // =========================================================================

  group('computeLoadTorqueVolts', () {
    test('arm: 5 lbs load on 10 lb arm → half of kG', () {
      final config = MechanismConfig(
        type: MechanismType.arm,
        simulatedArmMassLbs: 10.0,
        simulatedArmLengthIn: 20.0,
      );
      final physics = ArmPhysics(kG: 0.80);
      final volts = computeLoadTorqueVolts(
        loadMassKg: 10.0 / 2.2046 / 2.0, // 5 lbs in kg
        config: config,
        physics: physics,
      );
      // (5 lbs / 10 lbs ref) × 0.80 kG = 0.40 V
      expect(volts, closeTo(0.40, 0.01));
    });

    test('arm: default ref mass used when config has no arm mass', () {
      final config = MechanismConfig(type: MechanismType.arm);
      final physics = ArmPhysics(kG: 0.80);
      // Default ref mass = 10 lbs = 4.536 kg. Load = 4.536 kg → ratio = 1.0.
      final volts = computeLoadTorqueVolts(
        loadMassKg: 10.0 / 2.2046,
        config: config,
        physics: physics,
      );
      expect(volts, closeTo(0.80, 0.01));
    });

    test('elevator: 2.5 kg load on 5 kg ref → half of kG', () {
      final config = MechanismConfig(
        type: MechanismType.elevator,
        simulatedElevatorCarriageMassKg: 5.0,
      );
      final physics = ElevatorPhysics(kG: 0.55);
      final volts = computeLoadTorqueVolts(
        loadMassKg: 2.5,
        config: config,
        physics: physics,
      );
      expect(volts, closeTo(0.275, 0.01));
    });

    test('flywheel returns 0', () {
      final config = MechanismConfig(type: MechanismType.flywheel);
      final physics = ArmPhysics(); // type doesn't matter
      final volts = computeLoadTorqueVolts(
        loadMassKg: 5.0,
        config: config,
        physics: physics,
      );
      expect(volts, 0.0);
    });

    test('zero load returns 0', () {
      final config = MechanismConfig(type: MechanismType.arm);
      final physics = ArmPhysics(kG: 0.80);
      final volts = computeLoadTorqueVolts(
        loadMassKg: 0.0,
        config: config,
        physics: physics,
      );
      expect(volts, 0.0);
    });
  });

  // =========================================================================
  // Blended feedforward
  // =========================================================================

  group('PidAutoTuner.blendFeedforward', () {
    test('arithmetic mean of all parameters', () {
      const u = FeedforwardGains(kS: 0.20, kV: 0.018, kA: 0.002, kG: 0.80);
      const l = FeedforwardGains(kS: 0.24, kV: 0.020, kA: 0.004, kG: 1.20);
      final b = PidAutoTuner.blendFeedforward(u, l);
      expect(b.kS, closeTo(0.22, 1e-9));
      expect(b.kV, closeTo(0.019, 1e-9));
      expect(b.kA, closeTo(0.003, 1e-9));
      expect(b.kG, closeTo(1.00, 1e-9));
    });
  });

  // =========================================================================
  // Robust velocity PID
  // =========================================================================

  group('PidAutoTuner.tuneRobustVelocity', () {
    const ffU = FeedforwardGains(kS: 0.14, kV: 0.018, kA: 0.002, kG: 0.80);
    const ffL = FeedforwardGains(kS: 0.16, kV: 0.020, kA: 0.004, kG: 1.20);

    test('kP uses min(kA)', () {
      final pid = PidAutoTuner.tuneRobustVelocity(
        ffUnloaded: ffU,
        ffLoaded: ffL,
        mechanismType: MechanismType.arm,
        desiredTimeConstantMs: 200.0,
      );
      // min(kA) = 0.002
      final expected = 0.002 / (200.0 / 1000.0) / 12.0;
      expect(pid.kP, closeTo(expected, 1e-9));
    });

    test('kI is nonzero', () {
      final pid = PidAutoTuner.tuneRobustVelocity(
        ffUnloaded: ffU,
        ffLoaded: ffL,
        mechanismType: MechanismType.arm,
      );
      expect(pid.kI, greaterThan(0));
    });

    test('kI uses the slower robust integral time constant', () {
      final pid = PidAutoTuner.tuneRobustVelocity(
        ffUnloaded: ffU,
        ffLoaded: ffL,
        mechanismType: MechanismType.arm,
      );
      const kA = 0.002;
      const kV = 0.020;
      const tau = 0.1;
      const plantTau = kA / kV;
      final kP = kA / tau / 12.0;
      final ti = PidAutoTuner.robustVelocityIntegralTimeSec(
        closedLoopTauSec: tau,
        plantTauSec: plantTau,
      );
      // kI is scaled by the SPARK control period (0.001) for discrete accumulation.
      expect(pid.kI, closeTo((kP / ti) * 0.001, 1e-12));
      expect(pid.kI, lessThan(kP / (10.0 * plantTau)));
    });

    test('iZone is nonzero when ΔkG > 0', () {
      final pid = PidAutoTuner.tuneRobustVelocity(
        ffUnloaded: ffU,
        ffLoaded: ffL,
        mechanismType: MechanismType.arm,
      );
      expect(pid.iZone, greaterThan(0));
    });

    test('warnings mention robust gains', () {
      final pid = PidAutoTuner.tuneRobustVelocity(
        ffUnloaded: ffU,
        ffLoaded: ffL,
        mechanismType: MechanismType.arm,
      );
      expect(pid.warnings.any((w) => w.contains('Robust')), isTrue);
    });
  });

  // =========================================================================
  // Robust position PID
  // =========================================================================

  group('PidAutoTuner.tuneRobustPosition', () {
    const ffU = FeedforwardGains(kS: 0.14, kV: 0.018, kA: 0.002, kG: 0.80);
    const ffL = FeedforwardGains(kS: 0.16, kV: 0.020, kA: 0.004, kG: 1.20);

    test('kP uses max(kA) with bandwidth clamping', () {
      final pid = PidAutoTuner.tuneRobustPosition(
        ffUnloaded: ffU,
        ffLoaded: ffL,
        mechanismType: MechanismType.arm,
        desiredBandwidthHz: 5.0,
      );
      // plantTau = max(kA)/max(kV) = 0.004/0.020 = 0.2s
      // maxOmega = 3.0 / 0.2 = 15 rad/s (~2.39 Hz, clamped from 5 Hz)
      // kP = r * max(kA) * omega^2 / Vnom
      const kA = 0.004;
      const kV = 0.020;
      final plantTau = kA / kV;
      final omega = 3.0 / plantTau; // clamped
      final expected = 1.0 * kA * omega * omega / 12.0;
      expect(pid.kP, closeTo(expected, 0.001));
    });

    test('kI is nonzero', () {
      final pid = PidAutoTuner.tuneRobustPosition(
        ffUnloaded: ffU,
        ffLoaded: ffL,
        mechanismType: MechanismType.arm,
      );
      expect(pid.kI, greaterThan(0));
    });

    test('kI uses the slower robust position integral time constant', () {
      final pid = PidAutoTuner.tuneRobustPosition(
        ffUnloaded: ffU,
        ffLoaded: ffL,
        mechanismType: MechanismType.arm,
      );
      const kA = 0.004;
      const kV = 0.020;
      const omega = 15.0; // bandwidth is clamped from 5 Hz to 3.0/plantTau
      const plantTau = kA / kV;
      final kP = kA * omega * omega / 12.0;
      final ti = PidAutoTuner.robustPositionIntegralTimeSec(
        omegaRadPerSec: omega,
        plantTauSec: plantTau,
      );
      // kI is scaled by the SPARK control period (0.001) for discrete accumulation.
      expect(pid.kI, closeTo((kP / ti) * 0.001, 1e-12));
      expect(pid.kI, lessThan(kP * omega / 20.0));
    });

    test('iZone is nonzero', () {
      final pid = PidAutoTuner.tuneRobustPosition(
        ffUnloaded: ffU,
        ffLoaded: ffL,
        mechanismType: MechanismType.arm,
      );
      expect(pid.iZone, greaterThan(0));
    });

    test('kD is non-negative', () {
      final pid = PidAutoTuner.tuneRobustPosition(
        ffUnloaded: ffU,
        ffLoaded: ffL,
        mechanismType: MechanismType.arm,
        desiredBandwidthHz: 5.0,
        dampingRatio: 1.0,
      );
      // With kV/kA FF active, kD = 2·ζ·kA·ω / V_nom (always positive)
      expect(pid.kD, greaterThanOrEqualTo(0));
    });

    test('dFilter is set when kD > 0', () {
      final pid = PidAutoTuner.tuneRobustPosition(
        ffUnloaded: ffU,
        ffLoaded: ffL,
        mechanismType: MechanismType.arm,
        desiredBandwidthHz: 5.0,
      );
      if (pid.kD > 0) {
        expect(pid.dFilter, greaterThan(0));
      }
    });
  });

  // =========================================================================
  // TestRun loadCondition JSON round-trip
  // =========================================================================

  group('TestRun loadCondition round-trip', () {
    test('loaded TestRun survives JSON', () {
      final run = TestRun(
        id: 'test-1',
        testType: TestType.quasistaticForward,
        mechanismType: MechanismType.arm,
        data: [DataPoint(timestamp: 0, voltage: 1, velocity: 2, position: 3, current: 0.5)],
        startTime: DateTime(2025, 1, 1),
        durationSeconds: 1.0,
        testParams: const SysIdTestParams(),
        loadCondition: LoadCondition.loaded,
        loadMassKg: 3.5,
      );
      final json = run.toJson();
      final restored = TestRun.fromJson(json);
      expect(restored.loadCondition, LoadCondition.loaded);
      expect(restored.loadMassKg, 3.5);
    });

    test('unloaded TestRun survives JSON', () {
      final run = TestRun(
        id: 'test-2',
        testType: TestType.dynamicForward,
        mechanismType: MechanismType.arm,
        data: [DataPoint(timestamp: 0, voltage: 1, velocity: 2, position: 3, current: 0.5)],
        startTime: DateTime(2025, 1, 1),
        durationSeconds: 1.0,
        testParams: const SysIdTestParams(),
        loadCondition: LoadCondition.unloaded,
      );
      final json = run.toJson();
      final restored = TestRun.fromJson(json);
      expect(restored.loadCondition, LoadCondition.unloaded);
      expect(restored.loadMassKg, isNull);
    });

    test('null loadCondition (legacy) survives JSON', () {
      final run = TestRun(
        id: 'test-3',
        testType: TestType.dynamicReverse,
        mechanismType: MechanismType.elevator,
        data: [DataPoint(timestamp: 0, voltage: 1, velocity: 2, position: 3, current: 0.5)],
        startTime: DateTime(2025, 1, 1),
        durationSeconds: 1.0,
        testParams: const SysIdTestParams(),
      );
      final json = run.toJson();
      final restored = TestRun.fromJson(json);
      expect(restored.loadCondition, isNull);
      expect(restored.loadMassKg, isNull);
    });
  });

  // =========================================================================
  // PidResult iZone serialization
  // =========================================================================

  group('PidResult iZone', () {
    test('iZone round-trips through JSON', () {
      final pid = PidResult(kP: 0.1, kI: 0.02, kD: 0.05, iZone: 1.5);
      final json = pid.toJson();
      final restored = PidResult.fromJson(json);
      expect(restored.iZone, 1.5);
    });

    test('iZone defaults to 0 when absent from JSON', () {
      final json = {'kP': 0.1, 'kI': 0.0, 'kD': 0.0};
      final restored = PidResult.fromJson(json);
      expect(restored.iZone, 0.0);
    });

    test('copyWith preserves iZone', () {
      final pid = PidResult(kP: 0.1, kI: 0.02, kD: 0.05, iZone: 1.5);
      final copy = pid.copyWith(kP: 0.2);
      expect(copy.iZone, 1.5);
      expect(copy.kP, 0.2);
    });

    test('copyWith can change iZone', () {
      final pid = PidResult(kP: 0.1, kI: 0.02, kD: 0.05, iZone: 1.5);
      final copy = pid.copyWith(iZone: 3.0);
      expect(copy.iZone, 3.0);
    });
  });

  // =========================================================================
  // Simulated controller iZone behavior
  // =========================================================================

  group('SimulatedPidFfController iZone', () {
    test('velocity integral only accumulates inside iZone and resets outside',
        () async {
      final params = SimulatedParameterApi();
      final physics = FlywheelPhysics(noiseLevel: 0.0);
      final controller = SimulatedPidFfController(params, physics);

      await params.setPidSlot0(
        p: 0.0,
        i: 1.0,
        d: 0.0,
        iZone: 5.0,
      );

      final firstInside = controller.computeVelocity(4.0, 0.1);
      final secondInside = controller.computeVelocity(4.0, 0.1);
      final outsideZone = controller.computeVelocity(10.0, 0.1);
      final afterReset = controller.computeVelocity(4.0, 0.1);

      expect(firstInside, closeTo(4.8, 1e-9));
      expect(secondInside, closeTo(9.6, 1e-9));
      expect(outsideZone, closeTo(0.0, 1e-9));
      expect(afterReset, closeTo(4.8, 1e-9));
    });

    test('position integral only accumulates inside iZone and resets outside',
        () async {
      final params = SimulatedParameterApi();
      final physics = FlywheelPhysics(noiseLevel: 0.0);
      final controller = SimulatedPidFfController(params, physics);

      await params.setPidSlot0(
        p: 0.0,
        i: 1.0,
        d: 0.0,
        iZone: 2.0,
      );

      final firstInside = controller.computePosition(1.0, 0.1);
      final secondInside = controller.computePosition(1.0, 0.1);
      final outsideZone = controller.computePosition(3.0, 0.1);
      final afterReset = controller.computePosition(1.0, 0.1);

      expect(firstInside, closeTo(1.2, 1e-9));
      expect(secondInside, closeTo(2.4, 1e-9));
      expect(outsideZone, closeTo(0.0, 1e-9));
      expect(afterReset, closeTo(1.2, 1e-9));
    });
  });
}
