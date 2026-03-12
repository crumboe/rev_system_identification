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
    test('float32 value is placed correctly, rest are zeros', () {
      final payload = buildSetpointPayload(3.14);
      // Read back the float
      final bd = ByteData.sublistView(payload);
      final readValue = bd.getFloat32(0, Endian.little);
      expect(readValue, closeTo(3.14, 1e-5));
      // Bytes 4-7 should be zero by default (pidSlot defaults to 0).
      expect(payload[4], equals(0));
      expect(payload[5], equals(0));
      expect(payload[6], equals(0));
      expect(payload[7], equals(0));
    });

    test('negative value round-trips through float32', () {
      final payload = buildSetpointPayload(-7.5);
      final bd = ByteData.sublistView(payload);
      expect(bd.getFloat32(0, Endian.little), closeTo(-7.5, 1e-5));
    });

    test('zero payload is all zeros', () {
      final payload = buildSetpointPayload(0.0);
      expect(payload.every((b) => b == 0), isTrue);
    });

    test('pidSlot is encoded in byte 4', () {
      final payload = buildSetpointPayload(100.0, pidSlot: 3);
      expect(payload[4], equals(3));
      expect(payload[5], equals(0));
      expect(payload[6], equals(0));
      expect(payload[7], equals(0));
    });
  });

  group('buildParamWritePayload', () {
    test('paramId and value bytes are placed correctly (5-byte, no type tag)', () {
      // Write a float param: kParamSlot0P (id=13), value=1.5
      final valueBytes = Uint8List(4);
      ByteData.sublistView(valueBytes).setFloat32(0, 1.5, Endian.little);
      final payload = buildParamWritePayload(kParamSlot0P, valueBytes);
      expect(payload.length, equals(5));
      expect(payload[0], equals(kParamSlot0P)); // param ID
      // bytes[1:5] = float value
      final bd = ByteData.sublistView(payload);
      expect(bd.getFloat32(1, Endian.little), closeTo(1.5, 1e-5));
    });

    test('uint param value is placed correctly', () {
      final valueBytes = Uint8List(4);
      ByteData.sublistView(valueBytes).setUint32(0, 166, Endian.little);
      final payload = buildParamWritePayload(
          kParamMAXMotionCruiseVelocity0, valueBytes);
      expect(payload.length, equals(5));
      expect(payload[0], equals(kParamMAXMotionCruiseVelocity0 & 0xFF));
    });
  });

  group('buildParamReadPayload', () {
    test('param ID at byte 0, rest zeros', () {
      final payload = buildParamReadPayload(kParamSlot0FfKs);
      expect(payload[0], equals(kParamSlot0FfKs & 0xFF));
      for (var i = 1; i < 8; i++) {
        expect(payload[i], equals(0), reason: 'byte[$i] should be 0');
      }
    });
  });

  group('buildHeartbeatPayload', () {
    test('fw26 heartbeat is 8 zero bytes', () {
      final payload = buildHeartbeatPayload();
      expect(payload.length, equals(8));
      expect(payload.every((b) => b == 0), isTrue);
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
    test('secondary heartbeat uses API Class=11, Index=2', () {
      final arbId = buildArbId(
        apiClass: kApiClassSecondaryHeartbeat,
        apiIndex: kSecondaryHeartbeatIndex,
        deviceId: 0,
      );
      expect(extractApiClass(arbId), equals(0x0B));
      expect(extractApiIndex(arbId), equals(0x02));
    });

    test('persist parameters uses API Class=63, Index=15 with magic number', () {
      final arbId = buildArbId(
        apiClass: kApiClassPersistParameters,
        apiIndex: kPersistParametersIndex,
        deviceId: 0,
      );
      expect(extractApiClass(arbId), equals(0x3F));
      expect(extractApiIndex(arbId), equals(0x0F));

      final payload = buildPersistParametersPayload();
      expect(payload.length, equals(2));
      // Magic bytes [0xA3, 0x3A] — confirmed from Python
      expect(payload[0], equals(0xA3));
      expect(payload[1], equals(0x3A));
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

  // =========================================================================
  // SLCAN encode / decode
  // =========================================================================

  group('encodeSlcanFrame', () {
    test('produces T + 8-hex ID + DLC + hex data + CR', () {
      final arb = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 0,
      );
      final payload = buildParamReadPayload(kParamCanId); // paramId=0
      final frame = encodeSlcanFrame(arb, payload);

      expect(frame, startsWith('T'));
      expect(frame, endsWith('\r'));
      // T(1) + 8-char hex ID + DLC(1) + 16 hex chars (8 bytes) + \r = 27
      expect(frame.length, equals(27));
      // The arb ID hex should match the value padded to 8 chars (uppercase).
      expect(frame.substring(1, 9), equals(arb.toRadixString(16).padLeft(8, '0').toUpperCase()));
      // DLC = 8
      expect(frame[9], equals('8'));
    });

    test('short payload yields correct DLC', () {
      const arb = 0x02050000;
      final payload = Uint8List.fromList([0xAA, 0xBB]);
      final frame = encodeSlcanFrame(arb, payload);

      expect(frame[9], equals('2')); // DLC = 2
      expect(frame.substring(10, 14), equals('AABB'));
      expect(frame.length, equals(14 + 1)); // T(1) + 8-char ID + DLC(1) + 4 hex chars + \r
    });

    test('empty payload yields DLC 0', () {
      const arb = 0x02050000;
      final frame = encodeSlcanFrame(arb, Uint8List(0));
      expect(frame[9], equals('0'));
      expect(frame.length, equals(11)); // T + 8 + 1 + 0 + \r
    });
  });

  group('decodeSlcanFrame', () {
    test('round-trips with encodeSlcanFrame', () {
      final arb = buildArbId(
        apiClass: kApiClassNewStatus,
        apiIndex: kNewStatusIndex0,
        deviceId: 10,
      );
      final payload = Uint8List.fromList([0x00, 0x00, 0xB2, 0x06, 0x00, 0x00, 0x80, 0x00]);
      final frame = encodeSlcanFrame(arb, payload);
      // Strip trailing \r for decode
      final stripped = frame.substring(0, frame.length - 1);
      final resp = decodeSlcanFrame(stripped);

      expect(resp, isNotNull);
      expect(resp!.arbId, equals(arb));
      for (var i = 0; i < 8; i++) {
        expect(resp.payload[i], equals(payload[i]),
            reason: 'payload byte $i mismatch');
      }
      expect(resp.isData, isTrue);
    });

    test('decodes a new-status-0 frame from a real SPARK', () {
      // This is a real SLCAN message captured from a SPARK controller:
      // arb ID 0x0205b80a (new status 0, device 10)
      const frame = 'T0205b80a80000b20600008000';
      final resp = decodeSlcanFrame(frame);

      expect(resp, isNotNull);
      expect(resp!.arbId, equals(0x0205b80a));
      expect(extractApiClass(resp.arbId), equals(kApiClassNewStatus));
      expect(extractApiIndex(resp.arbId), equals(kNewStatusIndex0));
      expect(extractDeviceId(resp.arbId), equals(10));
      expect(resp.payload[0], equals(0x00));
      expect(resp.payload[1], equals(0x00));
      expect(resp.payload[2], equals(0xB2));
      expect(resp.payload[3], equals(0x06));
    });

    test('returns null for non-T prefix', () {
      expect(decodeSlcanFrame('t0205b80a80000b20600008000'), isNull);
      expect(decodeSlcanFrame('X0205b80a80000b20600008000'), isNull);
    });

    test('returns null for too-short string', () {
      expect(decodeSlcanFrame('T0205b80'), isNull);
      expect(decodeSlcanFrame('T'), isNull);
      expect(decodeSlcanFrame(''), isNull);
    });

    test('returns null for invalid hex in arb ID', () {
      expect(decodeSlcanFrame('T0205ZZZZ80000000000000000'), isNull);
    });

    test('returns null for truncated data', () {
      // DLC says 8 but only 6 bytes of data provided (12 hex chars)
      expect(decodeSlcanFrame('T0205b80a80000b206000'), isNull);
    });

    test('DLC 0 is valid', () {
      final resp = decodeSlcanFrame('T020500000');
      expect(resp, isNotNull);
      expect(resp!.arbId, equals(0x02050000));
      // Payload is all zeros
      expect(resp.payload.every((b) => b == 0), isTrue);
    });

    test('extracts arb ID fields correctly', () {
      // Build a parameter-get response arb ID and encode as SLCAN
      final arb = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 5,
      );
      final payload = Uint8List(8);
      final bd = ByteData.sublistView(payload);
      bd.setFloat32(0, 42.0, Endian.little);

      final frame = encodeSlcanFrame(arb, payload);
      final resp = decodeSlcanFrame(frame.substring(0, frame.length - 1));
      expect(resp, isNotNull);
      expect(resp!.apiClass, equals(kApiClassParameter));
      expect(resp.apiIndex, equals(kParamIndexGet));
      expect(resp.deviceId, equals(5));
      expect(readFloat32(resp.payload, 0), closeTo(42.0, 1e-5));
    });
  });

  group('isSlcanData', () {
    test('detects valid binary SPARK response as not SLCAN', () {
      // Build a valid binary response for new status 0
      final arb = buildArbId(
        apiClass: kApiClassNewStatus,
        apiIndex: kNewStatusIndex0,
        deviceId: 10,
      );
      final packet = encodePacket(arb, Uint8List(8));
      expect(isSlcanData(packet), isFalse);
    });

    test('detects valid binary ACK response as not SLCAN', () {
      final arb = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 0,
      );
      final packet = encodePacket(arb, Uint8List(8),
          usbCmdType: kUsbResponseAck);
      expect(isSlcanData(packet), isFalse);
    });

    test('detects valid binary DATA response as not SLCAN', () {
      final arb = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 5,
      );
      final packet = encodePacket(arb, Uint8List(8),
          usbCmdType: kUsbResponseData);
      expect(isSlcanData(packet), isFalse);
    });

    test('detects SLCAN text as not binary', () {
      // An SLCAN frame starts with 'T' followed by hex digits
      final slcanBytes =
          Uint8List.fromList('T0205b80a80000b20600008000\r\n'.codeUnits);
      expect(isSlcanData(slcanBytes), isTrue);
    });

    test('detects garbled arb ID bytes as SLCAN', () {
      // Bytes that look like ASCII text mistakenly interpreted as binary
      // (this is what the bug screenshot showed)
      final garbled = Uint8List.fromList(
          [0x30, 0x30, 0x0D, 0x0A, 0x54, 0x30, 0x32, 0x30, 0x35, 0x62, 0x38, 0x30]);
      expect(isSlcanData(garbled), isTrue);
    });
  });

  // =========================================================================
  // SLCAN ↔ binary arb-ID match mask interop
  //
  // Verify that arb IDs decoded from SLCAN frames still match the mask
  // used in sendAndReceive, so that command-response pairing works across
  // both protocols.
  // =========================================================================

  group('SLCAN arb-ID match mask interop', () {
    const matchMask = 0x1FFFFFC0;

    test('SLCAN response matches binary command after masking', () {
      // Command sent with deviceId=0
      final cmdArb = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 0,
      );
      // Simulate SLCAN response from device with CAN ID 10
      final respArb = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 10,
      );
      final frame = encodeSlcanFrame(respArb, Uint8List(8));
      final resp = decodeSlcanFrame(frame.substring(0, frame.length - 1));

      expect(
        (resp!.arbId & matchMask) == (cmdArb & matchMask),
        isTrue,
        reason: 'SLCAN response should match command after masking device ID',
      );
    });

    test('SLCAN status frame does NOT match parameter command', () {
      final cmdArb = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 0,
      );
      final statusArb = buildArbId(
        apiClass: kApiClassNewStatus,
        apiIndex: kNewStatusIndex0,
        deviceId: 10,
      );
      final frame = encodeSlcanFrame(statusArb, Uint8List(8));
      final resp = decodeSlcanFrame(frame.substring(0, frame.length - 1));

      expect(
        (resp!.arbId & matchMask) == (cmdArb & matchMask),
        isFalse,
        reason: 'Status frame should NOT match a parameter get command',
      );
    });
  });
}
