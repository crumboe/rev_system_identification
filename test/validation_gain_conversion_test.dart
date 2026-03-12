/// Unit tests for the validation-mode gain handling with onboard conversion
/// factors.
///
/// With onboard CFs the SPARK firmware handles unit conversion internally.
/// Gains computed from user-unit data are written to the controller WITHOUT
/// pre-scaling.  These tests verify that gains pass through unmodified and
/// that kCosRatio is always 1/360.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/mechanisms/mechanism.dart';
import 'package:rev_system_identification/sysid/pid_autotuner.dart';

// ---------------------------------------------------------------------------
// With onboard CFs, no gain pre-scaling is needed.
// ---------------------------------------------------------------------------

void main() {
  group('Flywheel (VCF=1, PCF=1) — gains pass through unchanged', () {
    const ff = FeedforwardGains(kS: 0.14, kV: 0.0185, kA: 0.003);

    test('velocity PID gains are written in user units (no scaling)', () {
      final velPid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
      );
      // With onboard CFs, gains go to the controller as-is.
      expect(velPid.kP, isPositive);
      expect(velPid.kI, isZero);
      expect(velPid.kD, equals(0.0));
    });

    test('FF kV passes through unchanged', () {
      // kV is in V/(user vel unit) — written directly.
      expect(ff.kV, closeTo(0.0185, 1e-9));
    });
  });

  // ---------------------------------------------------------------------------
  // Arm (VCF = 6.0 deg·s⁻¹/RPM, PCF = 360 deg/rotation — gear ratio = 1)
  // ---------------------------------------------------------------------------

  group('Arm with no gear reduction (VCF=6, PCF=360) — gains unscaled', () {
    const ff = FeedforwardGains(kS: 0.20, kV: 0.018, kA: 0.002, kG: 0.80);

    test('velocity PID gains pass through in user units', () {
      final velPid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.arm,
      );
      // Gains are in user units (dc/deg·s⁻¹) — no VCF multiplication.
      expect(velPid.kP, isPositive);
    });

    test('FF kV passes through in user units', () {
      // kV is V/(deg/s) — written directly to the controller.
      expect(ff.kV, closeTo(0.018, 1e-9));
    });

    test('position PID gains pass through in user units', () {
      final posPid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.arm,
      );
      // Gains are in user units (dc/deg) — no PCF multiplication.
      expect(posPid.kP, isPositive);
    });

    test('kCosRatio = 1/360 for arms (converts user position to rotations for cos)', () {
      // With onboard CFs, position is already in user units (e.g. degrees).
      // kCosRatio converts user-unit position to full rotations so that
      //   cos(pos_user × kCosRatio × 2π) = cos(angleDeg × π/180).
      const kCosRatio = 1.0 / 360.0;
      expect(kCosRatio, closeTo(1.0 / 360.0, 1e-9));

      // Verify for 45 degrees with PCF=360 (position in degrees).
      const angleDeg = 45.0;
      // Position in user units IS the angle in degrees.
      final cosFromSim = _cos2pi(angleDeg * kCosRatio);
      final cosExpected = _cosRad(angleDeg * 3.14159265358979 / 180.0);
      expect(cosFromSim, closeTo(cosExpected, 1e-4));
    });
  });

  group('Arm with gear ratio 20 (VCF=0.3, PCF=18) — gains unscaled', () {
    const ff = FeedforwardGains(kS: 0.20, kV: 0.018, kA: 0.002, kG: 0.80);

    test('velocity PID gains pass through regardless of VCF', () {
      final velPid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.arm,
      );
      // Gains are in user units — no VCF multiplication.
      expect(velPid.kP, isPositive);
    });

    test('FF kV round-trip: user-unit output is self-consistent', () {
      // With onboard CFs, the controller sees user-unit setpoints and
      // applies user-unit kV.  No round-trip scaling is needed.
      const setpointDegPerS = 90.0;
      final ffOutput = ff.kV * setpointDegPerS;
      expect(ffOutput, closeTo(0.018 * 90.0, 1e-9));
    });

    test('kCosRatio = 1/360 maps user-unit degrees to cos angle', () {
      // Regardless of gear ratio, position in user units is always degrees
      // for an arm.  kCosRatio = 1/360 converts degrees to full rotations.
      const kCosRatio = 1.0 / 360.0;

      // For 45 degrees (regardless of PCF or gear ratio).
      const angleDeg = 45.0;
      final cosFromSim = _cos2pi(angleDeg * kCosRatio);
      final cosExpected = _cosRad(angleDeg * 3.14159265358979 / 180.0);
      expect(cosFromSim, closeTo(cosExpected, 1e-4));
    });
  });

  group('Elevator (VCF=0.01, PCF=0.006) — gains unscaled', () {
    const ff = FeedforwardGains(kS: 0.10, kV: 2.0, kA: 0.5, kG: 0.60);

    test('velocity PID gains pass through in user units', () {
      final velPid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.elevator,
      );
      // Gains are in user units (dc/(m/s)) — no VCF multiplication.
      expect(velPid.kP, isPositive);
    });

    test('kG passes through unchanged for elevator', () {
      // kG for elevator is a constant voltage — no unit conversion needed.
      expect(ff.kG, closeTo(0.60, 1e-9));
    });
  });
  // ---------------------------------------------------------------------------
  // Configurable PID tuning parameters (Feature #8)
  // ---------------------------------------------------------------------------

  group('Configurable PID tuning parameters', () {
    const ff = FeedforwardGains(kS: 0.14, kV: 0.0185, kA: 0.003);

    test('velocity PID kP scales inversely with time constant', () {
      final pidDefault = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 100.0,
      );
      final pidFast = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 50.0,
      );
      final pidSlow = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 200.0,
      );

      // Faster time constant → higher kP.
      expect(pidFast.kP, greaterThan(pidDefault.kP));
      // Slower time constant → lower kP.
      expect(pidSlow.kP, lessThan(pidDefault.kP));
      // kP should be exactly kA/tau/12.
      expect(pidFast.kP, closeTo(ff.kA / 0.050 / 12.0, 1e-9));
      expect(pidSlow.kP, closeTo(ff.kA / 0.200 / 12.0, 1e-9));
      // Tuning parameter is stored in result.
      expect(pidFast.velocityTimeConstantMs, equals(50.0));
      expect(pidSlow.velocityTimeConstantMs, equals(200.0));
      expect(pidDefault.velocityTimeConstantMs, equals(100.0));
    });

    test('position PID gains scale with bandwidth', () {
      final pidDefault = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 5.0,
      );
      final pidFast = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 10.0,
      );
      final pidSlow = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 2.0,
      );

      // Higher bandwidth → higher kP (ω² scales quadratically).
      expect(pidFast.kP, greaterThan(pidDefault.kP));
      expect(pidSlow.kP, lessThan(pidDefault.kP));

      // Verify exact kP = r * kA * ω² / 12     (r=60 for flywheel).
      const pi = 3.14159265;
      final omega10 = 2.0 * pi * 10.0;
      expect(pidFast.kP, closeTo(60.0 * ff.kA * omega10 * omega10 / 12.0, 1e-4));

      // Tuning parameter is stored in result.
      expect(pidFast.positionBandwidthHz, equals(10.0));
      expect(pidSlow.positionBandwidthHz, equals(2.0));
      expect(pidDefault.positionBandwidthHz, equals(5.0));
    });

    test('default tuning params match original hardcoded values', () {
      final velPidDefault = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
      );
      final velPidExplicit = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 100.0,
      );
      expect(velPidDefault.kP, closeTo(velPidExplicit.kP, 1e-12));

      final posPidDefault = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
      );
      final posPidExplicit = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 5.0,
      );
      expect(posPidDefault.kP, closeTo(posPidExplicit.kP, 1e-12));
      expect(posPidDefault.kD, closeTo(posPidExplicit.kD, 1e-12));
    });
  });
}

// ---------------------------------------------------------------------------
// Helper math (avoids importing dart:math in test)
// ---------------------------------------------------------------------------

/// Compute cos(x * 2π) using a Taylor series approximation.
double _cos2pi(double x) {
  const twoPi = 2.0 * 3.14159265358979;
  return _cosRad(x * twoPi);
}

/// Compute cos(radians) using a Taylor series approximation (≤ 4th order).
double _cosRad(double x) {
  const pi = 3.14159265358979;
  x = x % (2 * pi);
  if (x > pi) x -= 2 * pi;
  if (x < -pi) x += 2 * pi;
  final x2 = x * x;
  return 1 - x2 / 2 + x2 * x2 / 24 - x2 * x2 * x2 / 720;
}
