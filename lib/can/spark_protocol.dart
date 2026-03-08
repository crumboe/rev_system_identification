/// Low-level SPARK MAX/Flex CAN-over-USB protocol constants and helpers.
///
/// All packet encoding follows the REV CAN/USB specification:
/// - Fixed 12-byte packets (4-byte command ID + 8-byte payload)
/// - 29-bit CAN arbitration IDs encoded in the lower 29 bits of the command ID
/// - Bits 31:29 carry USB command type (outbound) or response type (inbound)
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// CAN Arbitration ID fields
// ---------------------------------------------------------------------------

/// Device type for motor controllers.
const int kDevTypeMotorController = 0x02;

/// Manufacturer code for REV Robotics.
const int kManufacturerREV = 0x05;

/// Maximum valid CAN device ID (6-bit field, 0–62; 63 is reserved).
const int kMaxCanDeviceId = 62;

// API Classes
const int kApiClassControl = 0x00;
const int kApiClassParameter = 0x01;
const int kApiClassSystem = 0x02;
const int kApiClassStatus = 0x06;
const int kApiClassFrameRate = 0x07;

// Control API indices
const int kControlIndexSetpoint = 0x00;

// Parameter API indices
const int kParamIndexSet = 0x00;
const int kParamIndexGet = 0x01;
const int kParamIndexBurnFlash = 0x02;

// System API indices
const int kSystemIndexIdentify = 0x00;
const int kSystemIndexClearFaults = 0x01;
const int kSystemIndexBurnFlash = 0x03;
const int kSystemIndexSetFollower = 0x04;
const int kSystemIndexFactoryReset = 0x05;
const int kSystemIndexIdQuery = 0x06;
const int kSystemIndexIdAssign = 0x07;

// Status frame indices — legacy protocol (apiClass 0x06)
// Legacy status frames are still emitted by ≥25.0 firmware but Status 0
// contains only dummy data (applied_output=0, all faults set) for old
// follower backward-compat.  Real telemetry now uses the "new" status
// frames at kApiClassNewStatus (0x2E).
const int kStatusIndex0 = 0x00; // Applied output, faults
const int kStatusIndex1 = 0x01; // Velocity, temp, voltage, current
const int kStatusIndex2 = 0x02; // Position
const int kStatusIndex3 = 0x03; // Analog sensor
const int kStatusIndex4 = 0x04; // Alternate encoder
const int kStatusIndex5 = 0x05; // Absolute encoder position
const int kStatusIndex6 = 0x06; // Absolute encoder velocity

// New status frame API class — firmware ≥25.0 (2026.0.4 protocol)
// These frames carry the ACTUAL telemetry; decode with parseNewStatusFrame().
// Frame IDs: SPARK_STATUS_0..9 = apiClass 0x2E, apiIndex 0..9
const int kApiClassNewStatus = 0x2E;
const int kNewStatusIndex0 = 0x00; // Applied output, voltage, current, temp, limits
const int kNewStatusIndex1 = 0x01; // Faults, warnings (bitfields)
const int kNewStatusIndex2 = 0x02; // Primary encoder velocity + position
const int kNewStatusIndex3 = 0x03; // Analog sensor
const int kNewStatusIndex4 = 0x04; // External/alt encoder
const int kNewStatusIndex5 = 0x05; // Duty-cycle encoder
const int kNewStatusIndex6 = 0x06; // Duty-cycle raw
const int kNewStatusIndex7 = 0x07; // I accumulation
const int kNewStatusIndex8 = 0x08; // Setpoint + isAtSetpoint + pidSlot
const int kNewStatusIndex9 = 0x09; // MAXMotion setpoint position/velocity

// Control types for setpoint command — from REVLib 2026.0.4
const int kControlTypeDutyCycle = 0;
const int kControlTypeVelocity = 1;
const int kControlTypeVoltage = 2;
const int kControlTypePosition = 3;
const int kControlTypeCurrent = 4;
const int kControlTypeMAXMotionPosition = 5;
const int kControlTypeMAXMotionVelocity = 6;

// USB command types (bits 31:29 of the 32-bit command word)
const int kUsbCmdTypeStandard = 0x00;

// USB response types (bits 31:29 of the 32-bit response word)
const int kUsbResponseAck = 0x00;
const int kUsbResponseData = 0x01;

// FRC Heartbeat
/// Fixed arbitration ID for the FRC heartbeat frame.
const int kHeartbeatArbId = 0x01011840;

