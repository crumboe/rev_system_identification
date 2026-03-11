/// Simulated SPARK connection and API implementations.
///
/// These classes implement the abstract interfaces from [interfaces.dart]
/// using a [SimulatedPhysics] model instead of real hardware, enabling
/// full app testing without a physical motor controller.
library;

import 'dart:async';
import 'dart:typed_data';

import '../can/interfaces.dart';
import '../can/spark_protocol.dart';
import '../can/status_parser.dart';
import '../can/parameter_api.dart' show PidGains, ControllerFeedForward;
import 'simulated_physics.dart';

// ---------------------------------------------------------------------------
// Simulated connection
// ---------------------------------------------------------------------------

/// A simulated connection that updates status frames from physics.
class SimulatedSparkConnection implements ISparkConnection {
  /// The underlying physics model. Exposed for position dragging.
  final SimulatedPhysics physics;
  final String _portName;
  Timer? _simTimer;
  bool _isOpen = false;

  /// Reference to the control API for closed-loop tick updates.
  SimulatedControlApi? controlApi;

  @override
  bool get isOpen => _isOpen;

  @override
  String get portName => _portName;

  @override
  StatusFrame0? lastStatus0;

  @override
  StatusFrame1? lastStatus1;

  @override
  StatusFrame2? lastStatus2;

  @override
  Stream<SparkResponse> get responses => const Stream<SparkResponse>.empty();

  SimulatedSparkConnection(this.physics, {String? portName})
      : _portName = portName ?? '🧪 ${physics.label}';

  @override
  Future<void> open() async {
    if (_isOpen) return;
    _isOpen = true;
    // Note: do NOT reset physics here — user may have set start position.

    // Run physics at 10ms intervals, updating status frames.
    _simTimer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => _tick(),
    );
  }

  void _tick() {
    // Run closed-loop PID+FF controller before physics step.
    controlApi?.tick(0.010);

    physics.step(physics.commandedVoltage, 0.010);

    // Compute the applied output (duty cycle) from commanded voltage.
    final appliedOutput = physics.nominalVoltage > 0
        ? (physics.commandedVoltage / physics.nominalVoltage).clamp(-1.0, 1.0)
        : 0.0;

    lastStatus0 = StatusFrame0(
      appliedOutput: appliedOutput,
      faults: 0,
      stickyFaults: 0,
      flags: 0,
    );

    lastStatus1 = StatusFrame1(
      velocityRpm: physics.noisyVelocityRpm,
      temperatureC: physics.temperatureC,
      busVoltage: physics.nominalVoltage,
      outputCurrentAmps: physics.outputCurrentAmps,
    );

    lastStatus2 = StatusFrame2(
      positionRotations: physics.noisyPositionRotations,
    );
  }

  @override
  void close() {
    _simTimer?.cancel();
    _simTimer = null;
    _isOpen = false;
  }

  @override
  void dispose() => close();

  @override
  void sendRaw(Uint8List packet) {
    // No-op for simulation.
  }

  @override
  void sendCommand(int arbId, Uint8List payload) {
    // No-op for simulation.
  }

  @override
  Future<SparkResponse> sendAndReceive(
    int arbId,
    Uint8List payload, {
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    // Return a dummy ACK response.
    return SparkResponse(
      responseType: kUsbResponseAck,
      arbId: arbId,
      payload: Uint8List(8),
    );
  }
}

// ---------------------------------------------------------------------------
// Simulated heartbeat manager
// ---------------------------------------------------------------------------

/// A no-op heartbeat manager for simulation.
class SimulatedHeartbeatManager implements IHeartbeatManager {
  bool _running = false;
  bool _enabled = false;

  @override
  bool get isRunning => _running;

  @override
  bool get isEnabled => _enabled;

  @override
  void start({bool enabled = true}) {
    _running = true;
    _enabled = enabled;
  }

  @override
  void stop() {
    _running = false;
    _enabled = false;
  }

  @override
  void enable() => _enabled = true;

  @override
  void disable() => _enabled = false;

  @override
  void sendOnce({bool enabled = true}) {
    // No-op.
  }

  @override
  void dispose() => stop();
}

// ---------------------------------------------------------------------------
// Simulated PID + FeedForward controller
// ---------------------------------------------------------------------------

