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
  }) {
    const nominalVoltage = 12.0;

    var tau = desiredTimeConstantMs / 1000.0; // desired time constant
    final warnings = <String>[];

    // Low-inertia robustness: when the plant time constant (kA/kV) is very
    // small, the system has negligible inertia and nonlinearities (backlash,
    // stiction) dominate the response.  Ensure the desired CL time constant
    // is at least 3× the plant time constant so the controller doesn't try
    // to be faster than the physical system can linearly track.
    if (ff.kA > 0 && ff.kV > 0) {
      final plantTau = ff.kA / ff.kV;
      if (plantTau < _lowInertiaTauThreshold) {
        final minTau = plantTau * 3.0;
        if (tau < minTau) {
          final oldTauMs = tau * 1000.0;
          tau = minTau;
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
  }) {
    const nominalVoltage = 12.0;
    var omega = 2.0 * math.pi * desiredBandwidthHz; // rad/s
    var zeta = dampingRatio;
    final warnings = <String>[];

    final double r = _velocityToPositionRateFactor(mechanismType);

    // Low-inertia robustness: when the plant time constant is small,
    // nonlinearities (backlash, stiction) dominate.  Reduce bandwidth and
    // increase damping so the controller doesn't drive the system through
    // dead zones at high speed.
    if (ff.kA > 0 && ff.kV > 0) {
      final plantTau = ff.kA / ff.kV;
      if (plantTau < _lowInertiaTauThreshold) {
        // Cap bandwidth: don't command faster than 1/(2·τ_plant) rad/s.
        final maxOmega = 1.0 / (2.0 * plantTau);
        if (omega > maxOmega) {
          omega = maxOmega;
          warnings.add(
            'Low inertia detected (plant \u03c4 = '
            '${(plantTau * 1000).toStringAsFixed(1)} ms). '
            'Position bandwidth reduced from '
            '${desiredBandwidthHz.toStringAsFixed(1)} Hz to '
            '${(omega / (2.0 * math.pi)).toStringAsFixed(1)} Hz.');
        }
        // Increase damping proportionally to the inertia deficit.
        final dampingBoost =
            (_lowInertiaTauThreshold / plantTau).clamp(1.0, 2.5);
        if (dampingBoost > 1.01) {
          zeta = dampingRatio * dampingBoost;
          warnings.add(
            'Damping ratio increased from ${dampingRatio.toStringAsFixed(2)} '
            'to ${zeta.toStringAsFixed(2)} for low-inertia robustness.');
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

    return PidResult(
      kP: kP,
      kI: kI,
      kD: kD,
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
}
