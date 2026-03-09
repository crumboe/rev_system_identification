/// High-level API for reading and writing SPARK controller parameters.
///
/// Uses the modern CAN parameter protocol (API Classes 0x0E/0x0F) with
/// named getters/setters for commonly-used configuration values.
library;

import 'dart:async';
import 'dart:typed_data';

import 'interfaces.dart';
import 'spark_protocol.dart';

/// Provides typed access to SPARK controller parameters.
class ParameterApi implements IParameterApi {
  final ISparkConnection _conn;
  final int _deviceId;

  ParameterApi(this._conn, {int deviceId = 0}) : _deviceId = deviceId;

  // -----------------------------------------------------------------------
  // Low-level parameter access
  // -----------------------------------------------------------------------

  static const int _matchMask = 0x1FFFFFC0;

  /// Set a parameter by ID with a float32 value.
  ///
  /// Uses API class 7, index 0 (matching the working Python SLCAN protocol).
  /// Payload: [paramId, float32_LE(4), 0, 0, 0]
  /// Python always sends the value as float32, even for integer params.
  Future<SparkResponse> setParameter(int paramId, double value) async {
    final requestArb = buildArbId(
      apiClass: 0x07,
      apiIndex: 0x00,
      deviceId: _deviceId,
    );

    // Match Python: bytes([param_id]) + struct.pack('<f', value) + b'\x00'*3
    final payload = Uint8List(8);
    payload[0] = paramId & 0xFF;
    final bd = ByteData.sublistView(payload);
    bd.setFloat32(1, value, Endian.little);

    _conn.sendCommand(requestArb, payload);

    // Match Python write_param: accept any class-7 response from the device.
    // Python does: api_class != 0x20 (i.e. not a status frame).
    // No index filter — the device may respond on any index.
    final response = await _conn.responses
        .where((r) {
          final cls = extractApiClass(r.arbId);
          final dev = extractDeviceId(r.arbId);
          return cls == 0x07 && dev == _deviceId;
        })
        .first
        .timeout(const Duration(milliseconds: 500));

    return response;
  }

  /// Get a parameter by ID. Returns the numeric value from the response.
  ///
  /// Uses API class 7, index 1 (matching the working Python SLCAN protocol).
  /// Request payload: [paramId, 0, 0, 0, 0, 0, 0, 0]
  /// Response layout (per Python):
  ///   byte[0] = param_id echo
  ///   byte[1] = 0xFF (status OK)
  ///   bytes[2:6] = value (float32/uint32 LE)
  ///   byte[6] = type tag
  Future<double> getParameter(int paramId) async {
    final arbId = buildArbId(
      apiClass: 0x07,
      apiIndex: 0x01,
      deviceId: _deviceId,
    );

    final payload = Uint8List(8);
    payload[0] = paramId & 0xFF;

    _conn.sendCommand(arbId, payload);

    // Match the read-response specifically: class=7, same device.
    // Python's read_param accepts api_class==7 responses.
    final response = await _conn.responses
        .where((r) {
          final cls = extractApiClass(r.arbId);
          final dev = extractDeviceId(r.arbId);
          return cls == 0x07 && dev == _deviceId;
        })
        .first
        .timeout(const Duration(milliseconds: 500));

    // Value is at bytes[2:6] in the response
    if (_isIntegerLikeParam(paramId) || paramId == kParamCanId) {
      return readUint32(response.payload, 2).toDouble();
    }
    return readFloat32(response.payload, 2);
  }

