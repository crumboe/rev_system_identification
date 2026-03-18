/// First-principles elevator physics model for simulation.
///
/// Models a DC motor driving a linear elevator with constant gravity.
/// Uses the feedforward model:
///   V = kS·sign(v) + kG + kV·v + kA·a
/// solved for linear acceleration a, then integrated each time step.
///
/// Position is in inches, velocity in in/s.
library;

import 'dart:math';

import 'simulated_physics.dart';

/// Simulates an elevator mechanism with constant gravity compensation.
///
/// Known-answer constants for student verification:
///   kS ≈ 0.18 V, kV ≈ 0.12 V·s/in, kA ≈ 0.015 V·s²/in, kG ≈ 0.55 V
class ElevatorPhysics implements SimulatedPhysics {
  @override
  final double kS;

  /// Velocity feedforward (V per in/s).
  @override
  final double kV;

  /// Acceleration feedforward (V per in/s²).
  @override
  final double kA;

  /// Gravity compensation (V) — constant voltage to hold against gravity.
  @override
  final double kG;

  @override
  final double nominalVoltage;

  final double currentPerVolt;

  /// Soft limits in inches.
  final double minPositionIn;
  final double maxPositionIn;

  /// Inches per motor rotation (sprocket circumference / gear ratio).
  final double inchesPerRotation;

  /// Backlash dead-band in output inches.
  final double backlashInches;

  // -- State ----------------------------------------------------------------

  /// Current velocity in in/s.
  double _velocityInPerS = 0.0;

  /// Current position in inches.
  double _positionIn = 0.0;

  /// Output-side position after backlash is applied (sensor sees this).
  double _outputPositionIn = 0.0;

  /// Remaining backlash clearance to consume in the current direction.
  double _backlashRemainingIn = 0.0;

  /// Last direction of transmitted motion through the backlash mesh.
  double _backlashDirection = 0.0;

  @override
  double commandedVoltage = 0.0;

  @override
  double loadTorqueVolts = 0.0;

  final Random _rng;
  final double noiseLevel;

  ElevatorPhysics({
    this.kS = 0.18,
    this.kV = 0.12,
    this.kA = 0.015,
    this.kG = 0.55,
    this.nominalVoltage = 12.0,
    this.currentPerVolt = 3.5,
    this.noiseLevel = 0.015,
    this.minPositionIn = 0.0,
    this.maxPositionIn = 78.74,  // ~2 meters
    this.inchesPerRotation = 1.504,  // ~1.5" sprocket with 16:1 reduction
    this.backlashInches = 0.0,
    int? randomSeed,
  }) : _rng = Random(randomSeed);

  @override
  void reset() {
    _velocityInPerS = 0.0;
    _positionIn = 0.0;
    _outputPositionIn = 0.0;
    _backlashRemainingIn = 0.0;
    _backlashDirection = 0.0;
    commandedVoltage = 0.0;
  }

  @override
  void setPositionRotations(double rotations) {
    _positionIn = rotations * inchesPerRotation;
    _positionIn = _positionIn.clamp(minPositionIn, maxPositionIn);
    _outputPositionIn = _positionIn;
    _backlashRemainingIn = 0.0;
    _backlashDirection = 0.0;
  }

  @override
  void step(double voltage, double dtSeconds) {
    commandedVoltage = voltage.clamp(-nominalVoltage, nominalVoltage);

    // Gravity is a constant upward voltage requirement.
    final gravityVoltage = kG;

    // Load acts like additional gravity (constant, not velocity-dependent).
    final totalGravity = gravityVoltage + loadTorqueVolts;

    // Friction term.
    final double frictionTerm;
    if (_velocityInPerS.abs() > 0.05) {
      frictionTerm = kS * _velocityInPerS.sign;
    } else if ((commandedVoltage - totalGravity).abs() > kS) {
      frictionTerm = kS * (commandedVoltage - totalGravity).sign;
    } else {
      frictionTerm = commandedVoltage - totalGravity;
    }

    // V = kS·sign(v) + kG + kV·v + kA·a
    // a = (V - kS·sign(v) - kG - kV·v) / kA
    final netVoltage =
        commandedVoltage - frictionTerm - totalGravity - kV * _velocityInPerS;
    final accel = kA > 0 ? netVoltage / kA : 0.0;

    _velocityInPerS += accel * dtSeconds;

    // Friction stall.
    if ((commandedVoltage - totalGravity).abs() < kS &&
        _velocityInPerS.abs() < 0.05) {
      _velocityInPerS = 0.0;
    }

    final prevPositionIn = _positionIn;
    _positionIn += _velocityInPerS * dtSeconds;

    final motorDeltaIn = _positionIn - prevPositionIn;
    _outputPositionIn += _transmitThroughBacklash(motorDeltaIn);

    // Hard stops at limits — prevent motion into the wall.
    if (_positionIn <= minPositionIn) {
      _positionIn = minPositionIn;
      _outputPositionIn = minPositionIn;
      if (_velocityInPerS < 0) _velocityInPerS = 0.0;
    }
    if (_positionIn >= maxPositionIn) {
      _positionIn = maxPositionIn;
      _outputPositionIn = maxPositionIn;
      if (_velocityInPerS > 0) _velocityInPerS = 0.0;
    }

    // If sitting on a hard stop, prevent acceleration further into it.
    if (_positionIn <= minPositionIn && _velocityInPerS <= 0) {
      _velocityInPerS = 0.0;
    }
    if (_positionIn >= maxPositionIn && _velocityInPerS >= 0) {
      _velocityInPerS = 0.0;
    }
  }

  // -- Sensor outputs (in encoder-native units: rotations & RPM) -----------

  /// Convert in/s to RPM.
  double get _velocityRpm =>
      (_velocityInPerS / inchesPerRotation) * 60.0;

  /// Convert inches to rotations.
  double get _positionRotations => _outputPositionIn / inchesPerRotation;

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
        (commandedVoltage - kV * _velocityInPerS).abs();
    return torqueVoltage * currentPerVolt * (1.0 + _noise());
  }

  @override
  int get temperatureC => 25;

  @override
  String get label => 'Simulated Elevator';

  double _transmitThroughBacklash(double motorDeltaIn) {
    if (backlashInches <= 0 || motorDeltaIn == 0.0) {
      return motorDeltaIn;
    }

    final direction = motorDeltaIn.sign;
    if (direction != _backlashDirection) {
      _backlashDirection = direction;
      _backlashRemainingIn = backlashInches;
    }

    final deltaAbs = motorDeltaIn.abs();
    final consume =
        deltaAbs < _backlashRemainingIn ? deltaAbs : _backlashRemainingIn;
    _backlashRemainingIn -= consume;

    final transmittedAbs = deltaAbs - consume;
    return transmittedAbs * direction;
  }

  double _noise() => (2.0 * _rng.nextDouble() - 1.0) * noiseLevel;
}
