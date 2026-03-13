/// Parsers for SPARK MAX/Flex periodic status frames.
///
/// Status frames are broadcast by the controller at configurable rates.
/// Each frame is identified by API Class 0x06 and a specific API Index.
library;

import 'dart:typed_data';

import 'spark_protocol.dart';

// ---------------------------------------------------------------------------
// Status frame data classes
// ---------------------------------------------------------------------------

/// Status Frame 0: Applied output, faults, sticky faults, flags.
class StatusFrame0 {
  /// Applied duty cycle output, scaled from int16 / 32767 → [-1.0, 1.0].
  final double appliedOutput;

  /// Active fault bitmask (uint16).
  final int faults;

  /// Sticky fault bitmask (uint16).
  final int stickyFaults;

  /// Status flags byte.
  final int flags;

  const StatusFrame0({
    required this.appliedOutput,
    required this.faults,
    required this.stickyFaults,
    required this.flags,
  });

  @override
  String toString() =>
      'Status0(output=${appliedOutput.toStringAsFixed(3)}, '
      'faults=0x${faults.toRadixString(16)}, '
      'stickyFaults=0x${stickyFaults.toRadixString(16)}, '
      'flags=0x${flags.toRadixString(16)})';
}

/// Status Frame 1: Velocity, temperature, bus voltage, output current.
class StatusFrame1 {
  /// Motor velocity in RPM (float32).
  final double velocityRpm;

  /// Motor temperature in °C (uint8).
  final int temperatureC;

  /// Bus voltage in volts (decoded from packed 12-bit).
  final double busVoltage;

  /// Output current in amps (decoded from packed 12-bit).
  final double outputCurrentAmps;

  const StatusFrame1({
    required this.velocityRpm,
    required this.temperatureC,
    required this.busVoltage,
    required this.outputCurrentAmps,
  });

  @override
  String toString() =>
      'Status1(vel=${velocityRpm.toStringAsFixed(1)} RPM, '
      'temp=$temperatureC°C, '
      'voltage=${busVoltage.toStringAsFixed(2)}V, '
      'current=${outputCurrentAmps.toStringAsFixed(2)}A)';
}

/// Status Frame 2: Motor position.
class StatusFrame2 {
  /// Motor position in rotations (float32).
  final double positionRotations;

  const StatusFrame2({required this.positionRotations});

  @override
  String toString() =>
      'Status2(pos=${positionRotations.toStringAsFixed(4)} rot)';
}

/// Status Frame 3: Analog sensor data.
class StatusFrame3 {
  final double analogVoltage;
  final double analogVelocity;
  final double analogPosition;

  const StatusFrame3({
    required this.analogVoltage,
    required this.analogVelocity,
    required this.analogPosition,
  });
}

/// Status Frame 4: Alternate encoder data.
class StatusFrame4 {
  final double altEncoderVelocity;
  final double altEncoderPosition;

  const StatusFrame4({
    required this.altEncoderVelocity,
    required this.altEncoderPosition,
  });
}

/// Status Frame 5: Absolute encoder position + angle.
class StatusFrame5 {
  final double absoluteEncoderPosition;

  const StatusFrame5({required this.absoluteEncoderPosition});
}

// ---------------------------------------------------------------------------
// Parsers
// ---------------------------------------------------------------------------

/// Parse a Status Frame 0 from an 8-byte payload.
StatusFrame0 parseStatusFrame0(Uint8List payload) {
  final bd = ByteData.sublistView(payload);
  final rawOutput = bd.getInt16(0, Endian.little);
  final appliedOutput = rawOutput / 32767.0;
  final faults = bd.getUint16(2, Endian.little);
  final stickyFaults = bd.getUint16(4, Endian.little);
  final flags = payload[6];

  return StatusFrame0(
    appliedOutput: appliedOutput,
    faults: faults,
    stickyFaults: stickyFaults,
    flags: flags,
  );
}