/// Heartbeat mode flag: Watchdog enabled (bit 4).
const int kHeartbeatFlagWatchdog = 0x10;

/// Heartbeat mode flag: Robot enabled (bit 0).
const int kHeartbeatFlagEnabled = 0x01;

/// Heartbeat mode flag: Autonomous (bit 1).
const int kHeartbeatFlagAutonomous = 0x02;

// ---------------------------------------------------------------------------
// Parameter IDs — from REVLib 2026.0.4 CANSparkParameters.h
// Source: maven.revrobotics.com/com/revrobotics/frc/REVLib-driver/2026.0.4/
//         REVLib-driver-2026.0.4-headers.zip → rev/CANSparkParameters.h
// ---------------------------------------------------------------------------

const int kParamCanId = 0; // c_Spark_kCANID
const int kParamMotorType = 2; // c_Spark_kMotorType
const int kParamIdleMode = 6; // c_Spark_kIdleMode
const int kParamOpenLoopRampRate = 56; // c_Spark_kOpenLoopRampRate
const int kParamMotorInverted = 45; // c_Spark_kInverted
const int kParamPositionConvFactor = 112; // c_Spark_kPositionConversionFactor
const int kParamVelocityConvFactor = 113; // c_Spark_kVelocityConversionFactor

// PID Slot 0 (IDs 13–20)
const int kParamSlot0P = 13; // c_Spark_kP_0
const int kParamSlot0I = 14; // c_Spark_kI_0
const int kParamSlot0D = 15; // c_Spark_kD_0
const int kParamSlot0F = 16; // c_Spark_kV_0 (velocity feedforward)
const int kParamSlot0IZone = 17; // c_Spark_kIZone_0
const int kParamSlot0DFilter = 18; // c_Spark_kDFilter_0
const int kParamSlot0MinOutput = 19; // c_Spark_kOutputMin_0
const int kParamSlot0MaxOutput = 20; // c_Spark_kOutputMax_0

// PID Slot 1 (IDs 21–28)
const int kParamSlot1P = 21; // c_Spark_kP_1
const int kParamSlot1I = 22; // c_Spark_kI_1
const int kParamSlot1D = 23; // c_Spark_kD_1
const int kParamSlot1F = 24; // c_Spark_kV_1
const int kParamSlot1IZone = 25; // c_Spark_kIZone_1
const int kParamSlot1DFilter = 26; // c_Spark_kDFilter_1
const int kParamSlot1MinOutput = 27; // c_Spark_kOutputMin_1
const int kParamSlot1MaxOutput = 28; // c_Spark_kOutputMax_1

const int kParamSmartCurrentLimit = 59; // c_Spark_kSmartCurrentStallLimit
const int kParamSmartCurrentFreeLimit = 60; // c_Spark_kSmartCurrentFreeLimit
const int kParamSmartCurrentConfig = 61; // c_Spark_kSmartCurrentConfig
const int kParamSecondaryCurrentLimit = 60; // alias for free-limit

const int kParamCompensatedNominalVoltage = 75; // c_Spark_kCompensatedNominalVoltage
const int kParamClosedLoopRampRate = 114; // c_Spark_kClosedLoopRampRate

const int kParamForwardSoftLimit = 115; // c_Spark_kSoftLimitForward
const int kParamForwardSoftLimitEnabled = 54; // c_Spark_kSoftLimitFwdEn
const int kParamReverseSoftLimit = 116; // c_Spark_kSoftLimitReverse
const int kParamReverseSoftLimitEnabled = 55; // c_Spark_kSoftLimitRevEn

const int kParamFollowerId = 194; // c_Spark_kFollowerModeLeaderId
const int kParamFollowerConfig = 195; // c_Spark_kFollowerModeIsInverted

// FeedForward Slot 0 — verified from REVLib 2026.0.4 headers.
// NOTE: kV lives at kParamSlot0F (ID 16) — the old velocity-FF parameter.
// kS, kA, kG, kCos, kCosRatio are new firmware params (IDs 204–208).
// These require SPARK Flex or SPARK MAX firmware ≥25.0 to be accepted;
// older firmware will return "Invalid parameter id".
const int kParamSlot0FfKs = 204; // c_Spark_kS_0
const int kParamSlot0FfKv = 16; // c_Spark_kV_0 (same as kParamSlot0F)
const int kParamSlot0FfKa = 205; // c_Spark_kA_0
const int kParamSlot0FfKg = 206; // c_Spark_kG_0
const int kParamSlot0FfKcos = 207; // c_Spark_kCos_0
const int kParamSlot0FfKcosRatio = 208; // c_Spark_kCosRatio_0