/// Emulates the SPARK's internal closed-loop PID + FeedForward controller.
///
/// Runs once per simulation tick (~10 ms) and computes a voltage command
/// from the setpoint, measured state, and stored PID/FF parameters.
class SimulatedPidFfController {
  final SimulatedParameterApi _params;
  final SimulatedPhysics _physics;

  double _integralAccum = 0.0;
  double _prevError = 0.0;
  bool _firstTick = true;

  SimulatedPidFfController(this._params, this._physics);

  /// Reset integral accumulator and derivative state.
  void reset() {
    _integralAccum = 0.0;
    _prevError = 0.0;
    _firstTick = true;
  }

  /// Compute voltage for velocity closed-loop control.
  ///
  /// The SPARK's velocity PID computes:
  ///   output = kP*error + kI*integral + kD*derivative
  ///          + kS*sign(setpoint) + kV*setpoint
  ///          + kG (elevator) or kCos*cos(pos) (arm)
  double computeVelocity(double setpointRpm, double dtSeconds) {
    final kP = _params.getParamSync(kParamSlot0P);
    final kI = _params.getParamSync(kParamSlot0I);
    final kD = _params.getParamSync(kParamSlot0D);
    final iZone = _params.getParamSync(kParamSlot0IZone);
    final maxOut = _params.getParamSync(kParamSlot0MaxOutput);
    final minOut = _params.getParamSync(kParamSlot0MinOutput);

    final ffKs = _params.getParamSync(kParamSlot0FfKs);
    final ffKv = _params.getParamSync(kParamSlot0FfKv);
    final ffKg = _params.getParamSync(kParamSlot0FfKg);
    final ffKcos = _params.getParamSync(kParamSlot0FfKcos);
    final ffKcosRatio = _params.getParamSync(kParamSlot0FfKcosRatio);

    final measuredRpm = _physics.noisyVelocityRpm;
    final error = setpointRpm - measuredRpm;

    // Integral with anti-windup via IZone
    if (iZone <= 0 || error.abs() < iZone) {
      _integralAccum += error * dtSeconds;
    } else {
      _integralAccum = 0.0;
    }

    // Derivative (skip first tick to avoid spike)
    final derivative = _firstTick ? 0.0 : (error - _prevError) / dtSeconds;
    _prevError = error;
    _firstTick = false;

    // PID output is in duty-cycle units (autotuner divides by nominalVoltage).
    // Convert to volts so it can be summed with feedforward (which is in volts).
    final nomV = _physics.nominalVoltage;
    final pidOutput = (kP * error + kI * _integralAccum + kD * derivative) * nomV;

    // FeedForward: kS*sign(setpoint) + kV*setpoint + gravity compensation
    double ffOutput = ffKs * (setpointRpm > 0 ? 1.0 : (setpointRpm < 0 ? -1.0 : 0.0))
        + ffKv * setpointRpm;
    ffOutput += ffKg; // constant gravity (elevators); 0 for non-elevator
    if (ffKcos != 0.0) {
      // Arm gravity: kCos * cos(position * kCosRatio * 2π)
      final measuredPos = _physics.noisyPositionRotations;
      final absRotations = measuredPos * (ffKcosRatio != 0 ? ffKcosRatio : 1.0);
      ffOutput += ffKcos * _cos(absRotations * 2.0 * 3.14159265);
    }

    // Total output clamped to nominal voltage range
    final total = pidOutput + ffOutput;
    return (total / nomV).clamp(minOut, maxOut) * nomV;
  }