/// Parse a Status Frame 1 from an 8-byte payload.
///
/// Bytes 0–3: velocity (float32 LE, RPM)
/// Byte  4:   temperature (uint8, °C)
/// Bytes 5–7: packed 12-bit voltage and current
///   voltage = lower 12 bits of (bytes[5] | bytes[6]<<8) × (32/4096)
///   current = ((bytes[6]>>4) | bytes[7]<<4) 
StatusFrame1 parseStatusFrame1(Uint8List payload) {
  final bd = ByteData.sublistView(payload);
  final velocityRpm = bd.getFloat32(0, Endian.little);
  final temperatureC = payload[4];

  // Decode packed 12-bit values from bytes 5, 6, 7
  final b5 = payload[5];
  final b6 = payload[6];
  final b7 = payload[7];

  final rawVoltage = (b5 | (b6 << 8)) & 0x0FFF;
  final rawCurrent = ((b6 >> 4) | (b7 << 4)) & 0x0FFF;

  final busVoltage = rawVoltage * (32.0 / 4096.0);
  final outputCurrentAmps = rawCurrent * (8.0 / 4096.0);

  return StatusFrame1(
    velocityRpm: velocityRpm,
    temperatureC: temperatureC,
    busVoltage: busVoltage,
    outputCurrentAmps: outputCurrentAmps,
  );
}

/// Parse a Status Frame 2 from an 8-byte payload.
StatusFrame2 parseStatusFrame2(Uint8List payload) {
  final bd = ByteData.sublistView(payload);
  final positionRotations = bd.getFloat32(0, Endian.little);
  return StatusFrame2(positionRotations: positionRotations);
}

/// Parse a Status Frame 3 from an 8-byte payload.
StatusFrame3 parseStatusFrame3(Uint8List payload) {
  final bd = ByteData.sublistView(payload);
  return StatusFrame3(
    analogVoltage: bd.getFloat32(0, Endian.little),
    analogVelocity: bd.getFloat32(4, Endian.little),
    analogPosition: 0, // May vary by firmware version
  );
}

/// Parse a Status Frame 4 from an 8-byte payload.
StatusFrame4 parseStatusFrame4(Uint8List payload) {
  final bd = ByteData.sublistView(payload);
  return StatusFrame4(
    altEncoderVelocity: bd.getFloat32(0, Endian.little),
    altEncoderPosition: bd.getFloat32(4, Endian.little),
  );
}

/// Determine which status frame a [SparkResponse] represents and parse it.
///
/// Returns `null` if the response is not a status frame.
/// Supports both the legacy protocol (apiClass 0x06, firmware <25.0) and
/// the new protocol (apiClass 0x2E, firmware ≥25.0).
Object? parseStatusFrame(SparkResponse response) {
  // Legacy status frames (apiClass 0x06) — firmware <25.0 or backward-compat.
  // NOTE: On firmware ≥25.0, legacy Status 0 sends DUMMY data
  // (applied_output=0, all faults set). It exists only so old SPARKs
  // trying to follow this one don't move unexpectedly.
  if (response.apiClass == kApiClassStatus) {
    return switch (response.apiIndex) {
      kStatusIndex0 => parseStatusFrame0(response.payload),
      kStatusIndex1 => parseStatusFrame1(response.payload),
      kStatusIndex2 => parseStatusFrame2(response.payload),
      kStatusIndex3 => parseStatusFrame3(response.payload),
      kStatusIndex4 => parseStatusFrame4(response.payload),
      kStatusIndex5 => StatusFrame5(
          absoluteEncoderPosition:
              readFloat32(response.payload, 0)),
      _ => null,
    };
  }

  // New status frames (apiClass 0x2E) — firmware ≥25.0 (2026.0.4 protocol).
  // These carry the REAL telemetry data. When these arrive, they should
  // be preferred over legacy frames for populating cached status.
  if (response.apiClass == kApiClassNewStatus) {
    return switch (response.apiIndex) {
      kNewStatusIndex0 => parseNewStatusFrame0(response.payload),
      kNewStatusIndex2 => parseNewStatusFrame2(response.payload),
      _ => null,
    };
  }

  return null;
}

// ---------------------------------------------------------------------------
// New protocol status frame parsers (firmware ≥25.0)
// ---------------------------------------------------------------------------

