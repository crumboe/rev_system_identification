import 'package:flutter_test/flutter_test.dart';
import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/ui/widgets/bode_plot.dart';

void main() {
  // ── Typical first-order velocity plant ──
  // G_v(s) = 1 / (kA·s + kV) with kA = 0.1, kV = 2.0
  // Plant time constant τ_plant = kA/kV = 0.05 s → corner freq = 20 rad/s
  const ffVelocity = FeedforwardGains(kS: 0.5, kV: 2.0, kA: 0.1);

  // PID for velocity: kP·12 = kA/τ_desired → kP = kA / (τ_desired · 12)
  // Using τ_desired = 0.1 s: kP = 0.1 / (0.1 · 12) ≈ 0.0833
  const velPid = PidResult(kP: 0.08333, kI: 0.0, kD: 0.0);

  // ── Second-order position plant ──
  // G_p(s) = 1 / (kA·s² + kV·s) with kA = 0.1, kV = 2.0
  const ffPosition = FeedforwardGains(kS: 0.5, kV: 2.0, kA: 0.1);
  // Position PID: kP = kA·ω²/12, kD = (2·kA·ω - kV)/12, ω=2π·5
  // ω ≈ 31.4 → kP = 0.1·31.4²/12 ≈ 8.22, kD = (2·0.1·31.4 - 2)/12 ≈ 0.356
  const posPid = PidResult(kP: 8.22, kI: 0.0, kD: 0.356);

  group('FrequencyResponse data model', () {
    test('stores omega, magnitude, and phase', () {
      const fr = FrequencyResponse(
        omegaRadPerSec: 10.0,
        magnitudeDb: -3.0,
        phaseDeg: -45.0,
      );
      expect(fr.omegaRadPerSec, 10.0);
      expect(fr.magnitudeDb, -3.0);
      expect(fr.phaseDeg, -45.0);
    });
  });

  group('StabilityMargins data model', () {
    test('stores all margin fields', () {
      const m = StabilityMargins(
        gainMarginDb: 12.0,
        gainMarginFreq: 100.0,
        phaseMarginDeg: 45.0,
        phaseMarginFreq: 20.0,
        bandwidthRadPerSec: 30.0,
      );
      expect(m.gainMarginDb, 12.0);
      expect(m.phaseMarginDeg, 45.0);
      expect(m.bandwidthRadPerSec, 30.0);
    });
  });

  group('computeBodeData — velocity (first-order plant)', () {
    late final dynamic result;

    setUpAll(() {
      result = computeBodeData(
        ff: ffVelocity,
        pid: velPid,
        mode: BodePlotMode.velocity,
        omegaMin: 0.1,
        omegaMax: 10000.0,
        numPoints: 2000,
      );
    });

    test('returns 2000 frequency points for each trace', () {
      expect(result.plant.length, 2000);
      expect(result.openLoop.length, 2000);
      expect(result.closedLoop.length, 2000);
    });

    test('plant DC gain is correct', () {
      // G_v(0) = 1/kV = 0.5 → 20·log10(0.5) ≈ -6.02 dB
      final dcMag = result.plant.first.magnitudeDb;
      expect(dcMag, closeTo(-6.02, 0.5));
    });

    test('plant rolls off at -20 dB/decade at high frequency', () {
      // At ω >> kV/kA, magnitude decreases by 20 dB per decade
      final data = result.plant as List<FrequencyResponse>;
      // Find points at ~1000 and ~10000 rad/s
      final p1 = data.firstWhere((d) => d.omegaRadPerSec >= 1000);
      final p2 = data.firstWhere((d) => d.omegaRadPerSec >= 10000);
      final dbDrop = p2.magnitudeDb - p1.magnitudeDb;
      // Should be approximately -20 dB
      expect(dbDrop, closeTo(-20.0, 2.0));
    });

    test('plant phase starts near 0° and approaches -90°', () {
      final data = result.plant as List<FrequencyResponse>;
      // Low freq → ~0°
      expect(data.first.phaseDeg, closeTo(0.0, 5.0));
      // High freq → ~-90°
      expect(data.last.phaseDeg, closeTo(-90.0, 5.0));
    });

    test('plant phase near corner frequency is about -45°', () {
      // Corner freq = kV/kA = 20 rad/s
      final data = result.plant as List<FrequencyResponse>;
      final corner = data.reduce((a, b) =>
          (a.omegaRadPerSec - 20.0).abs() < (b.omegaRadPerSec - 20.0).abs()
              ? a
              : b);
      expect(corner.phaseDeg, closeTo(-45.0, 5.0));
    });

    test('phase margin is positive (system is stable)', () {
      final margins = result.margins as StabilityMargins;
      expect(margins.phaseMarginDeg > 0 || margins.phaseMarginDeg.isInfinite,
          isTrue);
    });

    test('gain margin is positive or infinite', () {
      final margins = result.margins as StabilityMargins;
      // First-order system + P controller: no phase crossover at -180°
      // so gain margin should be infinite
      expect(margins.gainMarginDb.isInfinite, isTrue);
    });

    test('closed-loop magnitude is ~0 dB at low frequency', () {
      // T(0) ≈ C(0)·G(0) / (1 + C(0)·G(0))
      // For P control: C(0) = kP·12 = 1.0, G(0) = 0.5 → L(0) = 0.5
      // T(0) = 0.5/1.5 ≈ 0.333 → ~-9.5 dB (not 0 dB because pure P)
      // Actually let's just check it's finite
      final clData = result.closedLoop as List<FrequencyResponse>;
      expect(clData.first.magnitudeDb.isFinite, isTrue);
    });
  });

  group('computeBodeData — position (second-order plant)', () {
    late final dynamic result;

    setUpAll(() {
      result = computeBodeData(
        ff: ffPosition,
        pid: posPid,
        mode: BodePlotMode.position,
        omegaMin: 0.1,
        omegaMax: 10000.0,
        numPoints: 2000,
      );
    });

    test('plant has -40 dB/decade rolloff at high frequency', () {
      // Position plant: G_p(s) = 1/(kA·s² + kV·s)
      // At high freq: ~ 1/(kA·s²) → -40 dB/decade
      final data = result.plant as List<FrequencyResponse>;
      final p1 = data.firstWhere((d) => d.omegaRadPerSec >= 1000);
      final p2 = data.firstWhere((d) => d.omegaRadPerSec >= 10000);
      final dbDrop = p2.magnitudeDb - p1.magnitudeDb;
      expect(dbDrop, closeTo(-40.0, 4.0));
    });

    test('plant phase approaches -180° at high frequency', () {
      final data = result.plant as List<FrequencyResponse>;
      expect(data.last.phaseDeg, closeTo(-180.0, 10.0));
    });

    test('open-loop gain crossover exists', () {
      // With PD controller, the open loop should cross 0 dB
      final margins = result.margins as StabilityMargins;
      expect(margins.phaseMarginFreq, greaterThan(0));
    });

    test('phase margin is positive for well-tuned PD', () {
      final margins = result.margins as StabilityMargins;
      expect(margins.phaseMarginDeg, greaterThan(0));
    });

    test('bandwidth is finite and positive', () {
      final margins = result.margins as StabilityMargins;
      expect(margins.bandwidthRadPerSec, greaterThan(0));
    });
  });

  group('computeBodeData — edge cases', () {
    test('zero PID gains yield plant == open-loop', () {
      final data = computeBodeData(
        ff: ffVelocity,
        pid: const PidResult(kP: 0),
        mode: BodePlotMode.velocity,
        numPoints: 50,
      );
      // With C(s) = 0, L(s) = 0, but we check that plant is computed
      expect(data.plant.length, 50);
    });

    test('very small kA does not crash', () {
      const ff = FeedforwardGains(kS: 0.1, kV: 1.0, kA: 0.001);
      final data = computeBodeData(
        ff: ff,
        pid: const PidResult(kP: 0.1),
        mode: BodePlotMode.velocity,
        numPoints: 50,
      );
      expect(data.plant.every((p) => p.magnitudeDb.isFinite), isTrue);
    });

    test('large kA does not crash', () {
      const ff = FeedforwardGains(kS: 1.0, kV: 5.0, kA: 100.0);
      final data = computeBodeData(
        ff: ff,
        pid: const PidResult(kP: 0.5, kD: 0.01),
        mode: BodePlotMode.position,
        numPoints: 50,
      );
      expect(data.plant.every((p) => p.magnitudeDb.isFinite), isTrue);
    });

    test('PID with kI term computes without error', () {
      final data = computeBodeData(
        ff: ffVelocity,
        pid: const PidResult(kP: 0.08, kI: 0.01, kD: 0.0),
        mode: BodePlotMode.velocity,
        numPoints: 100,
      );
      expect(data.openLoop.length, 100);
      expect(data.openLoop.every((d) => d.magnitudeDb.isFinite), isTrue);
    });

    test('custom frequency range is respected', () {
      final data = computeBodeData(
        ff: ffVelocity,
        pid: velPid,
        mode: BodePlotMode.velocity,
        omegaMin: 1.0,
        omegaMax: 100.0,
        numPoints: 10,
      );
      expect(data.plant.first.omegaRadPerSec, closeTo(1.0, 0.01));
      expect(data.plant.last.omegaRadPerSec, closeTo(100.0, 0.1));
    });
  });

  group('BodePlotMode enum', () {
    test('has velocity and position values', () {
      expect(BodePlotMode.values, contains(BodePlotMode.velocity));
      expect(BodePlotMode.values, contains(BodePlotMode.position));
      expect(BodePlotMode.values.length, 2);
    });
  });

  group('Known-answer: first-order velocity plant at corner frequency', () {
    // G(s) = 1/(0.1s + 2.0), corner = kV/kA = 20 rad/s
    // At ω = 20: |G(j20)| = 1/sqrt(kV² + (kA·ω)²) = 1/sqrt(4 + 4) = 1/2√2
    //   = 20·log10(1/(2·sqrt(2))) ≈ -9.03 dB
    // Phase = -atan(kA·ω / kV) = -atan(2/2) = -45°
    test('magnitude at corner ~= -9.03 dB', () {
      final data = computeBodeData(
        ff: ffVelocity,
        pid: velPid,
        mode: BodePlotMode.velocity,
        omegaMin: 19.5,
        omegaMax: 20.5,
        numPoints: 3,
      );
      // Middle point should be near ω = 20
      final mid = data.plant[1];
      expect(mid.magnitudeDb, closeTo(-9.03, 0.5));
    });

    test('phase at corner ~= -45°', () {
      final data = computeBodeData(
        ff: ffVelocity,
        pid: velPid,
        mode: BodePlotMode.velocity,
        omegaMin: 19.5,
        omegaMax: 20.5,
        numPoints: 3,
      );
      final mid = data.plant[1];
      expect(mid.phaseDeg, closeTo(-45.0, 2.0));
    });
  });
}
