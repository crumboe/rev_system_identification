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
    // Plant tau = 0.003 / 0.0185 ≈ 162 ms.
    final plantTauMs = (ff.kA / ff.kV) * 1000.0;

    test('kP is kA / tau / nomV when tau >= plant tau', () {
      // Request 200 ms, which is above the plant tau (~162 ms).
      const tau = 200.0;
      final pid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: tau,
      );
      final expected = ff.kA / (tau / 1000.0) / 12.0;
      expect(pid.kP, closeTo(expected, 1e-9));
    });

    test('tau is clamped to plant tau when requested is smaller', () {
      // Request 100 ms, plant tau is ~162 ms → clamp to 162.
      final pid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 100.0,
      );
      expect(pid.velocityTimeConstantMs!, closeTo(plantTauMs, 0.1));
      expect(pid.warnings, isNotEmpty);
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
      // Request a tau well above plant tau so no clamping occurs.
      final pid = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 250.0,
      );
      expect(pid.velocityTimeConstantMs, equals(250.0));
      expect(pid.positionBandwidthHz, isNull);
    });

    test('smaller time constant gives larger kP (both above plant tau)', () {
      // Both requested values are above plant tau, no clamping.
      final pidFast = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 200.0,
      );
      final pidSlow = PidAutoTuner.tuneVelocity(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 500.0,
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
    // plantTau = 0.003/0.0185 ≈ 162 ms
    // maxOmega = 3.0 / 0.162 ≈ 18.5 rad/s ≈ 2.94 Hz
    final plantTau = ff.kA / ff.kV;
    final maxOmega = 3.0 / plantTau;
    final maxBwHz = maxOmega / (2.0 * math.pi);

    test('bandwidth is capped by omega*tau <= 2 for flywheel', () {
      // Request 5 Hz, plant tau ≈ 162 ms → cap to ~1.96 Hz
      final pid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 5.0,
        transportDelaySec: 0, // isolate bandwidth cap
      );
      expect(pid.positionBandwidthHz!, closeTo(maxBwHz, 0.1));
      expect(pid.warnings.any((w) => w.contains('bandwidth')), isTrue);
    });

    test('kP formula correct at capped bandwidth (r=60 flywheel)', () {
      final pid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 5.0,
        transportDelaySec: 0, // isolate bandwidth cap
      );
      final omega = 2.0 * math.pi * pid.positionBandwidthHz!;
      // kP = r * kA * omega^2 / nomV, damping is still 1.0 since no
      // low-inertia boost (plantTau > 75ms) and delay = 0.
      final expected = 60.0 * ff.kA * omega * omega / 12.0;
      expect(pid.kP, closeTo(expected, 1e-6));
    });

    test('kP has r=1 for arm (velocity is time derivative of position)', () {
      // Use a small bandwidth that won't trigger the cap.
      const armFf = FeedforwardGains(kS: 0.20, kV: 0.018, kA: 0.002, kG: 0.80);
      const bw = 1.0; // Hz, well below any cap
      final pid = PidAutoTuner.tunePosition(
        ff: armFf,
        mechanismType: MechanismType.arm,
        desiredBandwidthHz: bw,
        transportDelaySec: 0,
      );
      final omega = 2.0 * math.pi * bw;
      final expected = armFf.kA * omega * omega / 12.0;
      expect(pid.kP, closeTo(expected, 1e-9));
    });

    test('delay compensation increases damping ratio', () {
      // Use a larger delay to verify the compensation mechanism works.
      final pidNoDelay = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 1.5,
        transportDelaySec: 0,
      );
      final pidDelay = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 1.5,
        transportDelaySec: 0.010,
      );
      // With delay, kD should be larger (higher effective zeta).
      expect(pidDelay.kD, greaterThan(pidNoDelay.kD));
      expect(pidDelay.warnings.any((w) => w.contains('delay')), isTrue);
    });

    test('kI is zero', () {
      final pid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
      );
      expect(pid.kI, equals(0.0));
    });

    test('no cap when requested bandwidth is below limit', () {
      final pid = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 1.0,
        transportDelaySec: 0,
      );
      expect(pid.positionBandwidthHz!, closeTo(1.0, 0.01));
    });

    test('higher bandwidth gives larger kP (both below cap)', () {
      final pidNarrow = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 0.5,
        transportDelaySec: 0,
      );
      final pidWide = PidAutoTuner.tunePosition(
        ff: ff,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 1.5,
        transportDelaySec: 0,
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
        desiredTimeConstantMs: 10.0, // well below plant tau (~49 ms)
      );
      // plantTau ≈ 49 ms. First clamp to plantTau, then 3× for low inertia = 147 ms.
      expect(pid.velocityTimeConstantMs!, greaterThan(100.0));
      expect(pid.warnings, isNotEmpty);
      expect(pid.warnings.any((w) => w.contains('Low inertia')), isTrue);
    });

    test('velocity: normal plant still clamped to plant tau', () {
      // normalFf: plantTau ≈ 162 ms. Request 100 ms → clamp to 162 ms.
      final pid = PidAutoTuner.tuneVelocity(
        ff: normalFf,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 100.0,
      );
      final plantTau = normalFf.kA / normalFf.kV;
      expect(pid.velocityTimeConstantMs!, closeTo(plantTau * 1000, 0.1));
      expect(pid.warnings, isNotEmpty);
    });

    test('velocity: no adjustment when tau already large enough', () {
      // Request well above plant tau.
      final pid = PidAutoTuner.tuneVelocity(
        ff: normalFf,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 500.0,
      );
      expect(pid.velocityTimeConstantMs, closeTo(500.0, 0.1));
      expect(pid.warnings, isEmpty);
    });

    test('velocity: kP is smaller with low-inertia adjustment', () {
      final pidLow = PidAutoTuner.tuneVelocity(
        ff: lowFf,
        mechanismType: MechanismType.flywheel,
        desiredTimeConstantMs: 10.0,
      );
      // What kP would be without adjustment:
      final kpUnadjusted = lowFf.kA / 0.01 / 12.0;
      expect(pidLow.kP, lessThan(kpUnadjusted));
    });

    test('position: bandwidth reduced for low-inertia plant', () {
      final pid = PidAutoTuner.tunePosition(
        ff: lowFf,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 50.0, // very high to guarantee cap triggers
        transportDelaySec: 0,
      );
      // plantTau ≈ 49 ms → maxOmega = 2.0/0.049 ≈ 40.8 rad/s → ≈6.5 Hz
      expect(pid.positionBandwidthHz!, lessThan(50.0));
      expect(pid.warnings, isNotEmpty);
      expect(pid.warnings.any((w) => w.contains('bandwidth')), isTrue);
    });

    test('position: damping ratio boosted for low-inertia plant', () {
      final pid = PidAutoTuner.tunePosition(
        ff: lowFf,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 5.0,
        dampingRatio: 1.0,
        transportDelaySec: 0, // isolate low-inertia effect
      );
      expect(pid.warnings.any((w) => w.contains('Low inertia')), isTrue);
      // kD should reflect the increased damping.
      final omega = 2.0 * math.pi * pid.positionBandwidthHz!;
      // With kV/kA FF active, kD = 2·ζ·kA·ω / V_nom (no kV subtraction).
      // Without the low-inertia boost, ζ = 1.0:
      final kDNoBoostedZeta = 2.0 * 1.0 * lowFf.kA * omega / 12.0;
      expect(pid.kD, greaterThan(kDNoBoostedZeta.clamp(0, double.infinity)));
    });

    test('position: normal-inertia plant is still bandwidth-capped', () {
      // normalFf: plantTau ≈ 162 ms → maxBw = 3.0/(2π×0.162) ≈ 2.94 Hz
      final pid = PidAutoTuner.tunePosition(
        ff: normalFf,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 5.0,
        transportDelaySec: 0,
      );
      expect(pid.positionBandwidthHz!, lessThan(5.0));
      expect(pid.warnings.any((w) => w.contains('bandwidth')), isTrue);
    });

    test('position: gains are more conservative with low inertia', () {
      final pidLow = PidAutoTuner.tunePosition(
        ff: lowFf,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 50.0,
        transportDelaySec: 0,
      );
      // Unadjusted kP at 50 Hz:
      final omega50 = 2.0 * math.pi * 50.0;
      final kpUnadjusted = 60.0 * lowFf.kA * omega50 * omega50 / 12.0;
      expect(pidLow.kP, lessThan(kpUnadjusted));
    });

    test('position: no bandwidth reduction when already low enough', () {
      // plantTau ≈ 49 ms → maxBw ≈ 6.5 Hz. Request 1 Hz → no cap.
      final pid = PidAutoTuner.tunePosition(
        ff: lowFf,
        mechanismType: MechanismType.flywheel,
        desiredBandwidthHz: 1.0,
        transportDelaySec: 0,
      );
      expect(pid.positionBandwidthHz!, closeTo(1.0, 0.1));
      // But damping should still be boosted (plantTau < threshold).
      expect(pid.warnings.any((w) => w.contains('Low inertia')), isTrue);
    });
  });
}
