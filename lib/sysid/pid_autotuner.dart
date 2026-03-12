/// PID auto-tuner: computes PID gains from the identified feedforward model.
///
/// Uses the plant model V = kS·sign(ω) + kV·ω + kA·α to derive PID gains
/// for closed-loop position or velocity control on the SPARK controller.
library;

import '../data/test_data.dart';
import '../mechanisms/mechanism.dart';

/// Computes PID gains from identified feedforward constants.
class PidAutoTuner {
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
    // The SPARK's internal PID operates on error in native units (RPM for
    // velocity) and outputs duty cycle [-1, 1].  We need to account for the
    // bus voltage when converting between the physical model and the
    // controller's PID.
    //
    // However, since users will typically run voltage compensation mode,
    // we can compute gains assuming 12V nominal bus voltage.
    const nominalVoltage = 12.0;

    final tau = desiredTimeConstantMs / 1000.0; // desired time constant

    // Model: τ·dω/dt + ω = (1/kV)·(V - kS·sign(ω))
    // where τ_plant = kA / kV (the plant's natural time constant)

    // kP: proportional gain. For a first-order system, we want the closed-loop
    // time constant to equal [tau].  The closed-loop bandwidth is determined by
    // kP.  In voltage units: kP_volts = kA / tau.
    // Convert to SPARK PID units (duty cycle per RPM):
    final kP = ff.kA > 0 ? (ff.kA / tau) / nominalVoltage : 0.0;

    // kI: typically 0 for velocity control to avoid windup.
    const kI = 0.0;

    // kD: not typically used for velocity control.
    const kD = 0.0;

    // Note: feedforward (kS, kV, kA, kG) is now configured separately
    // via the controller's FeedForwardConfig, not as part of PID.

    return PidResult(
      kP: kP,
      kI: kI,
      kD: kD,
      velocityTimeConstantMs: desiredTimeConstantMs,
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
    final omega = 2.0 * 3.14159265 * desiredBandwidthHz; // rad/s
    final zeta = dampingRatio;

    // Velocity-to-position-rate factor.
    //
    // For flywheel/simple: velocity is RPM, position is rotations.
    //   d(rotations)/dt = RPM / 60  →  r = 60
    // For arm: velocity is deg/s, position is degrees.  r = 1
    // For elevator: velocity is m/s (or in/s), position is m (or in).  r = 1
    final double r = _velocityToPositionRateFactor(mechanismType);

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

    // Convert to SPARK PID units (duty cycle per position-unit for P,
    // per velocity-unit for D).
    final kP = kPVolts / nominalVoltage;
    final kD = kDVolts > 0 ? kDVolts / nominalVoltage : 0.0;

    // No integral needed for position PID.
    const kI = 0.0;

    // Note: feedforward (kS, kG/kCos) is configured separately
    // via the controller's FeedForwardConfig.

    return PidResult(
      kP: kP,
      kI: kI,
      kD: kD,
      positionBandwidthHz: desiredBandwidthHz,
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
