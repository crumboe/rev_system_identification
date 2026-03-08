/// High-level API for reading and writing SPARK controller parameters.
///
/// Wraps the low-level CAN parameter protocol (API Class 0x01) with
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
  Future<SparkResponse> setParameter(int paramId, double value) async {
    // Prefer modern firmware write frame (apiClass 0x0E, index 0).
    // Fall back to legacy parameter-set on timeout.
    try {
      final requestArb = buildArbId(
        apiClass: kApiClassParameterWrite,
        apiIndex: kParamWriteIndexRequest,
        deviceId: _deviceId,
      );

      final payload = Uint8List(8);
      payload[0] = paramId & 0xFF;
      final bd = ByteData.sublistView(payload);
      // Modern protocol carries raw 32-bit parameter value. Encode known
      // integer/bool params as uint32 to avoid type-mismatch rejects.
      if (_isIntegerLikeParam(paramId)) {
        bd.setUint32(1, value.round() & 0xFFFFFFFF, Endian.little);
      } else {
        bd.setFloat32(1, value, Endian.little);
      }

      final response = await _sendAndReceiveExpected(
        requestArb,
        payload,
        expectedApiClass: kApiClassParameterWrite,
        expectedApiIndex: kParamWriteIndexResponse,
      );

      // Modern write response: [paramId, paramType, value(4), resultCode]
      if (response.payload.length >= 7) {
        final resultCode = response.payload[6];
        if (resultCode != 0) {
          throw StateError(
            'Parameter write failed (id=$paramId, resultCode=$resultCode)',
          );
        }
      }

      return response;
    } on TimeoutException {
      final arbId = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexSet,
        deviceId: _deviceId,
      );
      final payload = buildParamSetPayload(value, paramId);
      return _conn.sendAndReceive(arbId, payload);
    }
  }

  /// Get a parameter by ID. Returns the float32 value from the response.
  Future<double> getParameter(int paramId) async {
    // Prefer the modern read-pair protocol used by >=25.0 firmware.
    // If that times out, fall back to the legacy parameter-get frame.
    try {
      return await _getParameterModern(paramId);
    } on TimeoutException {
      // Legacy path for older firmware/protocol variants.
      final arbId = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: _deviceId,
      );
      final payload = buildParamGetPayload(paramId);
      final response = await _conn.sendAndReceive(arbId, payload);
      return readFloat32(response.payload, 0);
    }
  }

  Future<double> _getParameterModern(int paramId) async {
    final pairIndex = (paramId ~/ 2) & 0x0F;
    final arbId = buildArbId(
      apiClass: kApiClassParameterRead,
      apiIndex: pairIndex,
      deviceId: _deviceId,
    );

    // Read-pair frames carry two raw uint32 parameter values in the response.
    final payload = Uint8List(8);
    // Modern read responses arrive in API class 0x2F with same index.
    final response = await _sendAndReceiveExpected(
      arbId,
      payload,
      expectedApiClass: kApiClassParameterRead | 0x20,
      expectedApiIndex: pairIndex,
    );

    final offset = (paramId & 1) == 0 ? 0 : 4;
    final raw = readUint32(response.payload, offset);

    // CAN ID is integer-typed in modern frames; do not reinterpret as float.
    if (paramId == kParamCanId) {
      return raw.toDouble();
    }

    // Most tunable parameters are float32; interpret raw bits as float.
    final bytes = ByteData(4)..setUint32(0, raw, Endian.little);
    return bytes.getFloat32(0, Endian.little);
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
  Future<SparkResponse> burnFlash() async {
    // Modern persist command: apiClass 0x01, index 0x03 with response at 0x04.
    try {
      final modernArbId = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: 0x03,
        deviceId: _deviceId,
      );
      return await _sendAndReceiveExpected(
        modernArbId,
        Uint8List(0),
        expectedApiClass: kApiClassParameter,
        expectedApiIndex: 0x04,
        timeout: const Duration(seconds: 2),
      );
    } on TimeoutException {
      final legacyArbId = buildArbId(
        apiClass: kApiClassSystem,
        apiIndex: kSystemIndexBurnFlash,
        deviceId: _deviceId,
      );
      return _conn.sendAndReceive(
        legacyArbId,
        Uint8List(8),
        timeout: const Duration(seconds: 2),
      );
    }
  }

  // -----------------------------------------------------------------------
  // CAN ID
  // -----------------------------------------------------------------------

  /// Read the device's CAN ID (parameter 0).
  Future<int> getCanId() async {
    try {
      // For CAN ID specifically, do not fall back to legacy 0x01 polling
      // because modern firmware commonly answers on 0x2F or only broadcasts
      // status, which can otherwise generate repeated timeout spam.
      final value = await _getParameterModern(kParamCanId);
      final canId = value.toInt();
      if (canId >= 0 && canId <= kMaxCanDeviceId) {
        return canId;
      }
    } catch (_) {
      // Fall through to status-frame based fallback below.
    }

    // Fallback: infer CAN ID from any inbound status frame's device-id bits.
    // This avoids mis-reporting when a non-parameter DATA frame (e.g. 0x2F/0)
    // is matched by firmware behavior differences.
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
