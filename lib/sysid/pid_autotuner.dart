/// PID auto-tuner: computes PID gains from the identified feedforward model.
///
/// Uses the plant model V = kS·sign(ω) + kV·ω + kA·α to derive PID gains
/// for closed-loop position or velocity control on the SPARK controller.
library;

import 'dart:math' as math;

import '../data/test_data.dart';
import '../mechanisms/mechanism.dart';

/// Computes PID gains from identified feedforward constants.
class PidAutoTuner {
  /// Plant time constant threshold (seconds).  Below this, the system has very
  /// low inertia and gains are automatically de-rated for robustness against
  /// nonlinearities like backlash and stiction.
  static const _lowInertiaTauThreshold = 0.075; // 75 ms

  /// Default transport delay (seconds) for on-controller PID running at
  /// 1 kHz: sensor-to-actuation pipeline (~1 ms) + filtering (~1 ms).
  static const defaultTransportDelaySec = 0.002; // 2 ms

  /// Maximum ω·τ_plant product for position control.  With kV/kA
  /// feedforward active (firmware ≥25.0) the plant is largely linearised,
  /// so the cap is less critical — but still limits bandwidth to avoid
  /// actuator saturation and amplifying stiction/backlash.
  static const _maxOmegaTauProduct = 3.0;

  /// SPARK controller internal loop period (seconds).
  static const _sparkControlPeriodSec = 0.001; // 1 ms

  /// Multiplier for D-filter cutoff relative to closed-loop bandwidth.
  /// The filter cutoff is set at N× the bandwidth to reject noise while
  /// adding minimal phase lag at frequencies the controller cares about.
  static const _dFilterBandwidthMultiplier = 8.0;

  /// Robust velocity tuning uses a much slower integral loop than the
  /// proportional loop so load/gravity mismatch is corrected gradually
  /// instead of injecting overshoot.
  static double robustVelocityIntegralTimeSec({
    required double closedLoopTauSec,
    required double plantTauSec,
  }) {
    return math.max(12.0 * closedLoopTauSec, 30.0 * plantTauSec);
  }

  /// Robust position tuning uses a slow integral loop relative to both the
  /// commanded bandwidth and the plant time constant to avoid long tail
  /// settling from windup-like behavior.
  static double robustPositionIntegralTimeSec({
    required double omegaRadPerSec,
    required double plantTauSec,
  }) {
    if (omegaRadPerSec <= 0) return 20.0 * plantTauSec;
    return math.max(8.0 / omegaRadPerSec, 20.0 * plantTauSec);
  }

  /// Compute plant-optimal default tuning parameters from feedforward gains.
  ///
  /// Returns (velocityTimeConstantMs, positionBandwidthHz) representing the
  /// fastest safe values that won't trigger any internal clamping:
  ///   - Velocity τ = τ_plant (or 3×τ_plant for low-inertia)
  ///   - Position BW = ω_max / 2π  where ω_max = [_maxOmegaTauProduct] / τ_plant
  static (double tauMs, double bwHz) optimalDefaults(FeedforwardGains ff) {
    if (ff.kA <= 0 || ff.kV <= 0) return (100.0, 5.0);

    final plantTau = ff.kA / ff.kV; // seconds

    // Velocity: fastest τ_cl the plant can track linearly.
    double tauMs = plantTau * 1000.0;
    if (plantTau < _lowInertiaTauThreshold) {
      tauMs = plantTau * 3.0 * 1000.0; // 3× de-rating for low inertia
    }
    tauMs = tauMs.clamp(20.0, 500.0);

    // Position: fastest bandwidth satisfying ω·τ ≤ _maxOmegaTauProduct.
    double bwHz = _maxOmegaTauProduct / (2.0 * math.pi * plantTau);
    bwHz = bwHz.clamp(1.0, 20.0);

    return (tauMs, bwHz);
  }

