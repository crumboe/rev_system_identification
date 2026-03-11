/// High-level API for reading and writing SPARK controller parameters.
///
/// Uses the firmware 26.x CAN parameter protocol:
///   - Read:  API Class=0x07, Index=0x01
///   - Write: API Class=0x0E, Index=0x00 (5-byte payload, no type tag)
///   - Write ACK: API Class=0x0E, Index=0x01
///   - Burn:  API Class=0x3F, Index=0x0F (2-byte magic payload)
///   - Burn ACK: API Class=0x01, Index=0x04
///
/// Protocol confirmed from Python `spark_rw_verify.py` (physically verified).
library;

import 'dart:async';
import 'dart:typed_data';

import 'interfaces.dart';
import 'spark_protocol.dart';

/// Result of a raw parameter read, including the type tag from the device.
class ParamReadResult {
  /// The parameter ID echoed back by the device.
  final int paramId;

  /// The type tag from byte[6]: 0x00=bool, 0x02=int, 0x03=float, 0x04=uint.
  final int typeTag;

  /// The raw 4 value bytes (bytes[2:6] of the response).
  final Uint8List rawBytes;

  /// The value interpreted according to [typeTag].
  final double value;

  const ParamReadResult({
    required this.paramId,
    required this.typeTag,
    required this.rawBytes,
    required this.value,
  });

  @override
  String toString() =>
      'ParamReadResult(id=$paramId, type=0x${typeTag.toRadixString(16)}, '
      'value=$value)';
}

/// Exception thrown when a parameter write's read-back value doesn't match
/// the value that was sent.
class ParameterWriteException implements Exception {
  final int paramId;
  final double sentValue;
  final double readBackValue;

  ParameterWriteException({
    required this.paramId,
    required this.sentValue,
    required this.readBackValue,
  });

  @override
  String toString() =>
      'ParameterWriteException: param $paramId — sent $sentValue, '
      'read back $readBackValue';
}

/// Provides typed access to SPARK controller parameters.
class ParameterApi implements IParameterApi {
  final ISparkConnection _conn;
  final int _deviceId;

  ParameterApi(this._conn, {int deviceId = 0}) : _deviceId = deviceId;

  // -----------------------------------------------------------------------
  // Known parameter type tags from the protocol specification.
  // Used as fallback when a read returns type 0x00 for a zero-valued float
  // (firmware bug: zero floats can be misidentified as bool).
  // -----------------------------------------------------------------------

  static const Map<int, int> _knownParamTypes = {
    // uint params
    0: kParamTypeUint,   // kCanID
    1: kParamTypeUint,   // kInputMode (read-only)
    2: kParamTypeUint,   // kMotorType
    5: kParamTypeUint,   // kCtrlType (read-only)
    6: kParamTypeUint,   // kIdleMode
    10: kParamTypeUint,  // kPolePairs
    12: kParamTypeUint,  // kCurrentChopCycles
    57: kParamTypeUint,  // kFollowerID
    58: kParamTypeUint,  // kFollowerConfig
    59: kParamTypeUint,  // kSmartCurrentStallLimit
    60: kParamTypeUint,  // kSmartCurrentFreeLimit
    61: kParamTypeUint,  // kSmartCurrentConfig
    69: kParamTypeUint,  // kEncoderCountsPerRev
    70: kParamTypeUint,  // kEncoderAverageDepth
    71: kParamTypeUint,  // kEncoderSampleDelta
    121: kParamTypeUint, // kAnalogAverageDepth
    122: kParamTypeUint, // kAnalogSensorMode
    124: kParamTypeUint, // kAnalogSampleDelta
    127: kParamTypeUint, // kDataPortConfig
    128: kParamTypeUint, // kAltEncoderCountsPerRev
    129: kParamTypeUint, // kAltEncoderAverageDepth
    130: kParamTypeUint, // kAltEncoderSampleDelta
    // bool params
    50: kParamTypeBool,  // kLimitSwitchFwdPolarity
    51: kParamTypeBool,  // kLimitSwitchRevPolarity
    52: kParamTypeBool,  // kHardLimitFwdEn
    53: kParamTypeBool,  // kHardLimitRevEn
    45: kParamTypeBool,  // kMotorInverted (param 45, bool in REVLib)
    123: kParamTypeBool, // kAnalogInverted
    131: kParamTypeBool, // kAltEncoderInverted
    // float params (selected \u2014 most params 7\u201344, 56, 75\u201395, 96\u2013116, 119\u2013120, 132\u2013133)
    7: kParamTypeFloat,  // kInputDeadband
    11: kParamTypeFloat, // kCurrentChop
    56: kParamTypeFloat, // kRampRate
    75: kParamTypeFloat, // kCompensatedNominalVoltage
    112: kParamTypeFloat, // kPositionConversionFactor
    113: kParamTypeFloat, // kVelocityConversionFactor
    114: kParamTypeFloat, // kClosedLoopRampRate
    115: kParamTypeFloat, // kSoftLimitFwd
    116: kParamTypeFloat, // kSoftLimitRev
    119: kParamTypeFloat, // kAnalogPositionConversion
    120: kParamTypeFloat, // kAnalogVelocityConversion
    132: kParamTypeFloat, // kAltEncoderPositionFactor
    133: kParamTypeFloat, // kAltEncoderVelocityFactor
  };