// FeedForward Slot 1
const int kParamSlot1FfKs = 209; // c_Spark_kS_1
const int kParamSlot1FfKv = 24; // c_Spark_kV_1 (same as kParamSlot1F)
const int kParamSlot1FfKa = 210; // c_Spark_kA_1
const int kParamSlot1FfKg = 211; // c_Spark_kG_1
const int kParamSlot1FfKcos = 212; // c_Spark_kCos_1
const int kParamSlot1FfKcosRatio = 213; // c_Spark_kCosRatio_1

// MAXMotion Slot 0 (IDs 166–170)
const int kParamMAXMotionCruiseVelocity0 = 166; // c_Spark_kMAXMotionCruiseVelocity_0
const int kParamMAXMotionMaxAccel0 = 167;       // c_Spark_kMAXMotionMaxAccel_0
const int kParamMAXMotionMaxJerk0 = 168;         // c_Spark_kMAXMotionMaxJerk_0
const int kParamMAXMotionAllowedError0 = 169;    // c_Spark_kMAXMotionAllowedProfileError_0
const int kParamMAXMotionPositionMode0 = 170;    // c_Spark_kMAXMotionPositionMode_0

// MAXMotion position modes
const int kMAXMotionPositionModeTrapezoidal = 0;
const int kMAXMotionPositionModeSCurve = 1;

// Idle modes
const int kIdleModeCoast = 0;
const int kIdleModeBrake = 1;

// Motor types
const int kMotorTypeBrushed = 0;
const int kMotorTypeBrushless = 1;

// Follower config values
const int kFollowerConfigREV = 0x1A;
const int kFollowerConfigTalon = 0x1B;

// ---------------------------------------------------------------------------
// Arbitration ID construction
// ---------------------------------------------------------------------------

/// Build a 29-bit CAN arbitration ID from its constituent fields.
///
/// ```
/// arb = (DevType << 24) | (Manufacturer << 16) | (APIClass << 10)
///     | (APIIndex << 6) | DeviceID
/// ```
int buildArbId({
  int devType = kDevTypeMotorController,
  int manufacturer = kManufacturerREV,
  required int apiClass,
  required int apiIndex,
  int deviceId = 0,
}) {
  assert(devType & ~0x1F == 0, 'devType must be 5 bits');
  assert(manufacturer & ~0xFF == 0, 'manufacturer must be 8 bits');
  assert(apiClass & ~0x3F == 0, 'apiClass must be 6 bits');
  assert(apiIndex & ~0x0F == 0, 'apiIndex must be 4 bits');
  assert(deviceId & ~0x3F == 0, 'deviceId must be 6 bits');

  return (devType << 24) |
      (manufacturer << 16) |
      (apiClass << 10) |
      (apiIndex << 6) |
      deviceId;
}

/// Extract the API class (6 bits, [15:10]) from a 29-bit arb ID.
int extractApiClass(int arbId) => (arbId >> 10) & 0x3F;

/// Extract the API index (4 bits, [9:6]) from a 29-bit arb ID.
int extractApiIndex(int arbId) => (arbId >> 6) & 0x0F;

/// Extract the device ID (6 bits, [5:0]) from a 29-bit arb ID.
int extractDeviceId(int arbId) => arbId & 0x3F;

// ---------------------------------------------------------------------------
// 12-byte packet encoding / decoding
// ---------------------------------------------------------------------------

/// Encode a 12-byte USB packet for sending to the controller.
///
/// [arbId] is the 29-bit CAN arbitration ID.
/// [payload] is up to 8 bytes of data (zero-padded).
/// [usbCmdType] occupies bits 31:29 of the first 4 bytes.
Uint8List encodePacket(
  int arbId,
  Uint8List payload, {
  int usbCmdType = kUsbCmdTypeStandard,
}) {
  assert(payload.length <= 8, 'Payload must be ≤ 8 bytes');

  final packet = Uint8List(12);
  final bd = ByteData.sublistView(packet);

  // Command ID: bits 31:29 = usbCmdType, bits 28:0 = arbId
  final cmdId = ((usbCmdType & 0x07) << 29) | (arbId & 0x1FFFFFFF);
  bd.setUint32(0, cmdId, Endian.little);

  // Copy payload (zero-padded)
  for (var i = 0; i < payload.length; i++) {
    packet[4 + i] = payload[i];
  }

  return packet;
}