  /// Compute PID gains for velocity control.
  ///
  /// The plant transfer function from voltage to velocity is approximately:
  ///   G(s) = 1 / (kA·s + kV)
  ///
  /// We design a PI controller for velocity using model-inversion:
  ///   kP ≈ kA / (desired time constant)
  ///   kI = 0 (usually not needed; risks windup)
  ///   kF = kV (feedforward term)
  ///
  /// [controlPeriodMs] is the SPARK controller's internal loop period (default 1ms).
  static PidResult tuneVelocity({
    required FeedforwardGains ff,
    required MechanismType mechanismType,
    double desiredTimeConstantMs = 100.0,
    double controlPeriodMs = 1.0,
    double transportDelaySec = defaultTransportDelaySec,
  }) {
    const nominalVoltage = 12.0;

    var tau = desiredTimeConstantMs / 1000.0; // desired time constant
    final warnings = <String>[];

    if (ff.kA > 0 && ff.kV > 0) {
      final plantTau = ff.kA / ff.kV;

      // Ensure the closed-loop time constant is at least as large as the
      // plant time constant.  Commanding faster than the plant can respond
      // linearly causes actuator saturation and amplifies nonlinearities.
      final minTau = plantTau;
      if (tau < minTau) {
        final oldTauMs = tau * 1000.0;
        tau = minTau;
        warnings.add(
          'Plant \u03c4 = ${(plantTau * 1000).toStringAsFixed(1)} ms. '
          'Velocity time constant increased from '
          '${oldTauMs.toStringAsFixed(0)} ms to '
          '${(tau * 1000).toStringAsFixed(0)} ms (cannot be faster '
          'than the plant).');
      }

      // Additional low-inertia de-rating: when the plant time constant is
      // very short, nonlinearities (stiction, backlash) dominate.
      if (plantTau < _lowInertiaTauThreshold) {
        final robustMin = plantTau * 3.0;
        if (tau < robustMin) {
          final oldTauMs = tau * 1000.0;
          tau = robustMin;
          warnings.add(
            'Low inertia detected (plant \u03c4 = '
            '${(plantTau * 1000).toStringAsFixed(1)} ms). '
            'Time constant increased from '
            '${oldTauMs.toStringAsFixed(0)} ms to '
            '${(tau * 1000).toStringAsFixed(0)} ms for robustness.');
        }
      }
    }

    final kP = ff.kA > 0 ? (ff.kA / tau) / nominalVoltage : 0.0;
    const kI = 0.0;
    const kD = 0.0;

    return PidResult(
      kP: kP,
      kI: kI,
      kD: kD,
      velocityTimeConstantMs: tau * 1000.0,
      warnings: warnings,
    );
  }

