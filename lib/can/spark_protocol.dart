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

// Status frame indices
const int kStatusIndex0 = 0x00; // Applied output, faults
const int kStatusIndex1 = 0x01; // Velocity, temp, voltage, current
const int kStatusIndex2 = 0x02; // Position
const int kStatusIndex3 = 0x03; // Analog sensor
const int kStatusIndex4 = 0x04; // Alternate encoder
const int kStatusIndex5 = 0x05; // Absolute encoder position
const int kStatusIndex6 = 0x06; // Absolute encoder velocity

// Control types for setpoint command
const int kControlTypeDutyCycle = 0;
const int kControlTypeVelocity = 1;
const int kControlTypeVoltage = 2;
const int kControlTypePosition = 3;
const int kControlTypeSmartMotion = 4;
const int kControlTypeCurrent = 5;

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
// Parameter IDs
// ---------------------------------------------------------------------------

const int kParamMotorType = 2;
const int kParamIdleMode = 5;
const int kParamOpenLoopRampRate = 8;
const int kParamMotorInverted = 14;
const int kParamPositionConvFactor = 17;
const int kParamVelocityConvFactor = 18;

// PID Slot 0 (IDs 22–29)
const int kParamSlot0P = 22;
const int kParamSlot0I = 23;
const int kParamSlot0D = 24;
const int kParamSlot0F = 25;
const int kParamSlot0IZone = 26;
const int kParamSlot0DFilter = 27;
const int kParamSlot0MaxOutput = 28;
const int kParamSlot0MinOutput = 29;

// PID Slot 1 (IDs 30–37)
const int kParamSlot1P = 30;
const int kParamSlot1I = 31;
const int kParamSlot1D = 32;
const int kParamSlot1F = 33;
const int kParamSlot1IZone = 34;
const int kParamSlot1DFilter = 35;
const int kParamSlot1MaxOutput = 36;
const int kParamSlot1MinOutput = 37;

const int kParamSmartCurrentLimit = 35;
const int kParamSecondaryCurrentLimit = 38;

const int kParamForwardSoftLimit = 44;
const int kParamForwardSoftLimitEnabled = 45;
const int kParamReverseSoftLimit = 46;
const int kParamReverseSoftLimitEnabled = 47;

const int kParamFollowerId = 48;
const int kParamFollowerConfig = 49;

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
