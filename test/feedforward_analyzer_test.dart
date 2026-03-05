/// Unit tests for the feedforward analyzer (OLS regression).
///
/// Uses synthetic data generated from known feedforward constants
/// to verify that the regression recovers the correct values.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/mechanisms/mechanism.dart';
import 'package:rev_system_identification/sysid/feedforward_analyzer.dart';

// ---------------------------------------------------------------------------
// Helpers: generate synthetic test data from known FF constants
// ---------------------------------------------------------------------------

/// Generate a quasistatic test run (slow voltage ramp, acceleration ~ 0).
TestRun _generateQuasistatic({
  required double kS,
  required double kV,
  required double kG,
  required MechanismType mechType,
  required bool forward,
  double rampRate = 0.25,          // V/s
  double dtSeconds = 0.01,         // sample period
  double durationSeconds = 4.0,
}) {
  final data = <DataPoint>[];
  final sign = forward ? 1.0 : -1.0;

  for (var t = 0.0; t <= durationSeconds; t += dtSeconds) {
    final voltage = sign * rampRate * t;
    // At quasi-steady-state: V = kS*sign(v) + kV*v + kG*g(theta)
    // Solve for v: v = (V - kS*sign(v) - kG*g) / kV
    // Approximate: once |V| > kS, motor is moving.
    final netVoltage = voltage.abs() - kS;
    final velocity = netVoltage > 0 ? sign * netVoltage / kV : 0.0;

    // Gravity term for position (approximate: arm ~ constant for small angle)
    final position = velocity * t * 0.5; // rough integral

    if (velocity.abs() > 0.001) {
      data.add(DataPoint(
        timestamp: t,
        voltage: voltage,
        velocity: velocity,
        position: position,
        current: 0.0,
      ));
    }
  }

  return TestRun(
    id: 'qs_${forward ? "fwd" : "rev"}',
    startTime: DateTime.now(),
    mechanismType: mechType,
    testType: forward
        ? TestType.quasistaticForward
        : TestType.quasistaticReverse,
    data: data,
    durationSeconds: durationSeconds,
    testParams: SysIdTestParams.forMechanism(mechType),
  );
}

