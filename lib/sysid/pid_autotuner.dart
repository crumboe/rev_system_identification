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

  /// Maximum ω·τ_plant product for position control.  Beyond this, the
  /// controller bandwidth exceeds what the plant dynamics can linearly
  /// track, amplifying stiction and backlash nonlinearities.
  static const _maxOmegaTauProduct = 2.0;

  /// SPARK controller internal loop period (seconds).
  static const _sparkControlPeriodSec = 0.001; // 1 ms

  /// Multiplier for D-filter cutoff relative to closed-loop bandwidth.
  /// The filter cutoff is set at N× the bandwidth to reject noise while
  /// adding minimal phase lag at frequencies the controller cares about.
  static const _dFilterBandwidthMultiplier = 8.0;

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
  /// Uses pole placement for a second-order system.
  /// The plant from voltage to position is:
  ///   G(s) = 1 / (r·kA·s² + r·kV·s)
  ///
  /// where `r` is the ratio between the velocity user unit and the position
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

    // The plant transfer function from voltage to position (user units):
    //   G(s) = 1 / (r·kA·s² + r·kV·s)
    //
    // The SPARK PID computes:
    //   output_dc = kP·pos_error + kD·(-velocity_user)
    //   V = output_dc × V_nom
    //
    // Closed-loop characteristic equation (dividing by r·kA):
    //   s² + (kV + V_nom·kD)/kA · s + V_nom·kP/(r·kA) = 0
    //
    // Matching to desired poles s² + 2·ζ·ω_n·s + ω_n² = 0:
    //   ω_n² = V_nom·kP / (r·kA)  →  kP = r·kA·ω_n² / V_nom
    //   2·ζ·ω_n = (kV + V_nom·kD)/kA  →  kD = (2·ζ·kA·ω_n − kV) / V_nom

    final kPVolts = r * ff.kA * omega * omega;
    final kDVolts = (2.0 * zeta * ff.kA * omega - ff.kV);

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
}
