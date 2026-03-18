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

  /// Backlash dead-band in output rotations.
  ///
  /// The output position does not move until motor motion consumes this
  /// clearance after a direction reversal.
  final double backlashRotations;

  /// Extra breakaway voltage beyond kS used to model stick-slip in no-load
  /// systems. 0 disables the effect.
  final double stictionExtraVolts;

  /// Velocity threshold (RPM) below which static friction behavior dominates.
  final double stictionVelocityRpm;

  /// Number of simulation ticks of control delay for applied voltage.
  final int controlDelaySteps;

  /// Encoder position quantization step in rotations.
  final double encoderPositionQuantumRot;

  /// Encoder velocity quantization step in RPM.
  final double encoderVelocityQuantumRpm;

  // -----------------------------------------------------------------------
  // State
  // -----------------------------------------------------------------------

  /// Current angular velocity in RPM.
  double velocityRpm = 0.0;

  /// Current position in rotations.
  double positionRotations = 0.0;

  /// Output-side position after backlash is applied (sensor sees this).
  double _outputPositionRotations = 0.0;

  /// Remaining backlash clearance to consume in the current direction.
  double _backlashRemaining = 0.0;

  /// Last direction of transmitted motion through the backlash mesh.
  double _backlashDirection = 0.0;

  /// Last commanded voltage.
  double commandedVoltage = 0.0;

  @override
  double loadTorqueVolts = 0.0;

  /// Voltage after transport delay, used by plant dynamics.
  double _appliedVoltage = 0.0;

  /// Delay queue for applied voltage.
  final List<double> _voltageDelayQueue = <double>[];

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
    this.backlashRotations = 0.0,
    this.stictionExtraVolts = 0.0,
    this.stictionVelocityRpm = 35.0,
    this.controlDelaySteps = 0,
    this.encoderPositionQuantumRot = 0.0,
    this.encoderVelocityQuantumRpm = 0.0,
    this.noiseLevel = 0.015,
    int? randomSeed,
  }) : _rng = Random(randomSeed);

  /// Reset state to zero.
  void reset() {
    velocityRpm = 0.0;
    positionRotations = 0.0;
    _outputPositionRotations = 0.0;
    _backlashRemaining = 0.0;
    _backlashDirection = 0.0;
    _voltageDelayQueue.clear();
    _appliedVoltage = 0.0;
    commandedVoltage = 0.0;
  }

  @override
  void setPositionRotations(double rotations) {
    positionRotations = rotations;
    _outputPositionRotations = rotations;
    _backlashRemaining = 0.0;
    _backlashDirection = 0.0;
    _voltageDelayQueue.clear();
    _appliedVoltage = 0.0;
  }

  /// Advance the physics simulation by [dtSeconds].
  ///
  /// [voltage] is the applied motor voltage (clamped to ±nominalVoltage).
  void step(double voltage, double dtSeconds) {
    commandedVoltage = voltage.clamp(-nominalVoltage, nominalVoltage);

    // Apply controller/transport delay before the plant sees voltage.
    final delayed = _applyVoltageDelay(commandedVoltage);
    _appliedVoltage = delayed;

    // Net voltage after subtracting back-EMF and friction.
    // V = kS·sign(ω) + kV·ω + kA·α  →  α = (V - kS·sign(ω) - kV·ω) / kA
    final double frictionTerm;
    if (velocityRpm.abs() > stictionVelocityRpm) {
      // Moving: kinetic friction opposes motion.
      frictionTerm = kS * velocityRpm.sign;
    } else if (delayed.abs() > kS + stictionExtraVolts) {
      // Low-speed breakaway requires extra voltage in no-load systems.
      frictionTerm = (kS + stictionExtraVolts) * delayed.sign;
    } else {
      // Stalled: not enough voltage to overcome static friction.
      frictionTerm = delayed; // friction absorbs all voltage
    }

    final loadTerm = loadTorqueVolts * velocityRpm.sign;
    final netVoltage = delayed - frictionTerm - kV * velocityRpm - loadTerm;
    final accelerationRpmPerS = kA > 0 ? netVoltage / kA : 0.0;

    // Integrate velocity and position.
    velocityRpm += accelerationRpmPerS * dtSeconds;

    // Prevent sign changes due to friction at very low speed.
    if (delayed.abs() < kS + stictionExtraVolts && velocityRpm.abs() < 1.0) {
      velocityRpm = 0.0;
    }

    // Position: RPM → rot/s = RPM / 60
    final prevMotorPos = positionRotations;
    positionRotations += (velocityRpm / 60.0) * dtSeconds;

    // Apply backlash between motor and sensed output position.
    final motorDelta = positionRotations - prevMotorPos;
    _outputPositionRotations += _transmitThroughBacklash(motorDelta);
  }

  /// Get the current velocity with sensor noise applied.
  double get noisyVelocityRpm {
    if (velocityRpm.abs() < 0.1) return 0.0;
    final noisy = velocityRpm * (1.0 + _noise());
    return _quantize(noisy, encoderVelocityQuantumRpm);
  }

  /// Get the current position with sensor noise applied.
  double get noisyPositionRotations {
    final noisy = _outputPositionRotations + _noise() * 0.001;
    return _quantize(noisy, encoderPositionQuantumRot);
  }

  /// Get simulated output current (A) based on torque demand.
  double get outputCurrentAmps {
    final torqueVoltage =
        (_appliedVoltage - kV * velocityRpm).abs();
    return torqueVoltage * currentPerVolt * (1.0 + _noise());
  }

  /// Get simulated temperature (slowly increases with current).
  @override
  int get temperatureC => 25;

  @override
  String get label => 'Simulated Flywheel';

  @override
  double get kG => 0.0;

  double _transmitThroughBacklash(double motorDelta) {
    if (backlashRotations <= 0 || motorDelta == 0.0) {
      return motorDelta;
    }

    final direction = motorDelta.sign;
    if (direction != _backlashDirection) {
      _backlashDirection = direction;
      _backlashRemaining = backlashRotations;
    }

    final deltaAbs = motorDelta.abs();
    final consume = deltaAbs < _backlashRemaining ? deltaAbs : _backlashRemaining;
    _backlashRemaining -= consume;

    final transmittedAbs = deltaAbs - consume;
    return transmittedAbs * direction;
  }

  double _applyVoltageDelay(double requestedVoltage) {
    final steps = controlDelaySteps < 0 ? 0 : controlDelaySteps;
    if (steps == 0) return requestedVoltage;

    _voltageDelayQueue.add(requestedVoltage);
    if (_voltageDelayQueue.length <= steps) {
      return 0.0;
    }
    return _voltageDelayQueue.removeAt(0);
  }

  double _quantize(double value, double quantum) {
    if (quantum <= 0) return value;
    return (value / quantum).round() * quantum;
  }

  double _noise() => (2.0 * _rng.nextDouble() - 1.0) * noiseLevel;
}