  Future<SparkResponse> _sendAndReceiveExpected(
    int requestArb,
    Uint8List payload, {
    required int expectedApiClass,
    required int expectedApiIndex,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final expectedArb = buildArbId(
      apiClass: expectedApiClass,
      apiIndex: expectedApiIndex,
      deviceId: _deviceId,
    );

    _conn.sendCommand(requestArb, payload);

    return _conn.responses
        .where((r) => (r.arbId & _matchMask) == (expectedArb & _matchMask))
        .first
        .timeout(timeout);
  }

  bool _isIntegerLikeParam(int paramId) {
    switch (paramId) {
      case kParamCanId:
      case kParamMotorType:
      case kParamIdleMode:
      case kParamMotorInverted:
      case kParamForwardSoftLimitEnabled:
      case kParamReverseSoftLimitEnabled:
      case kParamFollowerId:
      case kParamFollowerConfig:
      case kParamMAXMotionPositionMode0:
        return true;
      default:
        return false;
    }
  }

  /// Burn all current parameters to flash (persist across power cycles).
  ///
  /// Firmware 26.x: send apiClass=6, apiIndex=1 with 8 zero bytes.
  /// The device writes to flash and will not respond during this time,
  /// so we wait 200ms before returning rather than expecting a response.
  Future<void> burnFlash() async {
    final arbId = buildArbId(
      apiClass: 0x06,
      apiIndex: 0x01,
      deviceId: _deviceId,
    );
    _conn.sendCommand(arbId, Uint8List(8));
    // Device is writing to flash — wait before sending further commands.
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  // -----------------------------------------------------------------------
  // CAN ID
  // -----------------------------------------------------------------------

  /// Read the device's CAN ID (parameter 0).
  Future<int> getCanId() async {
    try {
      final value = await getParameter(kParamCanId);
      final canId = value.toInt();
      if (canId >= 0 && canId <= kMaxCanDeviceId) {
        return canId;
      }
    } catch (_) {
      // Fall through to status-frame based fallback below.
    }

    // Fallback: infer CAN ID from any inbound status frame's device-id bits.
    final response = await _conn.responses
        .where((r) =>
            r.apiClass == kApiClassNewStatus || r.apiClass == kApiClassStatus)
        .first
        .timeout(const Duration(milliseconds: 500));
    return response.deviceId;
  }

  /// Set the device's CAN ID (0–62). Must call [burnFlash] to persist.
  Future<void> setCanId(int canId) =>
      setParameter(kParamCanId, canId.toDouble());

  // -----------------------------------------------------------------------
  // Motor configuration
  // -----------------------------------------------------------------------

  Future<void> setMotorType(int type) =>
      setParameter(kParamMotorType, type.toDouble());

  Future<void> setIdleMode(int mode) =>
      setParameter(kParamIdleMode, mode.toDouble());

  Future<void> setMotorInverted(bool inverted) =>
      setParameter(kParamMotorInverted, inverted ? 1.0 : 0.0);

  Future<void> setOpenLoopRampRate(double seconds) =>
      setParameter(kParamOpenLoopRampRate, seconds);

  // -----------------------------------------------------------------------
  // Conversion factors
  // -----------------------------------------------------------------------

  Future<void> setPositionConversionFactor(double factor) =>
      setParameter(kParamPositionConvFactor, factor);

  Future<void> setVelocityConversionFactor(double factor) =>
      setParameter(kParamVelocityConvFactor, factor);

  Future<double> getPositionConversionFactor() =>
      getParameter(kParamPositionConvFactor);

  Future<double> getVelocityConversionFactor() =>
      getParameter(kParamVelocityConvFactor);

  // -----------------------------------------------------------------------
  // PID Slot 0
  // -----------------------------------------------------------------------

  Future<void> setSlot0P(double value) =>
      setParameter(kParamSlot0P, value);

  Future<void> setSlot0I(double value) =>
      setParameter(kParamSlot0I, value);

  Future<void> setSlot0D(double value) =>
      setParameter(kParamSlot0D, value);

  Future<void> setSlot0F(double value) =>
      setParameter(kParamSlot0F, value);

  Future<void> setSlot0IZone(double value) =>
      setParameter(kParamSlot0IZone, value);

  Future<void> setSlot0DFilter(double value) =>
      setParameter(kParamSlot0DFilter, value);

  Future<void> setSlot0MaxOutput(double value) =>
      setParameter(kParamSlot0MaxOutput, value);

  Future<void> setSlot0MinOutput(double value) =>
      setParameter(kParamSlot0MinOutput, value);

  /// Set all PID Slot 0 values at once.
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

  /// Read all PID Slot 0 values.
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

  // -----------------------------------------------------------------------
  // Current limits
  // -----------------------------------------------------------------------

  Future<void> setSmartCurrentLimit(double amps) =>
      setParameter(kParamSmartCurrentLimit, amps);

  Future<void> setSecondaryCurrentLimit(double amps) =>
      setParameter(kParamSecondaryCurrentLimit, amps);

  // -----------------------------------------------------------------------
  // Soft limits
  // -----------------------------------------------------------------------

  Future<void> setForwardSoftLimit(double rotations) =>
      setParameter(kParamForwardSoftLimit, rotations);

  Future<void> setForwardSoftLimitEnabled(bool enabled) =>
      setParameter(kParamForwardSoftLimitEnabled, enabled ? 1.0 : 0.0);

  Future<void> setReverseSoftLimit(double rotations) =>
      setParameter(kParamReverseSoftLimit, rotations);

  Future<void> setReverseSoftLimitEnabled(bool enabled) =>
      setParameter(kParamReverseSoftLimitEnabled, enabled ? 1.0 : 0.0);

  /// Configure both soft limits and enable them.
  Future<void> configureSoftLimits({
    required double forwardLimit,
    required double reverseLimit,
  }) async {
    await setForwardSoftLimit(forwardLimit);
    await setForwardSoftLimitEnabled(true);
    await setReverseSoftLimit(reverseLimit);
    await setReverseSoftLimitEnabled(true);
  }

  /// Disable both soft limits.
  Future<void> disableSoftLimits() async {
    await setForwardSoftLimitEnabled(false);
    await setReverseSoftLimitEnabled(false);
  }

  // -----------------------------------------------------------------------
  // Follower
  // -----------------------------------------------------------------------

  /// Configure this controller as a follower of [leaderDeviceId].
  ///
  /// [leaderDeviceId] is the 6-bit CAN device ID of the leader.
  /// [followerType] defaults to REV-to-REV (0x1A).
  Future<void> configureFollower(
    int leaderDeviceId, {
    int followerType = kFollowerConfigREV,
  }) async {
    // Build the leader's arb ID (used as the follower target).
    final leaderArbId = buildArbId(
      apiClass: 0,
      apiIndex: 0,
      deviceId: leaderDeviceId,
    );
    await setParameter(kParamFollowerId, leaderArbId.toDouble());
    await setParameter(kParamFollowerConfig, followerType.toDouble());
  }

  // -----------------------------------------------------------------------
  // FeedForward Slot 0
  // -----------------------------------------------------------------------

  Future<void> setSlot0FfKs(double value) =>
      setParameter(kParamSlot0FfKs, value);

  Future<void> setSlot0FfKv(double value) =>
      setParameter(kParamSlot0FfKv, value);

  Future<void> setSlot0FfKa(double value) =>
      setParameter(kParamSlot0FfKa, value);

  Future<void> setSlot0FfKg(double value) =>
      setParameter(kParamSlot0FfKg, value);

  Future<void> setSlot0FfKcos(double value) =>
      setParameter(kParamSlot0FfKcos, value);

  Future<void> setSlot0FfKcosRatio(double value) =>
      setParameter(kParamSlot0FfKcosRatio, value);

  /// Set all FeedForward Slot 0 values at once.
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

  /// Read all FeedForward Slot 0 values.
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

  // -----------------------------------------------------------------------
  // MAXMotion Slot 0
  // -----------------------------------------------------------------------

  /// Set cruise velocity for MAXMotion Slot 0 (in RPM).
  Future<void> setMAXMotionCruiseVelocity(double value) =>
      setParameter(kParamMAXMotionCruiseVelocity0, value);

  /// Set maximum acceleration for MAXMotion Slot 0 (in RPM/s).
  Future<void> setMAXMotionMaxAccel(double value) =>
      setParameter(kParamMAXMotionMaxAccel0, value);

  /// Set maximum jerk for MAXMotion Slot 0 (in RPM/s², 0 = trapezoidal).
  Future<void> setMAXMotionMaxJerk(double value) =>
      setParameter(kParamMAXMotionMaxJerk0, value);

  /// Set allowed closed-loop error for MAXMotion Slot 0 (in rotations).
  Future<void> setMAXMotionAllowedError(double value) =>
      setParameter(kParamMAXMotionAllowedError0, value);

  /// Set MAXMotion position mode (0 = trapezoidal, 1 = S-curve).
  Future<void> setMAXMotionPositionMode(int mode) =>
      setParameter(kParamMAXMotionPositionMode0, mode.toDouble());

  /// Configure all MAXMotion Slot 0 parameters at once.
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

/// Represents a set of PID gains.
class PidGains {
  final double p;
  final double i;
  final double d;

  /// Legacy velocity feedforward (deprecated — use [ControllerFeedForward]).
  final double f;

  final double iZone;
  final double maxOutput;
  final double minOutput;

  const PidGains({
    this.p = 0.0,
    this.i = 0.0,
    this.d = 0.0,
    this.f = 0.0,
    this.iZone = 0.0,
    this.maxOutput = 1.0,
    this.minOutput = -1.0,
  });

  @override
  String toString() =>
      'PidGains(P=$p, I=$i, D=$d, F=$f, IZone=$iZone, '
      'out=[$minOutput, $maxOutput])';
}

/// Feedforward gains stored on the SPARK controller.
///
/// Maps to the new REV `FeedForwardConfig` API:
///   - [kS]: static friction (V)
///   - [kV]: velocity gain (V / velocity-unit) — velocity modes only
///   - [kA]: acceleration gain (V / accel-unit) — MAXMotion only
///   - [kG]: constant gravity compensation (V) — elevators
///   - [kCos]: cosine gravity compensation (V) — arms
///   - [kCosRatio]: degrees-to-rotations ratio for cos() — arms
class ControllerFeedForward {
  final double kS;
  final double kV;
  final double kA;
  final double kG;
  final double kCos;
  final double kCosRatio;

  const ControllerFeedForward({
    this.kS = 0.0,
    this.kV = 0.0,
    this.kA = 0.0,
    this.kG = 0.0,
    this.kCos = 0.0,
    this.kCosRatio = 0.0,
  });

  @override
  String toString() =>
      'FF(kS=$kS, kV=$kV, kA=$kA, kG=$kG, kCos=$kCos, '
      'kCosRatio=$kCosRatio)';
}
