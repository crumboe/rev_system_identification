/// Supplemental PID autotuner tests: covers tuneVelocity and tunePosition
/// and verifies gain scaling / relationships.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/mechanisms/mechanism.dart';
import 'package:rev_system_identification/sysid/pid_autotuner.dart';

void main() {
  // =========================================================================
  // Velocity tuning
  // =========================================================================

  group('PidAutoTuner.tuneVelocity', () {
    const ff = FeedforwardGains(kS: 0.14, kV: 0.0185, kA: 0.003);

    test('kP is kA / tau / nomV', () {
      const tau = 100.0; // ms
      final pid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: tau,
      );
      final expected = ff.kA / (tau / 1000.0) / 12.0;
      expect(pid.kP, closeTo(expected, 1e-9));
    });

    test('kI and kD are zero', () {
      final pid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
      );
      expect(pid.kI, equals(0.0));
      expect(pid.kD, equals(0.0));
    });

    test('stores velocityTimeConstantMs in result', () {
      final pid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 150.0,
      );
      expect(pid.velocityTimeConstantMs, equals(150.0));
      expect(pid.positionBandwidthHz, isNull);
    });

    test('smaller time constant gives larger kP', () {
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
      expect(pidFast.kP, greaterThan(pidSlow.kP));
    });

    test('zero kA in feedforward produces zero kP', () {
      const zeroFf = FeedforwardGains(kS: 0.14, kV: 0.0185, kA: 0.0);
      final pid = PidAutoTuner.tuneVelocity(
        ff: zeroFf,
        mechanismType: MechanismType.flywheel,
      );
      expect(pid.kP, equals(0.0));
    });
  });

  // =========================================================================
  // Position tuning
  // =========================================================================

  group('PidAutoTuner.tunePosition', () {
    const ff = FeedforwardGains(kS: 0.14, kV: 0.0185, kA: 0.003);

    test('kP is 60 * kA * omega^2 / nomV', () {
      const bw = 5.0; // Hz
      final pid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: bw,
      );
      final omega = 2.0 * math.pi * bw;
      final expected = 60.0 * ff.kA * omega * omega / 12.0;
      expect(pid.kP, closeTo(expected, 1e-9));
    });

    test('kD is (2*kA*omega - kV) / nomV, clamped >= 0', () {
      const bw = 5.0;
      final pid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: bw,
      );
      final omega = 2.0 * math.pi * bw;
      final kDVolts = 2.0 * ff.kA * omega - ff.kV;
      final expected = kDVolts > 0 ? kDVolts / 12.0 : 0.0;
      expect(pid.kD, closeTo(expected, 1e-9));
    });

    test('kI is zero', () {
      final pid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
      );
      expect(pid.kI, equals(0.0));
    });

    test('stores positionBandwidthHz in result', () {
      final pid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 8.0,
      );
      expect(pid.positionBandwidthHz, equals(8.0));
      expect(pid.velocityTimeConstantMs, isNull);
    });

    test('higher bandwidth gives larger kP', () {
      final pidNarrow = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 3.0,
      );
      final pidWide = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 10.0,
      );
      expect(pidWide.kP, greaterThan(pidNarrow.kP));
    });
  });

  // =========================================================================
  // PidResult model
  // =========================================================================

  group('PidResult model', () {
    test('default values are zero', () {
      const pid = PidResult();
      expect(pid.kP, equals(0.0));
      expect(pid.kI, equals(0.0));
      expect(pid.kD, equals(0.0));
    });

    test('toString contains P, I, D', () {
      const pid = PidResult(kP: 0.1, kI: 0.01, kD: 0.001);
      final s = pid.toString();
      expect(s, contains('P='));
      expect(s, contains('I='));
      expect(s, contains('D='));
    });
  });
}
