/// First-principles arm physics model for simulation.
///
/// Models a DC motor driving a pivoting arm with gravity.
/// Uses the feedforward model:
///   V = kS·sign(ω) + kG·cos(θ) + kV·ω + kA·α
/// solved for angular acceleration α, then integrated each time step.
///
/// Position is in degrees, velocity in deg/s.
library;

import 'dart:math';

import 'simulated_physics.dart';

/// Simulates an arm mechanism with gravity compensation.
///
/// Known-answer constants for student verification:
///   kS ≈ 0.20 V, kV ≈ 0.018 V·s/deg, kA ≈ 0.002 V·s²/deg, kG ≈ 0.80 V
class ArmPhysics implements SimulatedPhysics {
  @override
  final double kS;

  /// Velocity feedforward (V per deg/s).
  @override
  final double kV;

  /// Acceleration feedforward (V per deg/s²).
  @override
  final double kA;

  /// Gravity compensation (V) — peak voltage to hold against gravity.
  @override
  final double kG;

  @override
  final double nominalVoltage;

  final double currentPerVolt;

  /// Multiplies effective inertia in simulation by scaling kA.
  ///
  /// Values > 1 make the arm feel heavier (slower acceleration for the same
  /// voltage). Values < 1 make it feel lighter.
  final double inertiaMultiplier;

  /// Degrees of arm output motion per one motor rotation.
  ///
  /// This should match the controller position conversion factor so that
  /// status-frame user units and simulated plant units stay consistent,
  /// including geared arms.
  final double degreesPerRotation;

  /// Soft limits in degrees.
  final double minAngleDeg;
  final double maxAngleDeg;

  /// Backlash dead-band in degrees at the output.
  final double backlashDeg;

  // -- State ----------------------------------------------------------------

  /// Current angular velocity in deg/s.
  double _velocityDegPerS = 0.0;

  /// Current angle in degrees (0 = horizontal).
  double _angleDeg = 0.0;

  /// Output-side angle after backlash is applied (sensor sees this).
  double _outputAngleDeg = 0.0;

  /// Remaining backlash clearance to consume in the current direction.
  double _backlashRemainingDeg = 0.0;

  /// Last direction of transmitted motion through the backlash mesh.
  double _backlashDirection = 0.0;

  @override
  double commandedVoltage = 0.0;

  @override
  double loadTorqueVolts = 0.0;

  final Random _rng;
  final double noiseLevel;

  ArmPhysics({
    this.kS = 0.20,
    this.kV = 0.018,
    this.kA = 0.002,
    this.kG = 0.80,
    this.nominalVoltage = 12.0,
    this.currentPerVolt = 3.0,
    this.inertiaMultiplier = 1.0,
    this.degreesPerRotation = 360.0,
    this.noiseLevel = 0.015,
    this.minAngleDeg = -45.0,
    this.maxAngleDeg = 90.0,
    this.backlashDeg = 0.0,
    int? randomSeed,
  }) : _rng = Random(randomSeed);

  @override
  void reset() {
    _velocityDegPerS = 0.0;
    _angleDeg = 0.0;
    _outputAngleDeg = 0.0;
    _backlashRemainingDeg = 0.0;
    _backlashDirection = 0.0;
    commandedVoltage = 0.0;
  }

  @override
  void setPositionRotations(double rotations) {
    _angleDeg = rotations * degreesPerRotation;
    _angleDeg = _angleDeg.clamp(minAngleDeg, maxAngleDeg);
    _outputAngleDeg = _angleDeg;
    _backlashRemainingDeg = 0.0;
    _backlashDirection = 0.0;
  }