  /// Compute voltage for position closed-loop control.
  ///
  /// The SPARK's position PID computes:
  ///   output = kP*error + kI*integral + kD*derivative
  ///          + kS*sign(error) + kG (elevator) or kCos*cos(pos) (arm)
  double computePosition(double setpointRotations, double dtSeconds) {
    final kP = _params.getParamSync(kParamSlot0P);
    final kI = _params.getParamSync(kParamSlot0I);
    final kD = _params.getParamSync(kParamSlot0D);
    final iZone = _params.getParamSync(kParamSlot0IZone);
    final maxOut = _params.getParamSync(kParamSlot0MaxOutput);
    final minOut = _params.getParamSync(kParamSlot0MinOutput);

    final ffKs = _params.getParamSync(kParamSlot0FfKs);
    final ffKg = _params.getParamSync(kParamSlot0FfKg);
    final ffKcos = _params.getParamSync(kParamSlot0FfKcos);
    final ffKcosRatio = _params.getParamSync(kParamSlot0FfKcosRatio);

    final measuredPos = _physics.noisyPositionRotations;
    final error = setpointRotations - measuredPos;

    // Integral with anti-windup
    if (iZone <= 0 || error.abs() < iZone) {
      _integralAccum += error * dtSeconds;
    } else {
      _integralAccum = 0.0;
    }

    // Derivative
    final derivative = _firstTick ? 0.0 : (error - _prevError) / dtSeconds;
    _prevError = error;
    _firstTick = false;

    // PID output is in duty-cycle units (autotuner divides by nominalVoltage).
    // Convert to volts so it can be summed with feedforward (which is in volts).
    final nomV = _physics.nominalVoltage;
    final pidOutput = (kP * error + kI * _integralAccum + kD * derivative) * nomV;

    // FeedForward: kS*sign(error) + kG (elevator) or kCos*cos(pos) (arm)
    // kV is NOT applied in position mode per REV docs
    double ffOutput = ffKs * (error > 0 ? 1.0 : (error < 0 ? -1.0 : 0.0));
    ffOutput += ffKg; // constant gravity (elevators); 0 for non-elevator
    if (ffKcos != 0.0) {
      // Arm gravity: kCos * cos(position * kCosRatio * 2π)
      // kCosRatio converts user units → absolute rotations
      final absRotations = measuredPos * (ffKcosRatio != 0 ? ffKcosRatio : 1.0);
      ffOutput += ffKcos * _cos(absRotations * 2.0 * 3.14159265);
    }

    final total = pidOutput + ffOutput;
    return (total / nomV).clamp(minOut, maxOut) * nomV;
  }

  /// Simple cos without importing dart:math in this library.
  static double _cos(double x) {
    // Use Taylor series approximation (sufficient for simulation).
    // Normalize to [-π, π].
    const pi = 3.14159265358979;
    x = x % (2 * pi);
    if (x > pi) x -= 2 * pi;
    if (x < -pi) x += 2 * pi;
    final x2 = x * x;
    return 1 - x2 / 2 + x2 * x2 / 24 - x2 * x2 * x2 / 720;
  }
}

// ---------------------------------------------------------------------------
// Simulated control API
// ---------------------------------------------------------------------------

/// A control API that feeds voltage commands into the physics model.
///
/// Open-loop modes (voltage, duty cycle) pass through directly.
/// Closed-loop modes (velocity, position) use the [SimulatedPidFfController]
/// to emulate the SPARK's internal PID + FeedForward loop.
///
/// MAXMotion position mode additionally runs a trapezoidal motion profile
/// generator that limits cruise velocity and acceleration before feeding
/// the profiled setpoint into the PID position controller.
class SimulatedControlApi implements IControlApi {
  final SimulatedPhysics _physics;
  final SimulatedParameterApi _paramApi;
  SimulatedPidFfController? _pidFf;

  /// The current control mode and setpoint for closed-loop ticking.
  int _activeControlType = kControlTypeVoltage;
  double _activeSetpoint = 0.0;

  // MAXMotion profile state --------------------------------------------------
  /// Current profiled position setpoint (rotations) fed to the PID.
  double _profiledSetpoint = 0.0;
  /// Current profiled velocity (rotations / s) used to advance the profile.
  double _profiledVelocity = 0.0;
  /// Current profiled acceleration (rotations / s²) — used by S-curve mode.
  double _profiledAccel = 0.0;
  /// Whether the profile has been initialised for the current move.
  bool _profileInitialised = false;

  SimulatedControlApi(this._physics, this._paramApi);

  /// Attach a PID+FF controller for closed-loop simulation.
  void attachPidFfController(SimulatedPidFfController controller) {
    _pidFf = controller;
  }

  /// Called every simulation tick to update closed-loop output.
  void tick(double dtSeconds) {
    if (_pidFf == null) return;
    if (_activeControlType == kControlTypeVelocity) {
      _physics.commandedVoltage =
          _pidFf!.computeVelocity(_activeSetpoint, dtSeconds);
    } else if (_activeControlType == kControlTypeMAXMotionPosition) {
      // Run motion profile (trapezoidal or S-curve) to produce a setpoint.
      final posMode = _paramApi
          .getParamSync(kParamMAXMotionPositionMode0)
          .round();
      if (posMode == kMAXMotionPositionModeSCurve) {
        _advanceSCurveProfile(dtSeconds);
      } else {
        _advanceTrapezoidalProfile(dtSeconds);
      }
      _physics.commandedVoltage =
          _pidFf!.computePosition(_profiledSetpoint, dtSeconds);
    } else if (_activeControlType == kControlTypePosition) {
      _physics.commandedVoltage =
          _pidFf!.computePosition(_activeSetpoint, dtSeconds);
    }
  }