  // Fill in PID slot params (13-44, all float)
  static int _resolveTypeTag(int paramId, int deviceTypeTag) {
    // If the device returned a non-zero type tag, trust it.
    if (deviceTypeTag != kParamTypeBool) return deviceTypeTag;

    // Type tag is 0x00 (bool). Check if this is actually a bool param
    // or a zero-valued float misidentified by the firmware bug.
    if (_knownParamTypes.containsKey(paramId)) {
      return _knownParamTypes[paramId]!;
    }

    // PID params (IDs 13-44) and SmartMotion params (76-95) are all float.
    if ((paramId >= 13 && paramId <= 44) ||
        (paramId >= 76 && paramId <= 95) ||
        (paramId >= 96 && paramId <= 111)) {
      return kParamTypeFloat;
    }

    // Default: trust the device's reported tag.
    return deviceTypeTag;
  }

  // -----------------------------------------------------------------------
  // Low-level parameter access
  // -----------------------------------------------------------------------

  /// Read a parameter and return the full result including type tag.
  ///
  /// Uses API Class=7, Index=1.
  /// Request:  [paramId, 0, 0, 0, 0, 0, 0, 0]
  /// Response: [paramId, 0xFF, value(4), typeTag, 0x00]
  Future<ParamReadResult> readParameterRaw(int paramId) async {
    final arbId = buildArbId(
      apiClass: kApiClassParam,
      apiIndex: kParamIndexRead,
      deviceId: _deviceId,
    );

    final payload = buildParamReadPayload(paramId);
    _conn.sendCommand(arbId, payload);

    final response = await _conn.responses
        .where((r) {
          final cls = extractApiClass(r.arbId);
          final dev = extractDeviceId(r.arbId);
          // Accept class=7 responses from this device where byte[1]=0xFF
          // (read response marker).
          return cls == kApiClassParam &&
              dev == _deviceId &&
              r.payload[0] == (paramId & 0xFF) &&
              r.payload[1] == 0xFF;
        })
        .first
        .timeout(const Duration(milliseconds: 500));

    final rawTypeTag = response.payload[6];
    final typeTag = _resolveTypeTag(paramId, rawTypeTag);
    final rawBytes = Uint8List.sublistView(response.payload, 2, 6);

    final double value;
    switch (typeTag) {
      case kParamTypeFloat:
        value = readFloat32(response.payload, 2);
      case kParamTypeBool:
      case kParamTypeInt:
      case kParamTypeUint:
      default:
        value = readUint32(response.payload, 2).toDouble();
    }

    return ParamReadResult(
      paramId: paramId,
      typeTag: typeTag,
      rawBytes: rawBytes,
      value: value,
    );
  }

  /// Encode [value] into 4 little-endian bytes according to [tag].
  static Uint8List _encodeValue(double value, int tag) {
    final bytes = Uint8List(4);
    final bd = ByteData.sublistView(bytes);
    switch (tag) {
      case kParamTypeFloat:
        bd.setFloat32(0, value, Endian.little);
      case kParamTypeBool:
        bd.setUint32(0, value != 0.0 ? 1 : 0, Endian.little);
      case kParamTypeInt:
      case kParamTypeUint:
      default:
        bd.setUint32(0, value.toInt(), Endian.little);
    }
    return bytes;
  }