  /// Compute PID gains for position control.
  ///
  /// Uses pole placement for a second-order system.  With firmware ≥25.0
  /// the SPARK applies kV and kA feedforward in position mode, so the
  /// effective plant seen by the PID is a near-pure double integrator:
  ///   G_eff(s) ≈ 1 / (r·kA·s²)
  ///
  /// The raw plant from voltage to position is:
  ///   G(s) = 1 / (r·kA·s² + r·kV·s)
  /// but kV·measured_velocity feedforward cancels the kV·s damping term.
  ///
  /// `r` is the ratio between the velocity user unit and the position
  /// rate (d(pos_user)/dt).  For mechanisms where velocity is already the
  /// time-derivative of position (arm: deg/s↔deg, elevator: m/s↔m), r=1.
  /// For flywheel/simple where velocity is RPM and position is rotations,
  /// r=60 because RPM = 60 × rotations/s.
  ///
  /// We want critically-damped response with a specified bandwidth.
  ///
  /// [maxVelocity] is the maximum expected velocity in user units/s (used
  /// to scale gains appropriately).
  static PidResult tunePosition({
    required FeedforwardGains ff,
    required MechanismType mechanismType,
    double desiredBandwidthHz = 5.0,
    double dampingRatio = 1.0,
    double controlPeriodMs = 1.0,
    double? maxVelocity,
    double transportDelaySec = defaultTransportDelaySec,
  }) {
    const nominalVoltage = 12.0;
    var omega = 2.0 * math.pi * desiredBandwidthHz; // rad/s
    var zeta = dampingRatio;
    final warnings = <String>[];

    final double r = _velocityToPositionRateFactor(mechanismType);

    if (ff.kA > 0 && ff.kV > 0) {
      final plantTau = ff.kA / ff.kV;

      // ── Bandwidth cap based on plant dynamics ─────────────────────
      // Cap ω so that ω·τ_plant ≤ _maxOmegaTauProduct.  Beyond this the
      // controller asks the plant to respond faster than its linear
      // dynamics allow, which amplifies stiction and backlash.
      final maxOmegaTau = _maxOmegaTauProduct / plantTau;
      if (omega > maxOmegaTau) {
        final oldBw = omega / (2.0 * math.pi);
        omega = maxOmegaTau;
        warnings.add(
          'Plant \u03c4 = ${(plantTau * 1000).toStringAsFixed(1)} ms. '
          'Position bandwidth reduced from '
          '${oldBw.toStringAsFixed(1)} Hz to '
          '${(omega / (2.0 * math.pi)).toStringAsFixed(1)} Hz '
          '(\u03c9\u00b7\u03c4 \u2264 ${_maxOmegaTauProduct.toStringAsFixed(1)}).');
      }

      // ── Transport-delay damping compensation ───────────────────────
      // A delay T adds phase lag ω·T (radians).  For a second-order
      // system this reduces effective damping by approximately ω·T/2.
      // Compensate by boosting ζ so the actual closed-loop damping
      // stays close to the requested value.
      if (transportDelaySec > 0) {
        final phaseLag = omega * transportDelaySec; // radians
        final zetaLoss = phaseLag / 2.0;
        if (zetaLoss > 0.01) {
          final oldZeta = zeta;
          zeta += zetaLoss;
          warnings.add(
            'Transport delay \u2248 ${(transportDelaySec * 1000).toStringAsFixed(0)} ms '
            'reduces effective damping. \u03b6 increased from '
            '${oldZeta.toStringAsFixed(2)} to ${zeta.toStringAsFixed(2)} '
            'to compensate.');
        }
      }

      // ── Additional low-inertia de-rating ───────────────────────────
      if (plantTau < _lowInertiaTauThreshold) {
        final dampingBoost =
            (_lowInertiaTauThreshold / plantTau).clamp(1.0, 2.5);
        if (dampingBoost > 1.01) {
          final oldZeta = zeta;
          zeta *= dampingBoost;
          warnings.add(
            'Low inertia detected (plant \u03c4 = '
            '${(plantTau * 1000).toStringAsFixed(1)} ms). '
            'Damping ratio increased from ${oldZeta.toStringAsFixed(2)} '
            'to ${zeta.toStringAsFixed(2)} for robustness.');
        }
      }
    }

    // With kV/kA feedforward active (firmware ≥25.0), the SPARK outputs:
    //   V = (kP·pos_error + kD·(-vel) + kI·∫(error))·V_nom
    //       + kV·measured_vel + kA·accel + kS·sign(error)
    //
    // The kV·vel feedforward cancels the plant's natural kV·ω damping,
    // leaving an effective plant ≈ 1/(r·kA·s²)  (double integrator).
    //
    // Closed-loop characteristic equation (dividing by r·kA):
    //   s² + V_nom·kD/kA · s + V_nom·kP/(r·kA) = 0
    //
    // Matching to desired poles s² + 2·ζ·ω_n·s + ω_n² = 0:
    //   ω_n² = V_nom·kP / (r·kA)  →  kP = r·kA·ω_n² / V_nom
    //   2·ζ·ω_n = V_nom·kD / kA   →  kD = 2·ζ·kA·ω_n / V_nom

    final kPVolts = r * ff.kA * omega * omega;
    final kDVolts = 2.0 * zeta * ff.kA * omega;

    final kP = kPVolts / nominalVoltage;
    final kD = kDVolts > 0 ? kDVolts / nominalVoltage : 0.0;
    const kI = 0.0;

    // Compute D-filter coefficient for the SPARK's EMA low-pass filter.
    // Set cutoff at N× the closed-loop bandwidth (omega / 2π).
    final dFilter = kD > 0 ? computeDFilter(omega / (2.0 * math.pi)) : 0.0;

    return PidResult(
      kP: kP,
      kI: kI,
      kD: kD,
      dFilter: dFilter,
      positionBandwidthHz: omega / (2.0 * math.pi),
      warnings: warnings,
    );
  }

  /// Returns the ratio between the velocity user unit and the time derivative
  /// of the position user unit.
  ///
  /// For flywheel/simple: RPM ÷ (rotations/s) = 60.
  /// For arm/elevator: velocity unit = d(position unit)/dt, so ratio = 1.
  static double _velocityToPositionRateFactor(MechanismType type) {
    return switch (type) {
      MechanismType.flywheel || MechanismType.simple => 60.0,
      MechanismType.arm || MechanismType.elevator => 1.0,
    };
  }

  /// Compute the SPARK D-filter EMA coefficient for a given closed-loop
  /// bandwidth.
  ///
  /// The filter cutoff is placed at [_dFilterBandwidthMultiplier]× the
  /// bandwidth to reject high-frequency noise while preserving phase
  /// margin at the crossover frequency.
  ///
  /// Returns α in [0, 1) where:
  ///   D_filtered[n] = (1-α)·D_raw[n] + α·D_filtered[n-1]
  ///   α = 1 / (1 + 2π·f_c·T_s)
  static double computeDFilter(double bandwidthHz) {
    if (bandwidthHz <= 0) return 0.0;
    final fc = _dFilterBandwidthMultiplier * bandwidthHz;
    final alpha = 1.0 / (1.0 + 2.0 * math.pi * fc * _sparkControlPeriodSec);
    // Clamp to avoid extreme values; 0.0 means no filter.
    return alpha < 0.05 ? 0.0 : alpha.clamp(0.0, 0.99);
  }