  // -------------------------------------------------------------------------
  // Shared profile initialisation & parameter reading
  // -------------------------------------------------------------------------

  void _initProfileIfNeeded() {
    if (!_profileInitialised) {
      _profiledSetpoint = _physics.noisyPositionRotations;
      _profiledVelocity = 0.0;
      _profiledAccel = 0.0;
      _profileInitialised = true;
    }
  }

  ({double cruise, double maxAccel, double maxJerk, double allowedError})
      _readProfileParams() {
    final cruiseRpm =
        _paramApi.getParamSync(kParamMAXMotionCruiseVelocity0).abs();
    final maxAccelRpmPerS =
        _paramApi.getParamSync(kParamMAXMotionMaxAccel0).abs();
    final maxJerkRpmPerS2 =
        _paramApi.getParamSync(kParamMAXMotionMaxJerk0).abs();
    final allowedErrorRot =
        _paramApi.getParamSync(kParamMAXMotionAllowedError0).abs();
    return (
      cruise: cruiseRpm / 60.0,           // rot/s
      maxAccel: maxAccelRpmPerS / 60.0,   // rot/s²
      maxJerk: maxJerkRpmPerS2 / 60.0,    // rot/s³
      allowedError: allowedErrorRot,       // rot
    );
  }

  // -------------------------------------------------------------------------
  // Trapezoidal (acceleration-limited) profile
  // -------------------------------------------------------------------------

  void _advanceTrapezoidalProfile(double dt) {
    _initProfileIfNeeded();
    final p = _readProfileParams();

    final errorRot = _activeSetpoint - _profiledSetpoint;

    if (errorRot.abs() <= p.allowedError && p.allowedError > 0) {
      _profiledSetpoint = _activeSetpoint;
      _profiledVelocity = 0.0;
      return;
    }

    final direction = errorRot >= 0 ? 1.0 : -1.0;
    final absVel = _profiledVelocity.abs();
    final decelDist = p.maxAccel > 0
        ? (absVel * absVel) / (2.0 * p.maxAccel)
        : 0.0;

    double desiredVel;
    if (errorRot.abs() <= decelDist && absVel > 0) {
      desiredVel = direction *
          (absVel - p.maxAccel * dt).clamp(0.0, double.infinity);
    } else {
      desiredVel = direction * p.cruise;
    }

    if (p.maxAccel > 0) {
      final maxDeltaV = p.maxAccel * dt;
      final deltaV = desiredVel - _profiledVelocity;
      if (deltaV.abs() > maxDeltaV) {
        _profiledVelocity += maxDeltaV * (deltaV >= 0 ? 1.0 : -1.0);
      } else {
        _profiledVelocity = desiredVel;
      }
    } else {
      _profiledVelocity = desiredVel;
    }

    if (_profiledVelocity.abs() > p.cruise && p.cruise > 0) {
      _profiledVelocity = p.cruise * (_profiledVelocity >= 0 ? 1.0 : -1.0);
    }

    _profiledSetpoint += _profiledVelocity * dt;

    if (direction > 0 && _profiledSetpoint > _activeSetpoint) {
      _profiledSetpoint = _activeSetpoint;
      _profiledVelocity = 0.0;
    } else if (direction < 0 && _profiledSetpoint < _activeSetpoint) {
      _profiledSetpoint = _activeSetpoint;
      _profiledVelocity = 0.0;
    }
  }

  // -------------------------------------------------------------------------
  // S-curve (jerk-limited) profile
  // -------------------------------------------------------------------------