/// Parse new-protocol Status Frame 0 (apiClass 0x2E, index 0).
///
/// Actual byte layout verified against live SLCAN captures
/// (modifForStatus.txt, firmware 26.x, API class 0x2E):
///
///   Bytes 0–1: int16_t applied_output  scale 3.082369457075716e-5 → [-1, +1]
///   Bytes 2–4: 12-bit packed voltage + current (3 bytes, two 12-bit fields)
///     voltage_raw = payload[2] | ((payload[3] & 0x0F) << 8)   (12 bits)
///     current_raw = ((payload[3] >> 4) | (payload[4] << 4)) & 0x0FFF  (12 bits)
///     bus_voltage   = voltage_raw × (2/273)      → Volts  (full-scale 30 V)
///     output_current = current_raw × (16/250)    → Amps   (full-scale ≈ 262 A)
///   Byte  5:   uint8_t  motor_temperature         → °C
///   Bytes 6–7: packed status flags
///
/// NOTE: The old comment claimed uint16 voltage at bytes 2-3 and uint16 current
/// at bytes 4-5.  That layout gives valid voltage at idle (when payload[3] has
/// a zero high nibble) but produces wrong current (≈25 A at idle instead of 0).
/// Confirmed correct layout from captured data where idle current_raw = 0.
///
/// This replaces the legacy Status 0 + Status 1 combined, since the new
/// Status 0 contains voltage, current, and temperature that had been in
/// the old Status 1.
StatusFrame0 parseNewStatusFrame0AsLegacy0(Uint8List payload) {
  final bd = ByteData.sublistView(payload);
  final rawOutput = bd.getInt16(0, Endian.little);
  // Scale per header: 3.082369457075716e-05.
  final appliedOutput = rawOutput * 3.082369457075716e-05;

  // Byte 7 packed flags — we map to legacy "flags" field.
  // Byte 6 contains a hardware-model indicator (typically 0x80 for SPARK MAX).
  final flags = payload[7];

  return StatusFrame0(
    appliedOutput: appliedOutput,
    faults: 0,        // Individual faults are now in new Status 1
    stickyFaults: 0,
    flags: flags,
  );
}

/// Parse new-protocol Status Frame 0 and extract the Status 1-equivalent
/// data (voltage, current, temperature) that used to live in legacy Status 1.
StatusFrame1 parseNewStatusFrame0AsLegacy1(Uint8List payload) {
  // 12-bit packed voltage: lower 8 bits from byte 2, upper 4 from low nibble of byte 3.
  final rawVoltage = (payload[2] | ((payload[3] & 0x0F) << 8));

  // 12-bit packed current: high nibble of byte 3 concatenated with byte 4.
  final rawCurrent = ((payload[3] >> 4) | (payload[4] << 4)) & 0x0FFF;

  // Temperature is at byte 5 (not byte 6 as previously commented).
  final temperatureC = payload[5];

  // Voltage scale: 2/273 ≈ 0.00733 V/count — full-scale 30 V for 12-bit.
  final busVoltage = rawVoltage * 0.0073260073260073;

  // Current scale: 16/250 = 0.064 A/count.
  // Derived from the documented 16-bit encoding (1/250 A per count) compressed
  // to 12 bits: 12-bit covers 1/16 of the 16-bit range, so scale × 16.
  // Full-scale ≈ 262 A at 12-bit max (4095 counts).
  final outputCurrentAmps = rawCurrent * (16.0 / 250.0);

  return StatusFrame1(
    velocityRpm: 0.0,  // Velocity is now in new Status 2
    temperatureC: temperatureC,
    busVoltage: busVoltage,
    outputCurrentAmps: outputCurrentAmps,
  );
}

/// Combined parse of new-protocol Status Frame 0 returning both a
/// [StatusFrame0] and a partial [StatusFrame1] (voltage/current/temp).
///
/// Call this once and split the result to update both cached frames.
({StatusFrame0 status0, StatusFrame1 partialStatus1}) parseNewStatusFrame0(
    Uint8List payload) {
  return (
    status0: parseNewStatusFrame0AsLegacy0(payload),
    partialStatus1: parseNewStatusFrame0AsLegacy1(payload),
  );
}

/// Parse new-protocol Status Frame 2 (apiClass 0x2E, index 2).
///
/// Byte layout (from CANSparkFrames.h `spark_status_2_t`):
///   Bytes 0–3: float32 primary_encoder_velocity (RPM by default)
///   Bytes 4–7: float32 primary_encoder_position (rotations by default)
///
/// This single frame replaces both legacy Status 1 (velocity) and
/// legacy Status 2 (position).
({StatusFrame1? velocityUpdate, StatusFrame2 status2}) parseNewStatusFrame2(
    Uint8List payload) {
  final bd = ByteData.sublistView(payload);
  final velocityRpm = bd.getFloat32(0, Endian.little);
  final positionRotations = bd.getFloat32(4, Endian.little);

  return (
    velocityUpdate: StatusFrame1(
      velocityRpm: velocityRpm,
      temperatureC: 0,        // Temp is in new Status 0 now
      busVoltage: 0.0,        // Voltage is in new Status 0 now
      outputCurrentAmps: 0.0, // Current is in new Status 0 now
    ),
    status2: StatusFrame2(positionRotations: positionRotations),
  );
}
