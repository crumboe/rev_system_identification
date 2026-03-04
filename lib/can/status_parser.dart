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
///   current = ((bytes[6]>>4) | bytes[7]<<4) × (200/4096)
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
  final outputCurrentAmps = rawCurrent * (200.0 / 4096.0);

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
Object? parseStatusFrame(SparkResponse response) {
  if (response.apiClass != kApiClassStatus) return null;

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