  /// Advance the jerk-limited S-curve profile by [dt] seconds.
  ///
  /// The key difference from trapezoidal: instead of applying acceleration
  /// instantaneously, acceleration is ramped at [maxJerk] rot/s³. This
  /// produces smooth velocity curves (the "S" shape).
  void _advanceSCurveProfile(double dt) {
    _initProfileIfNeeded();
    final p = _readProfileParams();

    final errorRot = _activeSetpoint - _profiledSetpoint;

    if (errorRot.abs() <= p.allowedError && p.allowedError > 0) {
      _profiledSetpoint = _activeSetpoint;
      _profiledVelocity = 0.0;
      _profiledAccel = 0.0;
      return;
    }

    final direction = errorRot >= 0 ? 1.0 : -1.0;
    final absVel = _profiledVelocity.abs();
    final jerk = p.maxJerk > 0 ? p.maxJerk : p.maxAccel / 0.05;

    // Distance to stop from current velocity considering we must also
    // ramp acceleration down to zero via jerk.
    // For an S-curve decel: we need to ramp accel from 0 to -maxAccel
    // (jerk phase), cruise at -maxAccel, then ramp accel back to 0.
    // Approximate stopping distance:
    //   d_stop ≈ v²/(2*a) + v*a/(2*j)
    // The extra term accounts for the jerk ramp.
    final decelDist = p.maxAccel > 0
        ? (absVel * absVel) / (2.0 * p.maxAccel) +
            absVel * p.maxAccel / (2.0 * jerk)
        : 0.0;

    // Determine desired acceleration.
    double desiredAccel;
    if (errorRot.abs() <= decelDist && absVel > 0) {
      // Decelerating — target negative accel (opposite to direction).
      desiredAccel = -direction * p.maxAccel;
    } else if (absVel < p.cruise) {
      // Accelerating — target positive accel (same as direction).
      desiredAccel = direction * p.maxAccel;
    } else {
      // At cruise — zero acceleration.
      desiredAccel = 0.0;
    }

    // Apply jerk limit to acceleration.
    final maxDeltaA = jerk * dt;
    final deltaA = desiredAccel - _profiledAccel;
    if (deltaA.abs() > maxDeltaA) {
      _profiledAccel += maxDeltaA * (deltaA >= 0 ? 1.0 : -1.0);
    } else {
      _profiledAccel = desiredAccel;
    }

    // Clamp acceleration magnitude.
    if (_profiledAccel.abs() > p.maxAccel) {
      _profiledAccel = p.maxAccel * (_profiledAccel >= 0 ? 1.0 : -1.0);
    }

    // Update velocity from acceleration.
    _profiledVelocity += _profiledAccel * dt;

    // Clamp velocity to cruise.
    if (_profiledVelocity.abs() > p.cruise && p.cruise > 0) {
      _profiledVelocity = p.cruise * (_profiledVelocity >= 0 ? 1.0 : -1.0);
      // If we hit cruise, zero out the acceleration to stop pushing.
      if (_profiledAccel * _profiledVelocity > 0) {
        _profiledAccel = 0.0;
      }
    }

    // Advance position setpoint.
    _profiledSetpoint += _profiledVelocity * dt;

    // Don't overshoot the target.
    if (direction > 0 && _profiledSetpoint > _activeSetpoint) {
      _profiledSetpoint = _activeSetpoint;
      _profiledVelocity = 0.0;
      _profiledAccel = 0.0;
    } else if (direction < 0 && _profiledSetpoint < _activeSetpoint) {
      _profiledSetpoint = _activeSetpoint;
      _profiledVelocity = 0.0;
      _profiledAccel = 0.0;
    }
  }

  @override
  void setSetpoint(double value, int controlType, {int pidSlot = 0}) {
    final previousControlType = _activeControlType;
    _activeControlType = controlType;
    _activeSetpoint = value;

    if (controlType == kControlTypeVoltage) {
      _pidFf?.reset();
      _physics.commandedVoltage = value;
    } else if (controlType == kControlTypeDutyCycle) {
      _pidFf?.reset();
      _physics.commandedVoltage = value * _physics.nominalVoltage;
    } else if (controlType == kControlTypeMAXMotionPosition) {
      // Reset profile state when switching to MAXMotion so the profile
      // starts from the current position.
      if (previousControlType != controlType) {
        _pidFf?.reset();
        _profileInitialised = false;
        _profiledAccel = 0.0;
      }
    } else {
      // Closed-loop modes — only reset PID when switching from a different
      // control type.  A real SPARK does NOT reset its PID state on every
      // setpoint write; integral and derivative must accumulate.
      if (previousControlType != controlType) {
        _pidFf?.reset();
      }
    }
  }

  @override
  void setDutyCycle(double dutyCycle) =>
      setSetpoint(dutyCycle, kControlTypeDutyCycle);

