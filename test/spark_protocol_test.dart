/// Unit tests for the CAN protocol encoding/decoding layer.
///
/// Tests round-trip correctness for arbitration IDs, 12-byte USB packets,
/// payload builders, and the SparkResponse model.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/can/spark_protocol.dart';

void main() {
  // =========================================================================
  // Arbitration ID construction & extraction
  // =========================================================================

  group('buildArbId / extract round-trips', () {
    test('default device type + manufacturer with class 0, index 0, id 0', () {
      final arb = buildArbId(apiClass: 0, apiIndex: 0, deviceId: 0);
      // (0x02 << 24) | (0x05 << 16) = 0x02050000
      expect(arb, equals(0x02050000));
      expect(extractApiClass(arb), equals(0));
      expect(extractApiIndex(arb), equals(0));
      expect(extractDeviceId(arb), equals(0));
    });

    test('control class setpoint for device 1', () {
      final arb = buildArbId(
        apiClass: kApiClassControl,
        apiIndex: kControlIndexSetpoint,
        deviceId: 1,
      );
      expect(extractApiClass(arb), equals(kApiClassControl));
      expect(extractApiIndex(arb), equals(kControlIndexSetpoint));
      expect(extractDeviceId(arb), equals(1));
    });

    test('parameter class set for device 42', () {
      final arb = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexSet,
        deviceId: 42,
      );
      expect(extractApiClass(arb), equals(kApiClassParameter));
      expect(extractApiIndex(arb), equals(kParamIndexSet));
      expect(extractDeviceId(arb), equals(42));
    });

    test('status class index 2 for device 63 (max 6-bit)', () {
      final arb = buildArbId(
        apiClass: kApiClassStatus,
        apiIndex: kStatusIndex2,
        deviceId: 63,
      );
      expect(extractApiClass(arb), equals(kApiClassStatus));
      expect(extractApiIndex(arb), equals(kStatusIndex2));
      expect(extractDeviceId(arb), equals(63));
    });

    test('new status class (0x2E) index 0', () {
      final arb = buildArbId(
        apiClass: kApiClassNewStatus,
        apiIndex: kNewStatusIndex0,
        deviceId: 5,
      );
      expect(extractApiClass(arb), equals(kApiClassNewStatus));
      expect(extractApiIndex(arb), equals(kNewStatusIndex0));
      expect(extractDeviceId(arb), equals(5));
    });

    test('system class sub-indices', () {
      for (final idx in [
        kSystemIndexIdentify,
        kSystemIndexClearFaults,
        kSystemIndexBurnFlash,
        kSystemIndexSetFollower,
        kSystemIndexFactoryReset,
        kSystemIndexIdQuery,
        kSystemIndexIdAssign,
      ]) {
        final arb = buildArbId(
          apiClass: kApiClassSystem,
          apiIndex: idx,
          deviceId: 10,
        );
        expect(extractApiClass(arb), equals(kApiClassSystem));
        expect(extractApiIndex(arb), equals(idx));
        expect(extractDeviceId(arb), equals(10));
      }
    });

    test('max values for all fields', () {
      final arb = buildArbId(
        devType: 0x1F,       // 5 bits max
        manufacturer: 0xFF,  // 8 bits max
        apiClass: 0x3F,      // 6 bits max
        apiIndex: 0x0F,      // 4 bits max
        deviceId: 0x3F,      // 6 bits max
      );
      // All 29 bits should be set
      expect(arb & 0x1FFFFFFF, equals(arb));
      expect(extractApiClass(arb), equals(0x3F));
      expect(extractApiIndex(arb), equals(0x0F));
      expect(extractDeviceId(arb), equals(0x3F));
    });
  });

  // =========================================================================
  // Packet encoding / decoding round-trips
  // =========================================================================

  group('encodePacket / decodePacket round-trips', () {
    test('standard command with empty payload', () {
      final arb = buildArbId(
        apiClass: kApiClassControl,
        apiIndex: kControlIndexSetpoint,
        deviceId: 1,
      );
      final packet = encodePacket(arb, Uint8List(0));
      expect(packet.length, equals(12));

      final resp = decodePacket(packet);
      expect(resp.arbId, equals(arb));
      expect(resp.responseType, equals(kUsbCmdTypeStandard));
      // All payload bytes should be zero-padded
      expect(resp.payload.every((b) => b == 0), isTrue);
    });

    test('payload bytes are preserved at correct offsets', () {
      final payload = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44]);
      final arb = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexSet,
        deviceId: 5,
      );
      final packet = encodePacket(arb, payload);
      final resp = decodePacket(packet);

      expect(resp.arbId, equals(arb));
      for (var i = 0; i < 8; i++) {
        expect(resp.payload[i], equals(payload[i]),
            reason: 'payload byte $i mismatch');
      }
    });

    test('short payload is zero-padded', () {
      final payload = Uint8List.fromList([0x42]);
      final arb = buildArbId(apiClass: 0, apiIndex: 0, deviceId: 0);
      final packet = encodePacket(arb, payload);
      final resp = decodePacket(packet);

      expect(resp.payload[0], equals(0x42));
      for (var i = 1; i < 8; i++) {
        expect(resp.payload[i], equals(0),
            reason: 'expected zero at byte $i');
      }
    });

    test('USB response type (data) is encoded in bits 31:29', () {
      final arb = buildArbId(apiClass: 0, apiIndex: 0, deviceId: 0);
      final packet = encodePacket(arb, Uint8List(0),
          usbCmdType: kUsbResponseData);
      final resp = decodePacket(packet);
      expect(resp.responseType, equals(kUsbResponseData));
      expect(resp.isData, isTrue);
      expect(resp.isAck, isFalse);
    });

    test('arb ID is masked to 29 bits', () {
      // Even if we encode with response type bits, the arbId in the response
      // should be cleaned.
      final arb = buildArbId(
        apiClass: kApiClassStatus,
        apiIndex: kStatusIndex1,
        deviceId: 20,
      );
      final packet = encodePacket(arb, Uint8List(0),
          usbCmdType: kUsbResponseData);
      final resp = decodePacket(packet);
      expect(resp.arbId, equals(arb & 0x1FFFFFFF));
    });
  });

  // =========================================================================
  // Payload builders
  // =========================================================================

  group('buildSetpointPayload', () {
    test('float32 value and control type byte are placed correctly', () {
      final payload = buildSetpointPayload(3.14, kControlTypeVelocity);
      // Read back the float
      final bd = ByteData.sublistView(payload);
      final readValue = bd.getFloat32(0, Endian.little);
      expect(readValue, closeTo(3.14, 1e-5));
      expect(payload[4], equals(kControlTypeVelocity & 0xFF));
      expect(payload[5], equals(0)); // pidSlot = 0
    });

    test('pidSlot is stored at byte 5', () {
      final payload =
          buildSetpointPayload(0.0, kControlTypePosition, pidSlot: 1);
      expect(payload[5], equals(1));
    });

    test('negative value round-trips through float32', () {
      final payload = buildSetpointPayload(-7.5, kControlTypeDutyCycle);
      final bd = ByteData.sublistView(payload);
      expect(bd.getFloat32(0, Endian.little), closeTo(-7.5, 1e-5));
    });

    test('MAXMotion control types are encoded', () {
      final p1 = buildSetpointPayload(1.0, kControlTypeMAXMotionPosition);
      expect(p1[4], equals(kControlTypeMAXMotionPosition));

      final p2 = buildSetpointPayload(500.0, kControlTypeMAXMotionVelocity);
      expect(p2[4], equals(kControlTypeMAXMotionVelocity));
    });
  });

  group('buildParamSetPayload', () {
    test('float value and param ID are placed correctly', () {
      final payload = buildParamSetPayload(1.5, kParamSlot0P);
      final bd = ByteData.sublistView(payload);
      expect(bd.getFloat32(0, Endian.little), closeTo(1.5, 1e-5));
      expect(bd.getUint16(4, Endian.little), equals(kParamSlot0P));
    });

    test('MAXMotion param IDs are encoded correctly', () {
      final payload = buildParamSetPayload(
          600.0, kParamMAXMotionCruiseVelocity0);
      final bd = ByteData.sublistView(payload);
      expect(bd.getFloat32(0, Endian.little), closeTo(600.0, 1e-3));
      expect(bd.getUint16(4, Endian.little),
          equals(kParamMAXMotionCruiseVelocity0));
    });
  });

  group('buildParamGetPayload', () {
    test('param ID is stored at offset 0 as uint16', () {
      final payload = buildParamGetPayload(kParamSlot0FfKs);
      final bd = ByteData.sublistView(payload);
      expect(bd.getUint16(0, Endian.little), equals(kParamSlot0FfKs));
    });
  });

  group('buildHeartbeatPayload', () {
    test('timestamp and mode flags are placed correctly', () {
      final payload = buildHeartbeatPayload(12345, modeFlags: 0x11);
      final bd = ByteData.sublistView(payload);
      expect(bd.getUint32(0, Endian.little), equals(12345));
      expect(payload[5], equals(0x11));
    });

    test('timestamp wraps at uint32 max', () {
      final payload = buildHeartbeatPayload(0xFFFFFFFF + 1);
      final bd = ByteData.sublistView(payload);
      expect(bd.getUint32(0, Endian.little), equals(0));
    });
  });

  group('buildFrameRatePayload', () {
    test('rate is stored as uint16 at offset 0', () {
      final payload = buildFrameRatePayload(20);
      final bd = ByteData.sublistView(payload);
      expect(bd.getUint16(0, Endian.little), equals(20));
    });
  });

  group('buildFollowerPayload', () {
    test('leader arb ID is stored as uint32 LE', () {
      const leaderArb = 0x01020304;
      final payload = buildFollowerPayload(leaderArb);
      final bd = ByteData.sublistView(payload);
      expect(bd.getUint32(0, Endian.little), equals(leaderArb));
    });
  });

  // =========================================================================
  // Float/int read helpers
  // =========================================================================

  group('readFloat32 / readUint16 / readInt16', () {
    test('readFloat32 round-trips', () {
      final data = Uint8List(8);
      final bd = ByteData.sublistView(data);
      bd.setFloat32(0, -42.5, Endian.little);
      expect(readFloat32(data, 0), closeTo(-42.5, 1e-5));
    });

    test('readFloat32 at non-zero offset', () {
      final data = Uint8List(8);
      final bd = ByteData.sublistView(data);
      bd.setFloat32(4, 99.99, Endian.little);
      expect(readFloat32(data, 4), closeTo(99.99, 1e-2));
    });

    test('readUint16 round-trips', () {
      final data = Uint8List(8);
      final bd = ByteData.sublistView(data);
      bd.setUint16(2, 0xABCD, Endian.little);
      expect(readUint16(data, 2), equals(0xABCD));
    });

    test('readInt16 handles negative values', () {
      final data = Uint8List(8);
      final bd = ByteData.sublistView(data);
      bd.setInt16(0, -1234, Endian.little);
      expect(readInt16(data, 0), equals(-1234));
    });

    test('readInt16 handles max positive value', () {
      final data = Uint8List(8);
      final bd = ByteData.sublistView(data);
      bd.setInt16(0, 32767, Endian.little);
      expect(readInt16(data, 0), equals(32767));
    });
  });

  // =========================================================================
  // SparkResponse model
  // =========================================================================

  group('SparkResponse', () {
    test('isAck returns true for ack response type', () {
      final resp = SparkResponse(
        responseType: kUsbResponseAck,
        arbId: buildArbId(apiClass: 0, apiIndex: 0, deviceId: 0),
        payload: Uint8List(8),
      );
      expect(resp.isAck, isTrue);
      expect(resp.isData, isFalse);
    });

    test('isData returns true for data response type', () {
      final resp = SparkResponse(
        responseType: kUsbResponseData,
        arbId: buildArbId(apiClass: 0, apiIndex: 0, deviceId: 0),
        payload: Uint8List(8),
      );
      expect(resp.isData, isTrue);
      expect(resp.isAck, isFalse);
    });

    test('apiClass, apiIndex, deviceId are extracted from arbId', () {
      final arb = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 7,
      );
      final resp = SparkResponse(
        responseType: kUsbResponseData,
        arbId: arb,
        payload: Uint8List(8),
      );
      expect(resp.apiClass, equals(kApiClassParameter));
      expect(resp.apiIndex, equals(kParamIndexGet));
      expect(resp.deviceId, equals(7));
    });

    test('toString contains hex arb ID', () {
      final arb = buildArbId(apiClass: 1, apiIndex: 2, deviceId: 3);
      final resp = SparkResponse(
        responseType: 0,
        arbId: arb,
        payload: Uint8List(8),
      );
      expect(resp.toString(), contains(arb.toRadixString(16)));
    });
  });

  // =========================================================================
  // Constants sanity checks
  // =========================================================================

  group('Protocol constants', () {
    test('heartbeat arb ID is canonical FRC value', () {
      expect(kHeartbeatArbId, equals(0x01011840));
    });

    test('control types are sequential 0–6', () {
      expect(kControlTypeDutyCycle, equals(0));
      expect(kControlTypeVelocity, equals(1));
      expect(kControlTypeVoltage, equals(2));
      expect(kControlTypePosition, equals(3));
      expect(kControlTypeCurrent, equals(4));
      expect(kControlTypeMAXMotionPosition, equals(5));
      expect(kControlTypeMAXMotionVelocity, equals(6));
    });

    test('PID slot 0 param IDs are 13–20', () {
      expect(kParamSlot0P, equals(13));
      expect(kParamSlot0I, equals(14));
      expect(kParamSlot0D, equals(15));
      expect(kParamSlot0F, equals(16));
      expect(kParamSlot0IZone, equals(17));
      expect(kParamSlot0DFilter, equals(18));
      expect(kParamSlot0MinOutput, equals(19));
      expect(kParamSlot0MaxOutput, equals(20));
    });

    test('MAXMotion slot 0 param IDs are 166–170', () {
      expect(kParamMAXMotionCruiseVelocity0, equals(166));
      expect(kParamMAXMotionMaxAccel0, equals(167));
      expect(kParamMAXMotionMaxJerk0, equals(168));
      expect(kParamMAXMotionAllowedError0, equals(169));
      expect(kParamMAXMotionPositionMode0, equals(170));
    });

    test('feedforward slot 0 param IDs match REVLib headers', () {
      expect(kParamSlot0FfKs, equals(204));
      expect(kParamSlot0FfKv, equals(16)); // shared with kParamSlot0F
      expect(kParamSlot0FfKa, equals(205));
      expect(kParamSlot0FfKg, equals(206));
      expect(kParamSlot0FfKcos, equals(207));
      expect(kParamSlot0FfKcosRatio, equals(208));
    });
  });

  // =========================================================================
  // sendAndReceive arb-ID matching mask
  //
  // The mask 0x1FFFFFC0 clears the device-ID field (bits 5:0) so that the
  // controller's response — which echoes its real CAN ID instead of 0 —
  // is still matched to the outbound command that was sent with deviceId=0.
  // =========================================================================

  group('arb-ID match mask (sendAndReceive)', () {
    // The mask used in SparkConnection.sendAndReceive.
    const matchMask = 0x1FFFFFC0;

    test('same class/index, different device IDs → match after masking', () {
      // Command sent with deviceId = 0.
      final sent = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 0,
      );
      // Response echoes real CAN ID = 5.
      final received = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 5,
      );
      expect(
        (received & matchMask) == (sent & matchMask),
        isTrue,
        reason: 'Response with real CAN ID should match command sent with ID 0',
      );
    });

    test('different API class → no match after masking', () {
      final sent = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 0,
      );
      final statusFrame = buildArbId(
        apiClass: kApiClassStatus,
        apiIndex: kStatusIndex1,
        deviceId: 0,
      );
      expect(
        (statusFrame & matchMask) == (sent & matchMask),
        isFalse,
        reason: 'Status frame should not match a parameter command',
      );
    });

    test('different API index → no match after masking', () {
      final sentGet = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 0,
      );
      final sentSet = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexSet,
        deviceId: 0,
      );
      expect(
        (sentSet & matchMask) == (sentGet & matchMask),
        isFalse,
        reason: 'Set and Get commands have different indices — must not match',
      );
    });

    test('device IDs 0–63 all match command sent with id 0 (same class/index)',
        () {
      final sent = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 0,
      );
      for (var id = 0; id < 64; id++) {
        final response = buildArbId(
          apiClass: kApiClassParameter,
          apiIndex: kParamIndexGet,
          deviceId: id,
        );
        expect(
          (response & matchMask) == (sent & matchMask),
          isTrue,
          reason: 'deviceId=$id should match after masking',
        );
      }
    });
  });
}