  /// Compute blended feedforward from unloaded and loaded gain sets.
  ///
  /// Each parameter is the arithmetic mean: error is bounded to ±ΔkX/2
  /// in either direction, which the integral term corrects.
  static FeedforwardGains blendFeedforward(
    FeedforwardGains unloaded,
    FeedforwardGains loaded,
  ) {
    return FeedforwardGains(
      kS: (unloaded.kS + loaded.kS) / 2.0,
      kV: (unloaded.kV + loaded.kV) / 2.0,
      kA: (unloaded.kA + loaded.kA) / 2.0,
      kG: (unloaded.kG + loaded.kG) / 2.0,
    );
  }

  /// Compute robust velocity PID gains stable for both unloaded and loaded
  /// plant conditions.
  ///
  /// - kP sized for the lighter plant (min kA) so proportional action
  ///   never exceeds what either plant can track.
  /// - kI is a slow integral to reject the gravity/weight disturbance ΔkG.
  /// - I-zone bounds integrator accumulation to prevent windup.
  static PidResult tuneRobustVelocity({
    required FeedforwardGains ffUnloaded,
    required FeedforwardGains ffLoaded,
    required MechanismType mechanismType,
    double desiredTimeConstantMs = 100.0,
  }) {
    const nominalVoltage = 12.0;
    final warnings = <String>[];

    // Use lighter plant kA (faster natural response = worst-case for
    // proportional gain sizing — ensures stability for both).
    final kA = math.min(ffUnloaded.kA, ffLoaded.kA);
    final kV = math.max(ffUnloaded.kV, ffLoaded.kV);

    if (kA <= 0 || kV <= 0) {
      warnings.add('Invalid plant parameters — returning zero gains.');
      return PidResult(
        kP: 0, kI: 0, kD: 0,
        velocityTimeConstantMs: desiredTimeConstantMs,
        warnings: warnings,
      );
    }

    final plantTau = kA / kV;
    var tau = desiredTimeConstantMs / 1000.0;

    // Same clamping as single-plant tuneVelocity.
    if (tau < plantTau) {
      tau = plantTau;
      warnings.add(
        'Velocity time constant clamped to plant τ = '
        '${(plantTau * 1000).toStringAsFixed(1)} ms.');
    }
    if (plantTau < _lowInertiaTauThreshold) {
      final robustMin = plantTau * 3.0;
      if (tau < robustMin) {
        tau = robustMin;
        warnings.add('Low inertia de-rating applied: τ → '
            '${(tau * 1000).toStringAsFixed(0)} ms.');
      }
    }

    final kP = (kA / tau) / nominalVoltage;

    // Integral gain: reject the blended-load mismatch slowly enough that the
    // proportional loop remains dominant. A slower integral loop reduces
    // overshoot and long tail settling after the step response reaches target.
    final integralTimeSec = robustVelocityIntegralTimeSec(
      closedLoopTauSec: tau,
      plantTauSec: plantTau,
    );
    final kI = kP / integralTimeSec;

    // I-zone: bound accumulation to 2× |ΔkG| to prevent windup.
    final deltaKG = (ffLoaded.kG - ffUnloaded.kG).abs();
    final iZone = kI > 0 ? (2.0 * deltaKG / kI).clamp(0.0, 100.0) : 0.0;

    warnings.add(
      'Robust gains: kP uses lighter kA = ${kA.toStringAsFixed(4)}. '
      'kI = ${kI.toStringAsFixed(6)} uses Tᵢ = '
      '${integralTimeSec.toStringAsFixed(2)} s to reject load disturbance '
      'ΔkG = ${deltaKG.toStringAsFixed(3)} V without making the response ring.');

    return PidResult(
      kP: kP,
      kI: kI,
      kD: 0,
      iZone: iZone,
      velocityTimeConstantMs: tau * 1000.0,
      warnings: warnings,
    );
  }