  @override
  void setVelocity(double rpm, {int pidSlot = 0}) =>
      setSetpoint(rpm, kControlTypeVelocity, pidSlot: pidSlot);

  @override
  void setVoltage(double volts) =>
      setSetpoint(volts, kControlTypeVoltage);

  @override
  void setPosition(double rotations, {int pidSlot = 0}) =>
      setSetpoint(rotations, kControlTypePosition, pidSlot: pidSlot);

  @override
  void setSmartMotion(double rotations, {int pidSlot = 0}) =>
      setSetpoint(rotations, kControlTypeMAXMotionPosition, pidSlot: pidSlot);

  @override
  void setCurrent(double amps, {int pidSlot = 0}) =>
      setSetpoint(amps, kControlTypeCurrent, pidSlot: pidSlot);

  @override
  void stop() {
    _activeControlType = kControlTypeVoltage;
    _activeSetpoint = 0.0;
    _pidFf?.reset();
    _physics.commandedVoltage = 0.0;
  }

  @override
  Future<SparkResponse> identify() async {
    return SparkResponse(
      responseType: kUsbResponseAck,
      arbId: 0,
      payload: Uint8List(8),
    );
  }

  @override
  Future<SparkResponse> clearFaults() async {
    return SparkResponse(
      responseType: kUsbResponseAck,
      arbId: 0,
      payload: Uint8List(8),
    );
  }

  @override
  Future<SparkResponse> factoryReset() async {
    _pidFf?.reset();
    _activeControlType = kControlTypeVoltage;
    _activeSetpoint = 0.0;
    _physics.reset();
    return SparkResponse(
      responseType: kUsbResponseAck,
      arbId: 0,
      payload: Uint8List(8),
    );
  }

  @override
  void setStatusFrameRate(int statusIndex, int rateMs) {
    // No-op for simulation.
  }

  @override
  void configureForSysId() {
    // No-op for simulation.
  }

  @override
  void restoreDefaultFrameRates() {
    // No-op for simulation.
  }
}

// ---------------------------------------------------------------------------
// Simulated parameter API
// ---------------------------------------------------------------------------

/// A parameter API that stores values in memory.
class SimulatedParameterApi implements IParameterApi {
  final Map<int, double> _params = {
    kParamCanId: 42.0,
    kParamMotorType: 1.0, // brushless
    kParamIdleMode: 0.0, // coast
    kParamOpenLoopRampRate: 0.0,
    kParamMotorInverted: 0.0,
    kParamPositionConvFactor: 1.0,
    kParamVelocityConvFactor: 1.0,
    kParamSlot0P: 0.0,
    kParamSlot0I: 0.0,
    kParamSlot0D: 0.0,
    kParamSlot0F: 0.0, // = kParamSlot0FfKv (same ID: velocity FF)
    kParamSlot0IZone: 0.0,
    kParamSlot0DFilter: 0.0,
    kParamSlot0MaxOutput: 1.0,
    kParamSlot0MinOutput: -1.0,
    kParamSmartCurrentLimit: 40.0,
    kParamSecondaryCurrentLimit: 80.0,
    kParamClosedLoopRampRate: 0.0,
    kParamForwardSoftLimit: 0.0,
    kParamForwardSoftLimitEnabled: 0.0,
    kParamReverseSoftLimit: 0.0,
    kParamReverseSoftLimitEnabled: 0.0,
    kParamFollowerId: 0.0,
    kParamFollowerConfig: 0.0,
    // FeedForward Slot 0 defaults (kV omitted — shared with kParamSlot0F)
    kParamSlot0FfKs: 0.0,
    kParamSlot0FfKa: 0.0,
    kParamSlot0FfKg: 0.0,
    kParamSlot0FfKcos: 0.0,
    kParamSlot0FfKcosRatio: 0.0,
    // MAXMotion Slot 0 defaults
    kParamMAXMotionCruiseVelocity0: 0.0,
    kParamMAXMotionMaxAccel0: 0.0,
    kParamMAXMotionMaxJerk0: 0.0,
    kParamMAXMotionAllowedError0: 0.0,
    kParamMAXMotionPositionMode0: 0.0,
  };

  /// Synchronous parameter read for the simulated PID controller.
  double getParamSync(int paramId) => _params[paramId] ?? 0.0;

  @override
  Future<SparkResponse> setParameter(int paramId, double value) async {
    _params[paramId] = value;
    return SparkResponse(
      responseType: kUsbResponseAck,
      arbId: 0,
      payload: Uint8List(8),
    );
  }