/// Decode a 12-byte USB response packet from the controller.
///
/// Returns a [SparkResponse] with the parsed fields.
SparkResponse decodePacket(Uint8List packet) {
  assert(packet.length == 12, 'Packet must be exactly 12 bytes');

  final bd = ByteData.sublistView(packet);
  final cmdWord = bd.getUint32(0, Endian.little);

  final responseType = (cmdWord >> 29) & 0x07;
  final arbId = cmdWord & 0x1FFFFFFF;
  final payload = Uint8List.sublistView(packet, 4, 12);

  return SparkResponse(
    responseType: responseType,
    arbId: arbId,
    payload: payload,
  );
}

// ---------------------------------------------------------------------------
// Payload helpers
// ---------------------------------------------------------------------------

/// Build the 8-byte payload for a setpoint command.
Uint8List buildSetpointPayload(
  double value,
  int controlType, {
  int pidSlot = 0,
}) {
  final payload = Uint8List(8);
  final bd = ByteData.sublistView(payload);
  bd.setFloat32(0, value, Endian.little);
  payload[4] = controlType & 0xFF;
  payload[5] = pidSlot & 0xFF;
  return payload;
}

/// Build the 8-byte payload for a parameter set command.
Uint8List buildParamSetPayload(double value, int paramId) {
  final payload = Uint8List(8);
  final bd = ByteData.sublistView(payload);
  bd.setFloat32(0, value, Endian.little);
  bd.setUint16(4, paramId, Endian.little);
  return payload;
}

/// Build the 8-byte payload for a parameter get command.
Uint8List buildParamGetPayload(int paramId) {
  final payload = Uint8List(8);
  final bd = ByteData.sublistView(payload);
  bd.setUint16(0, paramId, Endian.little);
  return payload;
}

/// Build the 8-byte heartbeat payload.
Uint8List buildHeartbeatPayload(int timestampMs, {int modeFlags = 0x11}) {
  final payload = Uint8List(8);
  final bd = ByteData.sublistView(payload);
  bd.setUint32(0, timestampMs & 0xFFFFFFFF, Endian.little);
  payload[4] = 0; // match number
  payload[5] = modeFlags & 0xFF;
  return payload;
}

/// Build the 8-byte payload for setting frame rate.
Uint8List buildFrameRatePayload(int rateMs) {
  final payload = Uint8List(8);
  final bd = ByteData.sublistView(payload);
  bd.setUint16(0, rateMs, Endian.little);
  return payload;
}

/// Build the 8-byte payload for setting a follower.
Uint8List buildFollowerPayload(int leaderArbId) {
  final payload = Uint8List(8);
  final bd = ByteData.sublistView(payload);
  bd.setUint32(0, leaderArbId, Endian.little);
  return payload;
}

/// Extract float32 LE from bytes starting at [offset].
double readFloat32(Uint8List data, int offset) {
  final bd = ByteData.sublistView(data);
  return bd.getFloat32(offset, Endian.little);
}

/// Extract uint16 LE from bytes starting at [offset].
int readUint16(Uint8List data, int offset) {
  final bd = ByteData.sublistView(data);
  return bd.getUint16(offset, Endian.little);
}

/// Extract int16 LE from bytes starting at [offset].
int readInt16(Uint8List data, int offset) {
  final bd = ByteData.sublistView(data);
  return bd.getInt16(offset, Endian.little);
}

// ---------------------------------------------------------------------------
// Response model
// ---------------------------------------------------------------------------

/// Parsed response from a SPARK controller over USB.
class SparkResponse {
  /// 0 = Ack, 1 = Data (bits 31:29 of the response word).
  final int responseType;

  /// 29-bit CAN arbitration ID from the response.
  final int arbId;

  /// 8-byte payload.
  final Uint8List payload;

  const SparkResponse({
    required this.responseType,
    required this.arbId,
    required this.payload,
  });

  bool get isAck => responseType == kUsbResponseAck;
  bool get isData => responseType == kUsbResponseData;

  /// API class extracted from the arb ID.
  int get apiClass => extractApiClass(arbId);

  /// API index extracted from the arb ID.
  int get apiIndex => extractApiIndex(arbId);

  /// Device ID extracted from the arb ID.
  int get deviceId => extractDeviceId(arbId);

  @override
  String toString() =>
      'SparkResponse(type=$responseType, arbId=0x${arbId.toRadixString(16)}, '
      'payload=${payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')})';
}
