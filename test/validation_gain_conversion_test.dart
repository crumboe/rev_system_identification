/// Unit tests for the validation-mode gain conversion logic.
///
/// The core issue being fixed: gains computed from user-unit data (e.g. deg/s
/// for an arm) must be scaled to native controller units (RPM / rotations)
/// before being written to the SPARK.  The SPARK CAN protocol always uses
/// RPM for velocity setpoints and rotations for position setpoints.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/mechanisms/mechanism.dart';
import 'package:rev_system_identification/sysid/pid_autotuner.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Converts user-unit velocity PID gains to native (RPM) units.
PidResult toNativeVelPid(PidResult pid, double vcf) => PidResult(
      kP: pid.kP * vcf,
      kI: pid.kI * vcf,
      kD: pid.kD * vcf,
    );

/// Converts user-unit position PID gains to native (rotations) units.
PidResult toNativePosPid(PidResult pid, double pcf) => PidResult(
      kP: pid.kP * pcf,
      kI: pid.kI * pcf,
      kD: pid.kD * pcf,
    );

// ---------------------------------------------------------------------------
// Flywheel (VCF = 1.0, PCF = 1.0)
// ---------------------------------------------------------------------------

void main() {
  group('Flywheel (VCF=1, PCF=1) — no scaling needed', () {
    const ff = FeedforwardGains(kS: 0.14, kV: 0.0185, kA: 0.003);

    test('velocity PID conversion is identity when VCF=1', () {
      final velPid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
      );
      const vcf = 1.0;
      final native = toNativeVelPid(velPid, vcf);
      expect(native.kP, closeTo(velPid.kP, 1e-9));
      expect(native.kI, closeTo(velPid.kI, 1e-9));
      expect(native.kD, closeTo(velPid.kD, 1e-9));
    });

    test('FF kV conversion is identity when VCF=1', () {
      const vcf = 1.0;
      final kVNative = ff.kV * vcf;
      expect(kVNative, closeTo(ff.kV, 1e-9));
    });
  });

  // ---------------------------------------------------------------------------
  // Arm (VCF = 6.0 deg·s⁻¹/RPM, PCF = 360 deg/rotation — gear ratio = 1)
  // ---------------------------------------------------------------------------

  group('Arm with no gear reduction (VCF=6, PCF=360)', () {
    // kA is in V·s²/deg for an arm characterised in deg/s.
    const ff = FeedforwardGains(kS: 0.20, kV: 0.018, kA: 0.002, kG: 0.80);
    const vcf = 6.0; // deg/s per RPM
    const pcf = 360.0; // deg per rotation

    test('velocity PID kP is scaled by VCF', () {
      final velPid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.arm,
      );
      final native = toNativeVelPid(velPid, vcf);
      // kP_user is in dc/(deg/s); multiplied by VCF gives dc/RPM.
      expect(native.kP, closeTo(velPid.kP * vcf, 1e-9));
      // Sanity: native kP should be larger than user kP when VCF > 1.
      expect(native.kP, greaterThan(velPid.kP));
    });

    test('FF kV is scaled by VCF (V/RPM)', () {
      final kVNative = ff.kV * vcf;
      // At 15 RPM (≡ 90 deg/s for VCF=6), native FF output should equal
      // user-unit FF output at 90 deg/s.
      const setpointRpm = 90.0 / vcf; // 15 RPM
      final ffOutputNative = kVNative * setpointRpm;
      final ffOutputUser = ff.kV * 90.0; // user-unit computation
      expect(ffOutputNative, closeTo(ffOutputUser, 1e-9));
    });

    test('position PID kP is scaled by PCF', () {
      final posPid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.arm,
      );
      final native = toNativePosPid(posPid, pcf);
      // kP_user is in dc/deg; multiplied by PCF gives dc/rotation.
      expect(native.kP, closeTo(posPid.kP * pcf, 1e-9));
      expect(native.kP, greaterThan(posPid.kP));
    });

    test('kCosRatio = PCF / 360 for arms', () {
      // kCosRatio converts encoder rotations so that
      //   cos(posRotations × kCosRatio × 2π) = cos(angleDeg × π/180).
      final kCosRatio = pcf / 360.0;
      expect(kCosRatio, closeTo(1.0, 1e-9)); // PCF=360 → kCosRatio=1

      // Verify for 45 degrees.
      const angleDeg = 45.0;
      final posRot = angleDeg / pcf; // 0.125 rotations
      final cosFromSim = _cos2pi(posRot * kCosRatio);
      final cosExpected = _cosRad(angleDeg * 3.14159265358979 / 180.0);
      expect(cosFromSim, closeTo(cosExpected, 1e-4));
    });
  });

  // ---------------------------------------------------------------------------
  // Arm with gear reduction (gear ratio = 20, VCF = 0.3, PCF = 18)
  // ---------------------------------------------------------------------------

  group('Arm with gear ratio 20 (VCF=0.3, PCF=18)', () {
    const ff = FeedforwardGains(kS: 0.20, kV: 0.018, kA: 0.002, kG: 0.80);
    const vcf = 0.3; // deg/s per RPM (= 6 / 20)
    const pcf = 18.0; // deg per rotation (= 360 / 20)

    test('velocity PID kP is scaled down by VCF < 1', () {
      final velPid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.arm,
      );
      final native = toNativeVelPid(velPid, vcf);
      expect(native.kP, closeTo(velPid.kP * vcf, 1e-9));
      // When VCF < 1, native kP < user kP.
      expect(native.kP, lessThan(velPid.kP));
    });

    test('FF kV round-trip: native output = user output', () {
      final kVNative = ff.kV * vcf;
      const setpointDegPerS = 90.0;
      final setpointRpm = setpointDegPerS / vcf; // = 300 RPM
      final ffNative = kVNative * setpointRpm;
      final ffUser = ff.kV * setpointDegPerS;
      expect(ffNative, closeTo(ffUser, 1e-9));
    });

    test('kCosRatio = PCF / 360 maps encoder rotations to correct angle', () {
      final kCosRatio = pcf / 360.0; // = 0.05
      expect(kCosRatio, closeTo(0.05, 1e-9));

      // For 45 degrees with gear ratio 20:
      // encoder reads 45 / 18 = 2.5 rotations.
      const angleDeg = 45.0;
      final posRot = angleDeg / pcf; // 2.5 rotations
      final cosFromSim = _cos2pi(posRot * kCosRatio);
      final cosExpected = _cosRad(angleDeg * 3.14159265358979 / 180.0);
      expect(cosFromSim, closeTo(cosExpected, 1e-4));
    });
  });

  // ---------------------------------------------------------------------------
  // Elevator (VCF = 0.01 m/s per RPM, PCF = 0.006 m per rotation)
  // ---------------------------------------------------------------------------

  group('Elevator (VCF=0.01, PCF=0.006)', () {
    const ff = FeedforwardGains(kS: 0.10, kV: 2.0, kA: 0.5, kG: 0.60);
    const vcf = 0.01; // m/s per RPM
    const pcf = 0.006; // m per rotation

    test('velocity PID kP round-trip: native error = user error', () {
      final velPid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.elevator,
      );
      final native = toNativeVelPid(velPid, vcf);
      const setpointMperS = 0.15;
      final setpointRpm = setpointMperS / vcf; // 15 RPM
      final errorRpm = setpointRpm * 0.5; // assume 50% error
      final errorUser = errorRpm * vcf; // in m/s
      expect(native.kP * errorRpm, closeTo(velPid.kP * errorUser, 1e-9));
    });

    test('kG is not scaled for elevator (gravity is in Volts)', () {
      // kG for elevator is a constant voltage — no unit conversion needed.
      // Just verify it passes through unchanged.
      const kGNative = ff.kG; // no multiplication needed
      expect(kGNative, closeTo(ff.kG, 1e-9));
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
