/// Unit tests for the status frame parsers.
///
/// Tests decoding of legacy and new protocol status frames from raw bytes.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/can/spark_protocol.dart';
import 'package:rev_system_identification/can/status_parser.dart';

void main() {
  // =========================================================================
  // Status Frame 0: Applied output, faults, sticky faults, flags
  // =========================================================================

  group('parseStatusFrame0', () {
    test('zero payload produces zero output and no faults', () {
      final payload = Uint8List(8);
      final sf = parseStatusFrame0(payload);
      expect(sf.appliedOutput, closeTo(0.0, 1e-6));
      expect(sf.faults, equals(0));
      expect(sf.stickyFaults, equals(0));
      expect(sf.flags, equals(0));
    });

    test('full forward output (32767) maps to ~1.0', () {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setInt16(0, 32767, Endian.little);
      final sf = parseStatusFrame0(payload);
      expect(sf.appliedOutput, closeTo(1.0, 0.001));
    });

    test('full reverse output (-32767) maps to ~-1.0', () {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setInt16(0, -32767, Endian.little);
      final sf = parseStatusFrame0(payload);
      expect(sf.appliedOutput, closeTo(-1.0, 0.001));
    });

    test('faults and sticky faults are decoded as uint16 LE', () {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setUint16(2, 0x1234, Endian.little); // faults
      bd.setUint16(4, 0xABCD, Endian.little); // sticky faults
      final sf = parseStatusFrame0(payload);
      expect(sf.faults, equals(0x1234));
      expect(sf.stickyFaults, equals(0xABCD));
    });

    test('flags byte is at offset 6', () {
      final payload = Uint8List(8);
      payload[6] = 0xFF;
      final sf = parseStatusFrame0(payload);
      expect(sf.flags, equals(0xFF));
    });
  });

  // =========================================================================
  // Status Frame 1: Velocity, temperature, bus voltage, output current
  // =========================================================================

  group('parseStatusFrame1', () {
    test('zero payload produces zero readings', () {
      final payload = Uint8List(8);
      final sf = parseStatusFrame1(payload);
      expect(sf.velocityRpm, closeTo(0.0, 1e-6));
      expect(sf.temperatureC, equals(0));
      expect(sf.busVoltage, closeTo(0.0, 1e-6));
      expect(sf.outputCurrentAmps, closeTo(0.0, 1e-6));
    });

    test('velocity float32 round-trips', () {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setFloat32(0, 5676.5, Endian.little);
      final sf = parseStatusFrame1(payload);
      expect(sf.velocityRpm, closeTo(5676.5, 0.5));
    });

    test('temperature byte at offset 4', () {
      final payload = Uint8List(8);
      payload[4] = 45; // 45°C
      final sf = parseStatusFrame1(payload);
      expect(sf.temperatureC, equals(45));
    });

    test('packed 12-bit voltage and current decode correctly', () {
      // Build known packed values
      // voltage raw 12-bit = 2048 → voltage = 2048 * 32/4096 = 16.0 V
      // current raw 12-bit = 1024 → current = 1024 / 250 = 4.096 A
      final payload = Uint8List(8);
      // rawVoltage = (b5 | (b6 << 8)) & 0x0FFF = 2048 = 0x800
      // rawCurrent = ((b6 >> 4) | (b7 << 4)) & 0x0FFF = 1024 = 0x400
      // b5 = 0x00, b6 = 0x08, then (b6>>4)=0, b7<<4 needs to give 0x400
      // rawCurrent = (0 | b7<<4) & 0xFFF → b7 = 0x400 >> 4 = 0x40
      payload[5] = 0x00;
      payload[6] = 0x08;
      payload[7] = 0x40;

      final sf = parseStatusFrame1(payload);
      expect(sf.busVoltage, closeTo(16.0, 0.1));
      expect(sf.outputCurrentAmps, closeTo(4.096, 0.01));
    });

    test('negative velocity float32 works', () {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setFloat32(0, -3000.0, Endian.little);
      final sf = parseStatusFrame1(payload);
      expect(sf.velocityRpm, closeTo(-3000.0, 0.5));
    });
  });

  // =========================================================================
  // Status Frame 2: Position
  // =========================================================================

  group('parseStatusFrame2', () {
    test('position float32 round-trips', () {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setFloat32(0, 12.75, Endian.little);
      final sf = parseStatusFrame2(payload);
      expect(sf.positionRotations, closeTo(12.75, 1e-3));
    });

    test('negative position', () {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setFloat32(0, -0.125, Endian.little);
      final sf = parseStatusFrame2(payload);
      expect(sf.positionRotations, closeTo(-0.125, 1e-5));
    });
  });

  // =========================================================================
  // Status Frame 3: Analog sensor
  // =========================================================================

  group('parseStatusFrame3', () {
    test('analog voltage and velocity decode from float32', () {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setFloat32(0, 2.5, Endian.little);  // voltage
      bd.setFloat32(4, 100.0, Endian.little); // velocity
      final sf = parseStatusFrame3(payload);
      expect(sf.analogVoltage, closeTo(2.5, 1e-3));
      expect(sf.analogVelocity, closeTo(100.0, 1e-1));
    });
  });

  // =========================================================================
  // Status Frame 4: Alternate encoder
  // =========================================================================

  group('parseStatusFrame4', () {
    test('alt encoder velocity and position decode from float32', () {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setFloat32(0, 500.0, Endian.little);  // velocity
      bd.setFloat32(4, 3.75, Endian.little);   // position
      final sf = parseStatusFrame4(payload);
      expect(sf.altEncoderVelocity, closeTo(500.0, 1e-1));
      expect(sf.altEncoderPosition, closeTo(3.75, 1e-3));
    });
  });

  // =========================================================================
  // parseStatusFrame (dispatcher)
  // =========================================================================

  group('parseStatusFrame dispatcher', () {
    Uint8List _makeStatus0Payload({int rawOutput = 0}) {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setInt16(0, rawOutput, Endian.little);
      return payload;
    }

    Uint8List _makeStatus2Payload({double position = 0.0}) {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setFloat32(0, position, Endian.little);
      return payload;
    }

    test('dispatches legacy status 0', () {
      final arb = buildArbId(
        apiClass: kApiClassStatus,
        apiIndex: kStatusIndex0,
        deviceId: 1,
      );
      final resp = SparkResponse(
        responseType: kUsbResponseData,
        arbId: arb,
        payload: _makeStatus0Payload(rawOutput: 16384),
      );
      final result = parseStatusFrame(resp);
      expect(result, isA<StatusFrame0>());
      expect((result as StatusFrame0).appliedOutput, greaterThan(0));
    });

    test('dispatches legacy status 2', () {
      final arb = buildArbId(
        apiClass: kApiClassStatus,
        apiIndex: kStatusIndex2,
        deviceId: 1,
      );
      final resp = SparkResponse(
        responseType: kUsbResponseData,
        arbId: arb,
        payload: _makeStatus2Payload(position: 5.5),
      );
      final result = parseStatusFrame(resp);
      expect(result, isA<StatusFrame2>());
      expect((result as StatusFrame2).positionRotations, closeTo(5.5, 0.01));
    });

    test('returns null for unknown API class', () {
      final arb = buildArbId(
        apiClass: 0x3F, // not a status class
        apiIndex: 0,
        deviceId: 1,
      );
      final resp = SparkResponse(
        responseType: kUsbResponseData,
        arbId: arb,
        payload: Uint8List(8),
      );
      expect(parseStatusFrame(resp), isNull);
    });

    test('returns null for unknown status index', () {
      final arb = buildArbId(
        apiClass: kApiClassStatus,
        apiIndex: 0x0F, // not a valid status index
        deviceId: 1,
      );
      final resp = SparkResponse(
        responseType: kUsbResponseData,
        arbId: arb,
        payload: Uint8List(8),
      );
      expect(parseStatusFrame(resp), isNull);
    });

    test('dispatches new status frame 0', () {
      final arb = buildArbId(
        apiClass: kApiClassNewStatus,
        apiIndex: kNewStatusIndex0,
        deviceId: 1,
      );
      // Build a new-protocol status 0 payload
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setInt16(0, 16000, Endian.little);   // applied output
      bd.setUint16(2, 1500, Endian.little);   // voltage raw
      bd.setUint16(4, 500, Endian.little);    // current raw
      payload[6] = 30;                          // temp
      payload[7] = 0x01;                        // flags

      final resp = SparkResponse(
        responseType: kUsbResponseData,
        arbId: arb,
        payload: payload,
      );
      final result = parseStatusFrame(resp);
      // parseNewStatusFrame0 returns a record with status0 and partialStatus1
      expect(result, isNotNull);
    });

    test('dispatches new status frame 2', () {
      final arb = buildArbId(
        apiClass: kApiClassNewStatus,
        apiIndex: kNewStatusIndex2,
        deviceId: 1,
      );
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setFloat32(0, 3000.0, Endian.little); // velocity
      bd.setFloat32(4, 2.5, Endian.little);    // position

      final resp = SparkResponse(
        responseType: kUsbResponseData,
        arbId: arb,
        payload: payload,
      );
      final result = parseStatusFrame(resp);
      expect(result, isNotNull);
    });
  });

  // =========================================================================
  // New protocol status frame parsers
  // =========================================================================

  group('parseNewStatusFrame0', () {
    test('applied output scaling uses expected factor', () {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setInt16(0, 32443, Endian.little); // ~1.0 with scale factor
      final result = parseNewStatusFrame0(payload);
      expect(result.status0.appliedOutput, closeTo(1.0, 0.01));
    });

    test('voltage and current scaling', () {
      // Build a payload with the correct 12-bit packed encoding verified against
      // live SLCAN captures (modifForStatus.txt).
      //
      // Desired values: bus_voltage ≈ 12 V, output_current ≈ 20 A, temp = 25°C
      //
      // v_raw = 12 / 0.007326 ≈ 1638 = 0x666
      //   → payload[2] = 0x66 = 102, low nibble of payload[3] = 6
      // i_raw = 20 / 0.064 = 312 = 0x138
      //   → high nibble of payload[3] = 8, payload[4] = 0x13 = 19
      //   → payload[3] = (8 << 4) | 6 = 0x86 = 134
      // temp → payload[5] = 25
      final payload = Uint8List(8);
      payload[2] = 0x66; // v_raw bits [7:0]
      payload[3] = 0x86; // bits [3:0]=6 → v_raw bits [11:8]; bits [7:4]=8 → i_raw bits [3:0]
      payload[4] = 0x13; // i_raw bits [11:4]
      payload[5] = 25;   // temperature

      final result = parseNewStatusFrame0(payload);
      expect(result.partialStatus1.busVoltage, closeTo(12.0, 0.2));
      expect(result.partialStatus1.outputCurrentAmps, closeTo(20.0, 0.5));
      expect(result.partialStatus1.temperatureC, equals(25));
    });

    test('flags byte is at offset 7', () {
      final payload = Uint8List(8);
      payload[7] = 0x3F;
      final result = parseNewStatusFrame0(payload);
      expect(result.status0.flags, equals(0x3F));
    });

    // Live-captured idle frame from modifForStatus.txt:  00 00 98 06 00 19 80 00
    // appOut=0.0, bus≈12.37V, current=0A, temp=25°C
    test('idle captured frame: zero current and correct voltage', () {
      final payload =
          Uint8List.fromList([0x00, 0x00, 0x98, 0x06, 0x00, 0x19, 0x80, 0x00]);
      final result = parseNewStatusFrame0(payload);
      expect(result.status0.appliedOutput, closeTo(0.0, 0.001));
      expect(result.partialStatus1.busVoltage, closeTo(12.37, 0.05));
      expect(result.partialStatus1.outputCurrentAmps, closeTo(0.0, 0.001));
      expect(result.partialStatus1.temperatureC, equals(25));
    });

    // Live-captured running frame from modifForStatus.txt:  fe 11 5c 46 15 19 80 00
    // appOut≈0.142, bus≈11.93V, i_raw=340 → 21.76A, temp=25°C
    test('running captured frame: non-zero current and correct voltage', () {
      final payload =
          Uint8List.fromList([0xfe, 0x11, 0x5c, 0x46, 0x15, 0x19, 0x80, 0x00]);
      final result = parseNewStatusFrame0(payload);
      expect(result.status0.appliedOutput, closeTo(0.142, 0.001));
      expect(result.partialStatus1.busVoltage, closeTo(11.93, 0.05));
      // i_raw = ((0x46>>4) | (0x15<<4)) & 0xFFF = (4 | 336) = 340 → 340 × 0.064 = 21.76 A
      expect(result.partialStatus1.outputCurrentAmps, closeTo(21.76, 0.1));
      expect(result.partialStatus1.temperatureC, equals(25));
    });
  });

  group('parseNewStatusFrame2', () {
    test('velocity and position float32 round-trip', () {
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setFloat32(0, 5000.0, Endian.little);  // velocity RPM
      bd.setFloat32(4, 10.25, Endian.little);   // position rotations

      final result = parseNewStatusFrame2(payload);
      expect(result.velocityUpdate!.velocityRpm, closeTo(5000.0, 0.5));
      expect(result.status2.positionRotations, closeTo(10.25, 1e-3));
    });
  });

  // =========================================================================
  // Data class string representations
  // =========================================================================

  group('Status frame toString', () {
    test('StatusFrame0 toString contains output and faults', () {
      final sf = StatusFrame0(
        appliedOutput: 0.5,
        faults: 0x01,
        stickyFaults: 0x02,
        flags: 0x10,
      );
      final s = sf.toString();
      expect(s, contains('0.500'));
      expect(s, contains('0x1'));
      expect(s, contains('0x2'));
    });

    test('StatusFrame1 toString contains velocity and voltage', () {
      final sf = StatusFrame1(
        velocityRpm: 1234.5,
        temperatureC: 30,
        busVoltage: 12.0,
        outputCurrentAmps: 5.5,
      );
      final s = sf.toString();
      expect(s, contains('1234.5'));
      expect(s, contains('12.00'));
    });

    test('StatusFrame2 toString contains position', () {
      final sf = StatusFrame2(positionRotations: 3.1416);
      expect(sf.toString(), contains('3.1416'));
    });
  });
}