  @override
  Future<double> getParameter(int paramId) async {
    return _params[paramId] ?? 0.0;
  }

  @override
  Future<void> burnFlash({IHeartbeatManager? heartbeat}) async {
    // Simulated — nothing to persist.
  }

  // -- CAN ID ---------------------------------------------------------------

  @override
  Future<int> getCanId() async => (_params[kParamCanId] ?? 42).toInt();

  @override
  Future<void> setCanId(int canId) =>
      setParameter(kParamCanId, canId.toDouble());

  // -- Motor config ---------------------------------------------------------

  @override
  Future<void> setMotorType(int type) =>
      setParameter(kParamMotorType, type.toDouble());

  @override
  Future<void> setIdleMode(int mode) =>
      setParameter(kParamIdleMode, mode.toDouble());

  @override
  Future<void> setMotorInverted(bool inverted) =>
      setParameter(kParamMotorInverted, inverted ? 1.0 : 0.0);

  @override
  Future<void> setOpenLoopRampRate(double seconds) =>
      setParameter(kParamOpenLoopRampRate, seconds);

  // -- Conversion factors ---------------------------------------------------

  @override
  Future<void> setPositionConversionFactor(double factor) =>
      setParameter(kParamPositionConvFactor, factor);

  @override
  Future<void> setVelocityConversionFactor(double factor) =>
      setParameter(kParamVelocityConvFactor, factor);

  @override
  Future<double> getPositionConversionFactor() =>
      getParameter(kParamPositionConvFactor);

  @override
  Future<double> getVelocityConversionFactor() =>
      getParameter(kParamVelocityConvFactor);

  // -- PID Slot 0 -----------------------------------------------------------

  @override
  Future<void> setSlot0P(double value) =>
      setParameter(kParamSlot0P, value);

  @override
  Future<void> setSlot0I(double value) =>
      setParameter(kParamSlot0I, value);

  @override
  Future<void> setSlot0D(double value) =>
      setParameter(kParamSlot0D, value);

  @override
  Future<void> setSlot0F(double value) =>
      setParameter(kParamSlot0F, value);

  @override
  Future<void> setSlot0IZone(double value) =>
      setParameter(kParamSlot0IZone, value);

  @override
  Future<void> setSlot0DFilter(double value) =>
      setParameter(kParamSlot0DFilter, value);

  @override
  Future<void> setSlot0MaxOutput(double value) =>
      setParameter(kParamSlot0MaxOutput, value);

  @override
  Future<void> setSlot0MinOutput(double value) =>
      setParameter(kParamSlot0MinOutput, value);

  @override
  Future<void> setPidSlot0({
    required double p,
    required double i,
    required double d,
    double f = 0.0,
    double iZone = 0.0,
    double dFilter = 0.0,
    double maxOutput = 1.0,
    double minOutput = -1.0,
  }) async {
    await setSlot0P(p);
    await setSlot0I(i);
    await setSlot0D(d);
    await setSlot0F(f);
    await setSlot0IZone(iZone);
    await setSlot0DFilter(dFilter);
    await setSlot0MaxOutput(maxOutput);
    await setSlot0MinOutput(minOutput);
  }

  @override
  Future<PidGains> getPidSlot0() async {
    return PidGains(
      p: await getParameter(kParamSlot0P),
      i: await getParameter(kParamSlot0I),
      d: await getParameter(kParamSlot0D),
      f: await getParameter(kParamSlot0F),
      iZone: await getParameter(kParamSlot0IZone),
      maxOutput: await getParameter(kParamSlot0MaxOutput),
      minOutput: await getParameter(kParamSlot0MinOutput),
    );
  }

  // -- Current limits -------------------------------------------------------

  @override
  Future<void> setSmartCurrentLimit(double amps) =>
      setParameter(kParamSmartCurrentLimit, amps);

  @override
  Future<void> setSecondaryCurrentLimit(double amps) =>
      setParameter(kParamSecondaryCurrentLimit, amps);

  // -- Soft limits ----------------------------------------------------------

  @override
  Future<void> setForwardSoftLimit(double rotations) =>
      setParameter(kParamForwardSoftLimit, rotations);

  @override
  Future<void> setForwardSoftLimitEnabled(bool enabled) =>
      setParameter(kParamForwardSoftLimitEnabled, enabled ? 1.0 : 0.0);