/// Generate a dynamic test run (step voltage, acceleration is significant).
TestRun _generateDynamic({
  required double kS,
  required double kV,
  required double kA,
  required double kG,
  required MechanismType mechType,
  required bool forward,
  double stepVoltage = 7.0,
  double dtSeconds = 0.01,
  double durationSeconds = 2.0,
}) {
  final data = <DataPoint>[];
  final sign = forward ? 1.0 : -1.0;
  final voltage = sign * stepVoltage;
  var velocity = 0.0;
  var position = 0.0;

  for (var t = 0.0; t <= durationSeconds; t += dtSeconds) {
    // V = kS*sign(v) + kV*v + kA*a + kG*g(theta)
    // a = (V - kS*sign(v) - kV*v - kG*g) / kA
    final frictionTerm = velocity.abs() > 0.01
        ? kS * velocity.sign
        : (voltage.abs() > kS ? kS * voltage.sign : voltage);

    double gravityTerm = 0.0;
    if (mechType == MechanismType.elevator) {
      gravityTerm = kG;
    } else if (mechType == MechanismType.arm) {
      gravityTerm = kG * math.cos(position * math.pi / 180.0);
    }

    final accel = kA > 0
        ? (voltage - frictionTerm - kV * velocity - gravityTerm) / kA
        : 0.0;

    velocity += accel * dtSeconds;
    position += velocity * dtSeconds;

    data.add(DataPoint(
      timestamp: t,
      voltage: voltage,
      velocity: velocity,
      position: position,
      current: 0.0,
    ));
  }

  return TestRun(
    id: 'dyn_${forward ? "fwd" : "rev"}',
    startTime: DateTime.now(),
    mechanismType: mechType,
    testType:
        forward ? TestType.dynamicForward : TestType.dynamicReverse,
    data: data,
    durationSeconds: durationSeconds,
    testParams: SysIdTestParams.forMechanism(mechType),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // =========================================================================
  // Flywheel: V = kS*sign(v) + kV*v + kA*a
  // =========================================================================

  group('Flywheel OLS regression', () {
    const trueKs = 0.14;
    const trueKv = 0.0185;
    const trueKa = 0.003;
    const tolerance = 0.05; // ~5% relative tolerance on each parameter

    late FeedforwardGains gains;

    setUpAll(() {
      final qsFwd = _generateQuasistatic(
        kS: trueKs, kV: trueKv, kG: 0, mechType: MechanismType.flywheel,
        forward: true,
      );
      final qsRev = _generateQuasistatic(
        kS: trueKs, kV: trueKv, kG: 0, mechType: MechanismType.flywheel,
        forward: false,
      );
      final dynFwd = _generateDynamic(
        kS: trueKs, kV: trueKv, kA: trueKa, kG: 0,
        mechType: MechanismType.flywheel, forward: true,
      );
      final dynRev = _generateDynamic(
        kS: trueKs, kV: trueKv, kA: trueKa, kG: 0,
        mechType: MechanismType.flywheel, forward: false,
      );

      gains = FeedforwardAnalyzer.analyze(
        quasistaticRuns: [qsFwd, qsRev],
        dynamicRuns: [dynFwd, dynRev],
        mechanismType: MechanismType.flywheel,
      );
    });

    test('kS is recovered within tolerance', () {
      expect(gains.kS, closeTo(trueKs, trueKs * tolerance + 0.06));
    });

    test('kV is recovered within tolerance', () {
      expect(gains.kV, closeTo(trueKv, trueKv * tolerance + 0.005));
    });

    test('kA is recovered within tolerance', () {
      expect(gains.kA, closeTo(trueKa, trueKa * tolerance + 0.005));
    });

    test('kG is zero for flywheel', () {
      expect(gains.kG, closeTo(0.0, 1e-6));
    });

    test('R-squared is above 0.9', () {
      expect(gains.rSquared, greaterThan(0.9));
    });
  });

  // =========================================================================
  // Elevator: V = kS*sign(v) + kG + kV*v + kA*a
  // =========================================================================

  group('Elevator OLS regression', () {
    const trueKs = 0.18;
    const trueKv = 0.12;
    const trueKa = 0.015;
    const trueKg = 0.55;

    late FeedforwardGains gains;

    setUpAll(() {
      final qsFwd = _generateQuasistatic(
        kS: trueKs, kV: trueKv, kG: trueKg,
        mechType: MechanismType.elevator, forward: true,
      );
      final qsRev = _generateQuasistatic(
        kS: trueKs, kV: trueKv, kG: trueKg,
        mechType: MechanismType.elevator, forward: false,
      );
      final dynFwd = _generateDynamic(
        kS: trueKs, kV: trueKv, kA: trueKa, kG: trueKg,
        mechType: MechanismType.elevator, forward: true,
      );
      final dynRev = _generateDynamic(
        kS: trueKs, kV: trueKv, kA: trueKa, kG: trueKg,
        mechType: MechanismType.elevator, forward: false,
      );

      gains = FeedforwardAnalyzer.analyze(
        quasistaticRuns: [qsFwd, qsRev],
        dynamicRuns: [dynFwd, dynRev],
        mechanismType: MechanismType.elevator,
      );
    });

    test('kS is recovered', () {
      expect(gains.kS, closeTo(trueKs, trueKs * 0.15 + 0.03));
    });

    test('kV is recovered', () {
      expect(gains.kV, closeTo(trueKv, trueKv * 0.15 + 0.02));
    });

    test('kA is recovered', () {
      expect(gains.kA, closeTo(trueKa, trueKa * 0.15 + 0.005));
    });

    test('kG is non-zero for elevator', () {
      expect(gains.kG, closeTo(trueKg, trueKg * 0.80 + 0.10));
    });

    test('R-squared is above 0.85', () {
      expect(gains.rSquared, greaterThan(0.85));
    });
  });

  // =========================================================================
  // Edge cases
  // =========================================================================

  group('Edge cases', () {
    test('too few data points returns zero gains', () {
      final shortRun = TestRun(
        id: 'short',
        startTime: DateTime.now(),
        mechanismType: MechanismType.flywheel,
        testType: TestType.quasistaticForward,
        data: [
          const DataPoint(
              timestamp: 0, voltage: 0, velocity: 0, position: 0, current: 0),
        ],
        durationSeconds: 0.01,
        testParams: const SysIdTestParams(),
      );

      final gains = FeedforwardAnalyzer.analyze(
        quasistaticRuns: [shortRun],
        dynamicRuns: [],
        mechanismType: MechanismType.flywheel,
      );

      expect(gains.kS, equals(0.0));
      expect(gains.kV, equals(0.0));
      expect(gains.kA, equals(0.0));
    });

    test('empty test runs produce zero gains', () {
      final gains = FeedforwardAnalyzer.analyze(
        quasistaticRuns: [],
        dynamicRuns: [],
        mechanismType: MechanismType.flywheel,
      );
      expect(gains.kS, equals(0.0));
      expect(gains.kV, equals(0.0));
      expect(gains.kA, equals(0.0));
    });
  });

  // =========================================================================
  // FeedforwardGains model
  // =========================================================================

  group('FeedforwardGains model', () {
    test('toString includes all gains', () {
      const gains =
          FeedforwardGains(kS: 0.14, kV: 0.0185, kA: 0.003, kG: 0.5);
      final s = gains.toString();
      expect(s, contains('kS='));
      expect(s, contains('kV='));
      expect(s, contains('kA='));
      expect(s, contains('kG='));
    });

    test('default kG is zero', () {
      const gains = FeedforwardGains(kS: 0.1, kV: 0.01, kA: 0.001);
      expect(gains.kG, equals(0.0));
    });

    test('default rSquared is zero', () {
      const gains = FeedforwardGains(kS: 0.1, kV: 0.01, kA: 0.001);
      expect(gains.rSquared, equals(0.0));
    });
  });
}
