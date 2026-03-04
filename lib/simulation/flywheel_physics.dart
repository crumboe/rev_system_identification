/// First-principles flywheel physics model for simulation.
///
/// Models a DC motor driving a flywheel with known system parameters.
/// Uses the standard feedforward model:
///   V = kS·sign(ω) + kV·ω + kA·α
/// solved for angular acceleration α, then integrated each time step.
library;

import 'dart:math';

import 'simulated_physics.dart';

/// Simulates a flywheel driven by a brushless DC motor (e.g., NEO).
///
/// The "known answer" constants are chosen to produce recognizable
/// sysid results that students can verify:
///   kS ≈ 0.14 V,  kV ≈ 0.0185 V·s/rot,  kA ≈ 0.003 V·s²/rot
class FlywheelPhysics implements SimulatedPhysics {
  // -----------------------------------------------------------------------
  // Ground-truth system constants (what sysid should recover)
  // -----------------------------------------------------------------------

  /// Static friction voltage (V).
  final double kS;

  /// Velocity feedforward (V per RPM).
  final double kV;

  /// Acceleration feedforward (V per RPM/s).
  final double kA;

  /// Nominal bus voltage (V).
  final double nominalVoltage;

  /// Current per volt of net torque (A/V) — for simulated current readout.
  final double currentPerVolt;

  // -----------------------------------------------------------------------
  // State
  // -----------------------------------------------------------------------

  /// Current angular velocity in RPM.
  double velocityRpm = 0.0;

  /// Current position in rotations.
  double positionRotations = 0.0;

  /// Last commanded voltage.
  double commandedVoltage = 0.0;

  /// Random number generator for sensor noise.
  final Random _rng;

  /// Noise amplitude as a fraction of the signal (0.0–1.0).
  final double noiseLevel;

  FlywheelPhysics({
    this.kS = 0.14,
    this.kV = 0.0185,
    this.kA = 0.003,
    this.nominalVoltage = 12.0,
    this.currentPerVolt = 2.5,
    this.noiseLevel = 0.015,
    int? randomSeed,
  }) : _rng = Random(randomSeed);

  /// Reset state to zero.
  void reset() {
    velocityRpm = 0.0;
    positionRotations = 0.0;
    commandedVoltage = 0.0;
  }

  @override
  void setPositionRotations(double rotations) {
    positionRotations = rotations;
  }

  /// Advance the physics simulation by [dtSeconds].
  ///
  /// [voltage] is the applied motor voltage (clamped to ±nominalVoltage).
  void step(double voltage, double dtSeconds) {
    commandedVoltage = voltage.clamp(-nominalVoltage, nominalVoltage);

    // Net voltage after subtracting back-EMF and friction.
    // V = kS·sign(ω) + kV·ω + kA·α  →  α = (V - kS·sign(ω) - kV·ω) / kA
    final double frictionTerm;
    if (velocityRpm.abs() > 0.5) {
      // Moving: kinetic friction opposes motion.
      frictionTerm = kS * velocityRpm.sign;
    } else if (commandedVoltage.abs() > kS) {
      // Stationary but enough voltage to overcome static friction.
      frictionTerm = kS * commandedVoltage.sign;
    } else {
      // Stalled: not enough voltage to overcome static friction.
      frictionTerm = commandedVoltage; // friction absorbs all voltage
    }

    final netVoltage = commandedVoltage - frictionTerm - kV * velocityRpm;
    final accelerationRpmPerS = kA > 0 ? netVoltage / kA : 0.0;

    // Integrate velocity and position.
    velocityRpm += accelerationRpmPerS * dtSeconds;

    // Prevent sign changes due to friction at very low speed.
    if (commandedVoltage.abs() < kS && velocityRpm.abs() < 1.0) {
      velocityRpm = 0.0;
    }

    // Position: RPM → rot/s = RPM / 60
    positionRotations += (velocityRpm / 60.0) * dtSeconds;
  }

  /// Get the current velocity with sensor noise applied.
  double get noisyVelocityRpm {
    if (velocityRpm.abs() < 0.1) return 0.0;
    return velocityRpm * (1.0 + _noise());
  }

  /// Get the current position with sensor noise applied.
  double get noisyPositionRotations {
    return positionRotations + _noise() * 0.001;
  }

  /// Get simulated output current (A) based on torque demand.
  double get outputCurrentAmps {
    final torqueVoltage =
        (commandedVoltage - kV * velocityRpm).abs();
    return torqueVoltage * currentPerVolt * (1.0 + _noise());
  }

  /// Get simulated temperature (slowly increases with current).
  @override
  int get temperatureC => 25;

  @override
  String get label => 'Simulated Flywheel';

  @override
  double get kG => 0.0;

  double _noise() => (2.0 * _rng.nextDouble() - 1.0) * noiseLevel;
}
