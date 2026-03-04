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
import '../can/parameter_api.dart' show PidGains;
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

  SimulatedSparkConnection(this.physics, {String? portName})
      : _portName = portName ?? '🧪 ${physics.label}';

  @override
  void open() {
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
    physics.step(physics.commandedVoltage, 0.010);

    lastStatus0 = const StatusFrame0(
      appliedOutput: 0.0,
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
// Simulated control API
// ---------------------------------------------------------------------------

/// A control API that feeds voltage commands into the physics model.
class SimulatedControlApi implements IControlApi {
  final SimulatedPhysics _physics;

  SimulatedControlApi(this._physics);

  @override
  void setSetpoint(double value, int controlType, {int pidSlot = 0}) {
    if (controlType == kControlTypeVoltage) {
      _physics.commandedVoltage = value;
    } else if (controlType == kControlTypeDutyCycle) {
      _physics.commandedVoltage = value * _physics.nominalVoltage;
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
      setSetpoint(rotations, kControlTypeSmartMotion, pidSlot: pidSlot);

  @override
  void setCurrent(double amps, {int pidSlot = 0}) =>
      setSetpoint(amps, kControlTypeCurrent, pidSlot: pidSlot);

  @override
  void stop() {
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
    kParamSlot0F: 0.0,
    kParamSlot0IZone: 0.0,
    kParamSlot0DFilter: 0.0,
    kParamSlot0MaxOutput: 1.0,
    kParamSlot0MinOutput: -1.0,
    kParamSmartCurrentLimit: 40.0,
    kParamSecondaryCurrentLimit: 80.0,
    kParamForwardSoftLimit: 0.0,
    kParamForwardSoftLimitEnabled: 0.0,
    kParamReverseSoftLimit: 0.0,
    kParamReverseSoftLimitEnabled: 0.0,
    kParamFollowerId: 0.0,
    kParamFollowerConfig: 0.0,
  };

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
  Future<SparkResponse> burnFlash() async {
    return SparkResponse(
      responseType: kUsbResponseAck,
      arbId: 0,
      payload: Uint8List(8),
    );
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
}