  /// Compute robust position PID gains stable for both unloaded and loaded
  /// plant conditions.
  ///
  /// - kP and kD sized for **heavier** kA (max) to avoid over-driving the
  ///   loaded plant — the lighter plant simply settles faster (no overshoot).
  ///   This is opposite to robust velocity, where min(kA) is correct because
  ///   lighter inertia means less phase margin.
  /// - kI added for disturbance rejection of blended-kG mismatch.
  /// - I-zone bounded to prevent windup.
  /// - D-filter at 8× bandwidth as usual.
  /// - Default damping ratio 1.2 (overdamped) to eliminate overshoot from
  ///   the gravity-compensation mismatch inherent in FF blending.
  static PidResult tuneRobustPosition({
    required FeedforwardGains ffUnloaded,
    required FeedforwardGains ffLoaded,
    required MechanismType mechanismType,
    double desiredBandwidthHz = 5.0,
    double dampingRatio = 1.2,
    double transportDelaySec = defaultTransportDelaySec,
  }) {
    const nominalVoltage = 12.0;
    final warnings = <String>[];

    final double r = _velocityToPositionRateFactor(mechanismType);

    // Use heavier kA (max) for position — avoids over-driving the loaded
    // plant which has more momentum and would overshoot with lighter gains.
    // Use heavier kV (max) for conservative damping subtraction.
    final kA = math.max(ffUnloaded.kA, ffLoaded.kA);
    final kV = math.max(ffUnloaded.kV, ffLoaded.kV);

    if (kA <= 0 || kV <= 0) {
      warnings.add('Invalid plant parameters — returning zero gains.');
      return PidResult(
        kP: 0, kI: 0, kD: 0,
        positionBandwidthHz: desiredBandwidthHz,
        warnings: warnings,
      );
    }

    final plantTau = kA / kV;
    var omega = 2.0 * math.pi * desiredBandwidthHz;
    var zeta = dampingRatio;

    // Bandwidth cap: ω·τ ≤ _maxOmegaTauProduct.
    final maxOmegaTau = _maxOmegaTauProduct / plantTau;
    if (omega > maxOmegaTau) {
      omega = maxOmegaTau;
      warnings.add(
        'Position bandwidth clamped to '
        '${(omega / (2.0 * math.pi)).toStringAsFixed(1)} Hz '
        '(ω·τ ≤ ${_maxOmegaTauProduct.toStringAsFixed(1)}).');
    }

    // Transport-delay damping compensation.
    if (transportDelaySec > 0) {
      final phaseLag = omega * transportDelaySec;
      final zetaLoss = phaseLag / 2.0;
      if (zetaLoss > 0.01) {
        zeta += zetaLoss;
      }
    }

    // Low-inertia de-rating.
    if (plantTau < _lowInertiaTauThreshold) {
      final boost = (_lowInertiaTauThreshold / plantTau).clamp(1.0, 2.5);
      if (boost > 1.01) zeta *= boost;
    }

    // Pole placement (same derivation as single-plant tunePosition).
    // With kV/kA feedforward active, kV damping is cancelled — D term
    // must provide all damping:  kD = 2·ζ·kA·ω / V_nom.
    final kPVolts = r * kA * omega * omega;
    final kDVolts = 2.0 * zeta * kA * omega;
    final kP = kPVolts / nominalVoltage;
    final kD = kDVolts > 0 ? kDVolts / nominalVoltage : 0.0;

    // Integral: correct residual blended-gravity mismatch slowly so PD still
    // shapes the transient while I only trims the final error.
    final integralTimeSec = robustPositionIntegralTimeSec(
      omegaRadPerSec: omega,
      plantTauSec: plantTau,
    );
    final kI = kP / integralTimeSec;

    // I-zone: |ΔkG| / kI bounds accumulation.
    final deltaKG = (ffLoaded.kG - ffUnloaded.kG).abs();
    final iZone = kI > 0 ? (deltaKG / kI).clamp(0.0, 100.0) : 0.0;

    final dFilter = kD > 0
        ? computeDFilter(omega / (2.0 * math.pi))
        : 0.0;

    warnings.add(
      'Robust gains: kP/kD use heavier kA = ${kA.toStringAsFixed(4)}. '
      'kI = ${kI.toStringAsFixed(6)} uses Tᵢ = '
      '${integralTimeSec.toStringAsFixed(2)} s to trim residual ΔkG = '
      '${deltaKG.toStringAsFixed(3)} V after the PD transient settles.');

    return PidResult(
      kP: kP,
      kI: kI,
      kD: kD,
      dFilter: dFilter,
      iZone: iZone,
      positionBandwidthHz: omega / (2.0 * math.pi),
      warnings: warnings,
    );
  }
}