  @override
  void step(double voltage, double dtSeconds) {
    commandedVoltage = voltage.clamp(-nominalVoltage, nominalVoltage);

    // Gravity term: kG·cos(θ) opposes downward motion.
    final angleRad = _angleDeg * pi / 180.0;
    final gravityVoltage = kG * cos(angleRad);

    // Load acts like additional gravity (angle-dependent, like kG·cos(θ)).
    final totalGravity = gravityVoltage + loadTorqueVolts * cos(angleRad);

    // Friction term.
    final double frictionTerm;
    if (_velocityDegPerS.abs() > 0.5) {
      frictionTerm = kS * _velocityDegPerS.sign;
    } else if ((commandedVoltage - totalGravity).abs() > kS) {
      frictionTerm = kS * (commandedVoltage - totalGravity).sign;
    } else {
      frictionTerm = commandedVoltage - totalGravity;
    }

    // V = kS·sign(ω) + kG·cos(θ) + kV·ω + kA·α
    // α = (V - kS·sign(ω) - kG·cos(θ) - kV·ω) / kA
    final netVoltage =
        commandedVoltage - frictionTerm - totalGravity - kV * _velocityDegPerS;
    final effectiveKA = kA * (inertiaMultiplier > 0 ? inertiaMultiplier : 1.0);
    final accel = effectiveKA > 0 ? netVoltage / effectiveKA : 0.0;

    _velocityDegPerS += accel * dtSeconds;

    // Friction stall.
    if ((commandedVoltage - totalGravity).abs() < kS &&
        _velocityDegPerS.abs() < 0.5) {
      _velocityDegPerS = 0.0;
    }

    final prevAngle = _angleDeg;
    _angleDeg += _velocityDegPerS * dtSeconds;

    final motorDeltaDeg = _angleDeg - prevAngle;
    _outputAngleDeg += _transmitThroughBacklash(motorDeltaDeg);

    // Hard stops at soft limits — prevent motion into the wall.
    if (_angleDeg <= minAngleDeg) {
      _angleDeg = minAngleDeg;
      _outputAngleDeg = minAngleDeg;
      if (_velocityDegPerS < 0) _velocityDegPerS = 0.0;
    }
    if (_angleDeg >= maxAngleDeg) {
      _angleDeg = maxAngleDeg;
      _outputAngleDeg = maxAngleDeg;
      if (_velocityDegPerS > 0) _velocityDegPerS = 0.0;
    }

    // If sitting on a hard stop, prevent acceleration further into it.
    if (_angleDeg <= minAngleDeg && _velocityDegPerS <= 0) {
      _velocityDegPerS = 0.0;
    }
    if (_angleDeg >= maxAngleDeg && _velocityDegPerS >= 0) {
      _velocityDegPerS = 0.0;
    }
  }

  // -- Sensor outputs (in encoder-native units: rotations & RPM) -----------

  /// Convert internal deg/s to RPM for the encoder.
  double get _velocityRpm => _velocityDegPerS / degreesPerRotation * 60.0;

  /// Convert internal degrees to rotations for the encoder.
  double get _positionRotations => _outputAngleDeg / degreesPerRotation;

  @override
  double get noisyVelocityRpm {
    if (_velocityRpm.abs() < 0.01) return 0.0;
    return _velocityRpm * (1.0 + _noise());
  }

  @override
  double get noisyPositionRotations =>
      _positionRotations + _noise() * 0.0005;

  @override
  double get outputCurrentAmps {
    final torqueVoltage =
        (commandedVoltage - kV * _velocityDegPerS).abs();
    return torqueVoltage * currentPerVolt * (1.0 + _noise());
  }

  @override
  int get temperatureC => 25;

  @override
  String get label => 'Simulated Arm';

  double _transmitThroughBacklash(double motorDeltaDeg) {
    if (backlashDeg <= 0 || motorDeltaDeg == 0.0) {
      return motorDeltaDeg;
    }

    final direction = motorDeltaDeg.sign;
    if (direction != _backlashDirection) {
      _backlashDirection = direction;
      _backlashRemainingDeg = backlashDeg;
    }

    final deltaAbs = motorDeltaDeg.abs();
    final consume =
        deltaAbs < _backlashRemainingDeg ? deltaAbs : _backlashRemainingDeg;
    _backlashRemainingDeg -= consume;

    final transmittedAbs = deltaAbs - consume;
    return transmittedAbs * direction;
  }

  double _noise() => (2.0 * _rng.nextDouble() - 1.0) * noiseLevel;
}
