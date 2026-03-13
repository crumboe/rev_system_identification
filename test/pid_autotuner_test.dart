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

    test('kP includes velocity-to-position-rate factor (r=60 for flywheel)', () {
      const bw = 5.0; // Hz
      final pid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: bw,
      );
      final omega = 2.0 * math.pi * bw;
      // For flywheel: kP = r * kA * omega^2 / nomV, where r=60
      final expected = 60.0 * ff.kA * omega * omega / 12.0;
      expect(pid.kP, closeTo(expected, 1e-6));
    });

    test('kP has r=1 for arm (velocity is time derivative of position)', () {
      const bw = 5.0;
      const armFf = FeedforwardGains(kS: 0.20, kV: 0.018, kA: 0.002, kG: 0.80);
      final pid = PidAutoTuner.tunePosition(
        ff: armFf,
        mechanismType: MechanismType.arm,
        desiredBandwidthHz: bw,
      );
      final omega = 2.0 * math.pi * bw;
      // For arm: r=1, so kP = kA * omega^2 / nomV
      final expected = armFf.kA * omega * omega / 12.0;
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
      expect(pid.warnings, isEmpty);
    });

    test('toString contains P, I, D', () {
      const pid = PidResult(kP: 0.1, kI: 0.01, kD: 0.001);
      final s = pid.toString();
      expect(s, contains('P='));
      expect(s, contains('I='));
      expect(s, contains('D='));
    });

    test('warnings round-trip through JSON', () {
      const pid = PidResult(
        kP: 0.1,
        warnings: ['Low inertia warning'],
      );
      final json = pid.toJson();
      final restored = PidResult.fromJson(json);
      expect(restored.warnings, equals(['Low inertia warning']));
    });

    test('empty warnings omitted from JSON', () {
      const pid = PidResult(kP: 0.1);
      final json = pid.toJson();
      expect(json.containsKey('warnings'), isFalse);
    });
  });

  // =========================================================================
  // Low-inertia robustness
  // =========================================================================

  group('Low-inertia robustness', () {
    // Low-inertia FF: plantTau = 0.00024/0.00492 ≈ 49 ms (< 75 ms threshold)
    const lowFf = FeedforwardGains(kS: 0.128, kV: 0.00492, kA: 0.00024);
    // Normal FF: plantTau = 0.003/0.0185 ≈ 162 ms (> 75 ms threshold)
    const normalFf = FeedforwardGains(kS: 0.14, kV: 0.0185, kA: 0.003);

    test('velocity: time constant increased for low-inertia plant', () {
      final pid = PidAutoTuner.tuneVelocity(
        ff: lowFf,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 100.0,
      );
      // plantTau ≈ 49 ms, minTau = 3 × 49 ≈ 147 ms > 100 ms
      expect(pid.velocityTimeConstantMs!, greaterThan(100.0));
      expect(pid.warnings, isNotEmpty);
      expect(pid.warnings.first, contains('Low inertia'));
    });

    test('velocity: no adjustment for normal-inertia plant', () {
      final pid = PidAutoTuner.tuneVelocity(
        ff: normalFf,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 100.0,
      );
      expect(pid.velocityTimeConstantMs, equals(100.0));
      expect(pid.warnings, isEmpty);
    });

    test('velocity: kP is smaller with low-inertia adjustment', () {
      final pidLow = PidAutoTuner.tuneVelocity(
        ff: lowFf,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 100.0,
      );
      // What kP would be without adjustment:
      final kpUnadjusted = lowFf.kA / 0.1 / 12.0;
      expect(pidLow.kP, lessThan(kpUnadjusted));
    });

    test('position: bandwidth reduced for low-inertia plant', () {
      final pid = PidAutoTuner.tunePosition(
        ff: lowFf,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 5.0,
      );
      // plantTau ≈ 49 ms → maxOmega = 1/(2×0.049) ≈ 10.25 rad/s → ≈1.6 Hz
      expect(pid.positionBandwidthHz!, lessThan(5.0));
      expect(pid.warnings, isNotEmpty);
      expect(pid.warnings.any((w) => w.contains('bandwidth')), isTrue);
    });

    test('position: damping ratio boosted for low-inertia plant', () {
      final pid = PidAutoTuner.tunePosition(
        ff: lowFf,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 5.0,
        dampingRatio: 1.0,
      );
      expect(pid.warnings.any((w) => w.contains('Damping')), isTrue);
      // kD should reflect the increased damping (higher than undamped formula).
      // With just ζ=1.0 at the reduced bandwidth, kD would be smaller.
      // The boost makes kD larger than it would be with ζ=1.0 at that ω.
      final omega = 2.0 * math.pi * pid.positionBandwidthHz!;
      final kDNoBoostedZeta = (2.0 * 1.0 * lowFf.kA * omega - lowFf.kV) / 12.0;
      // With boosted ζ, the actual kD should be larger.
      expect(pid.kD, greaterThan(kDNoBoostedZeta.clamp(0, double.infinity)));
    });

    test('position: no adjustment for normal-inertia plant', () {
      final pid = PidAutoTuner.tunePosition(
        ff: normalFf,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 5.0,
      );
      expect(pid.positionBandwidthHz, closeTo(5.0, 0.01));
      expect(pid.warnings, isEmpty);
    });

    test('position: gains are more conservative with low inertia', () {
      final pidLow = PidAutoTuner.tunePosition(
        ff: lowFf,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 5.0,
      );
      // Unadjusted kP at 5 Hz:
      final omega5 = 2.0 * math.pi * 5.0;
      final kpUnadjusted = 60.0 * lowFf.kA * omega5 * omega5 / 12.0;
      expect(pidLow.kP, lessThan(kpUnadjusted));
    });

    test('velocity: no adjustment when tau already large enough', () {
      final pid = PidAutoTuner.tuneVelocity(
        ff: lowFf,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 500.0, // much larger than 3×plantTau
      );
      expect(pid.velocityTimeConstantMs, closeTo(500.0, 0.1));
      expect(pid.warnings, isEmpty);
    });

    test('position: no adjustment when bandwidth already low enough', () {
      // maxOmega = 1/(2×0.049) ≈ 10.25 rad/s → 1.63 Hz
      // Requesting 1 Hz is already below the cap.
      final pid = PidAutoTuner.tunePosition(
        ff: lowFf,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 1.0,
      );
      // Bandwidth should not be reduced (1.0 < 1.63).
      expect(pid.positionBandwidthHz!, closeTo(1.0, 0.1));
      // But damping should still be boosted (plantTau < threshold).
      expect(pid.warnings.any((w) => w.contains('Damping')), isTrue);
    });
  });
}