  /// Set a parameter by ID with ACK verification.
  ///
  /// Matches the confirmed Python protocol:
  /// 1. Read the parameter first to discover the device's actual type tag.
  /// 2. Encode the value according to the resolved type tag.
  /// 3. Write using cls=0x0E, idx=0x00 with 5-byte payload [paramId, value(4B)].
  /// 4. Wait for ACK on cls=0x0E, idx=0x01 where data[0]==paramId.
  ///
  /// Throws [ParameterWriteException] if the ACK indicates a mismatch.
  @override
  Future<SparkResponse> setParameter(int paramId, double value) async {
    // --- Step 1: Read to discover the device's actual type tag ---
    final preRead = await readParameterRaw(paramId);
    final typeTag = preRead.typeTag; // already resolved by readParameterRaw

    // --- Step 2: Encode and write (cls=0x0E, idx=0x00, 5-byte payload) ---
    final valueBytes = _encodeValue(value, typeTag);
    final requestArb = buildArbId(
      apiClass: kApiClassParameterWrite,
      apiIndex: kParamWriteIndexRequest,
      deviceId: _deviceId,
    );
    final payload = buildParamWritePayload(paramId, valueBytes);
    _conn.sendCommand(requestArb, payload);

    // --- Step 3: Wait for ACK on cls=0x0E, idx=0x01 ---
    final ack = await _conn.responses
        .where((r) {
          final cls = extractApiClass(r.arbId);
          final idx = extractApiIndex(r.arbId);
          final dev = extractDeviceId(r.arbId);
          return cls == kApiClassParameterWrite &&
              idx == kParamWriteIndexResponse &&
              dev == _deviceId &&
              r.payload[0] == (paramId & 0xFF);
        })
        .first
        .timeout(const Duration(milliseconds: 500));

    // Verify the ACK echoes the correct type tag (data[1]).
    final ackTypeTag = ack.payload[1];
    if (ackTypeTag != typeTag) {
      throw ParameterWriteException(
        paramId: paramId,
        sentValue: value,
        readBackValue: double.nan,
      );
    }

    return ack;
  }

  /// Get a parameter by ID. Returns the numeric value from the response.
  ///
  /// Uses API Class=7, Index=1.
  /// Response type tag at byte[6] determines interpretation:
  ///   0x00=bool, 0x02=int, 0x03=float, 0x04=uint
  @override
  Future<double> getParameter(int paramId) async {
    final result = await readParameterRaw(paramId);
    return result.value;
  }

  /// Burn all current parameters to flash (persist across power cycles).
  ///
  /// Firmware 26.x: send apiClass=0x3F, apiIndex=0x0F with 2-byte payload
  /// [0xA3, 0x3A] (magic token).
  /// ACK: cls=0x01, idx=0x04 (~125ms later).
  ///
  /// Confirmed from Python `spark_rw_verify.py` (physically verified).
  ///
  /// If [heartbeat] is provided, it is stopped before the burn command
  /// and restarted after the ACK is received.
  @override
  Future<void> burnFlash({IHeartbeatManager? heartbeat}) async {
    // Stop heartbeat FIRST so the bus is quiet before burning.
    // The Python script never sends heartbeats during burn — the device
    // returns 0xFF (error) if other traffic is present on the bus.
    final wasRunning = heartbeat?.isRunning ?? false;
    if (wasRunning) heartbeat!.stop();

    // Allow 500ms for the bus to quiet and for the device to finish
    // committing any pending parameter writes to RAM.
    await Future<void>.delayed(const Duration(milliseconds: 1000));

    final arbId = buildArbId(
      apiClass: kApiClassPersistParameters,
      apiIndex: kPersistParametersIndex,
      deviceId: _deviceId,
    );
    _conn.sendCommand(arbId, buildPersistParametersPayload());

    // Wait for burn ACK on cls=0x01, idx=0x04.
    try {
      await _conn.responses
          .where((r) {
            final cls = extractApiClass(r.arbId);
            final idx = extractApiIndex(r.arbId);
            final dev = extractDeviceId(r.arbId);
            return cls == kBurnFlashAckApiClass &&
                idx == kBurnFlashAckApiIndex &&
                dev == _deviceId;
          })
          .first
          .timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      // Burn may still succeed even without ACK — wait the fallback time.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }

    if (wasRunning) heartbeat!.start();
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
    final writes = <Future<void> Function()>[
      () => setSlot0P(p),
      () => setSlot0I(i),
      () => setSlot0D(d),
      () => setSlot0F(f),
      () => setSlot0IZone(iZone),
      () => setSlot0DFilter(dFilter),
      () => setSlot0MaxOutput(maxOutput),
      () => setSlot0MinOutput(minOutput),
    ];
    ParameterWriteException? firstError;
    for (final w in writes) {
      try {
        await w();
      } on ParameterWriteException catch (e) {
        firstError ??= e;
      }
    }
    if (firstError != null) throw firstError;
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
    final writes = <Future<void> Function()>[
      () => setSlot0FfKs(kS),
      () => setSlot0FfKv(kV),
      () => setSlot0FfKa(kA),
      () => setSlot0FfKg(kG),
      () => setSlot0FfKcos(kCos),
      () => setSlot0FfKcosRatio(kCosRatio),
    ];
    ParameterWriteException? firstError;
    for (final w in writes) {
      try {
        await w();
      } on ParameterWriteException catch (e) {
        firstError ??= e;
      }
    }
    if (firstError != null) throw firstError;
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
