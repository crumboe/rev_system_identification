/// High-level API for reading and writing SPARK controller parameters.
///
/// Wraps the low-level CAN parameter protocol (API Class 0x01) with
/// named getters/setters for commonly-used configuration values.
library;

import 'dart:typed_data';

import 'spark_protocol.dart';
import 'spark_connection.dart';

/// Provides typed access to SPARK controller parameters.
class ParameterApi {
  final SparkConnection _conn;
  final int _deviceId;

  ParameterApi(this._conn, {int deviceId = 0}) : _deviceId = deviceId;

  // -----------------------------------------------------------------------
  // Low-level parameter access
  // -----------------------------------------------------------------------

  /// Set a parameter by ID with a float32 value.
  Future<SparkResponse> setParameter(int paramId, double value) {
    final arbId = buildArbId(
      apiClass: kApiClassParameter,
      apiIndex: kParamIndexSet,
      deviceId: _deviceId,
    );
    final payload = buildParamSetPayload(value, paramId);
    return _conn.sendAndReceive(arbId, payload);
  }

  /// Get a parameter by ID. Returns the float32 value from the response.
  Future<double> getParameter(int paramId) async {
    final arbId = buildArbId(
      apiClass: kApiClassParameter,
      apiIndex: kParamIndexGet,
      deviceId: _deviceId,
    );
    final payload = buildParamGetPayload(paramId);
    final response = await _conn.sendAndReceive(arbId, payload);
    return readFloat32(response.payload, 0);
  }

  /// Burn all current parameters to flash (persist across power cycles).
  Future<SparkResponse> burnFlash() {
    final arbId = buildArbId(
      apiClass: kApiClassSystem,
      apiIndex: kSystemIndexBurnFlash,
      deviceId: _deviceId,
    );
    return _conn.sendAndReceive(
      arbId,
      Uint8List(8),
      timeout: const Duration(seconds: 2),
    );
  }

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
}

/// Represents a set of PID gains.
class PidGains {
  final double p;
  final double i;
  final double d;
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