  @override
  Future<void> setReverseSoftLimit(double rotations) =>
      setParameter(kParamReverseSoftLimit, rotations);

  @override
  Future<void> setReverseSoftLimitEnabled(bool enabled) =>
      setParameter(kParamReverseSoftLimitEnabled, enabled ? 1.0 : 0.0);

  @override
  Future<void> configureSoftLimits({
    required double forwardLimit,
    required double reverseLimit,
  }) async {
    await setForwardSoftLimit(forwardLimit);
    await setForwardSoftLimitEnabled(true);
    await setReverseSoftLimit(reverseLimit);
    await setReverseSoftLimitEnabled(true);
  }

  @override
  Future<void> disableSoftLimits() async {
    await setForwardSoftLimitEnabled(false);
    await setReverseSoftLimitEnabled(false);
  }

  // -- Follower -------------------------------------------------------------

  @override
  Future<void> configureFollower(
    int leaderDeviceId, {
    int followerType = kFollowerConfigREV,
  }) async {
    await setParameter(kParamFollowerId, leaderDeviceId.toDouble());
    await setParameter(kParamFollowerConfig, followerType.toDouble());
  }

  // -- FeedForward Slot 0 ---------------------------------------------------

  @override
  Future<void> setSlot0FfKs(double value) =>
      setParameter(kParamSlot0FfKs, value);

  @override
  Future<void> setSlot0FfKv(double value) =>
      setParameter(kParamSlot0FfKv, value);

  @override
  Future<void> setSlot0FfKa(double value) =>
      setParameter(kParamSlot0FfKa, value);

  @override
  Future<void> setSlot0FfKg(double value) =>
      setParameter(kParamSlot0FfKg, value);

  @override
  Future<void> setSlot0FfKcos(double value) =>
      setParameter(kParamSlot0FfKcos, value);

  @override
  Future<void> setSlot0FfKcosRatio(double value) =>
      setParameter(kParamSlot0FfKcosRatio, value);

  @override
  Future<void> setFeedForwardSlot0({
    double kS = 0.0,
    double kV = 0.0,
    double kA = 0.0,
    double kG = 0.0,
    double kCos = 0.0,
    double kCosRatio = 0.0,
  }) async {
    await setSlot0FfKs(kS);
    await setSlot0FfKv(kV);
    await setSlot0FfKa(kA);
    await setSlot0FfKg(kG);
    await setSlot0FfKcos(kCos);
    await setSlot0FfKcosRatio(kCosRatio);
  }

  @override
  Future<ControllerFeedForward> getFeedForwardSlot0() async {
    return ControllerFeedForward(
      kS: await getParameter(kParamSlot0FfKs),
      kV: await getParameter(kParamSlot0FfKv),
      kA: await getParameter(kParamSlot0FfKa),
      kG: await getParameter(kParamSlot0FfKg),
      kCos: await getParameter(kParamSlot0FfKcos),
      kCosRatio: await getParameter(kParamSlot0FfKcosRatio),
    );
  }

  // -- MAXMotion Slot 0 -----------------------------------------------------

  @override
  Future<void> setMAXMotionCruiseVelocity(double value) =>
      setParameter(kParamMAXMotionCruiseVelocity0, value);

  @override
  Future<void> setMAXMotionMaxAccel(double value) =>
      setParameter(kParamMAXMotionMaxAccel0, value);

  @override
  Future<void> setMAXMotionMaxJerk(double value) =>
      setParameter(kParamMAXMotionMaxJerk0, value);

  @override
  Future<void> setMAXMotionAllowedError(double value) =>
      setParameter(kParamMAXMotionAllowedError0, value);

  @override
  Future<void> setMAXMotionPositionMode(int mode) =>
      setParameter(kParamMAXMotionPositionMode0, mode.toDouble());

  @override
  Future<void> configureMAXMotionSlot0({
    required double cruiseVelocity,
    required double maxAcceleration,
    double maxJerk = 0.0,
    double allowedError = 0.0,
    int positionMode = 0,
  }) async {
    await setMAXMotionCruiseVelocity(cruiseVelocity);
    await setMAXMotionMaxAccel(maxAcceleration);
    await setMAXMotionMaxJerk(maxJerk);
    await setMAXMotionAllowedError(allowedError);
    await setMAXMotionPositionMode(positionMode);
  }
}
