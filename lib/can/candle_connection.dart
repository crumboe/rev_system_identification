/// Bidirectional CAN connection to a SPARK MAX/Flex via the Candle API.
///
/// Uses REV's CANBridge.dll (from REV Hardware Client) to communicate
/// through the WinUSB MI_00 interface.  Unlike the serial SLCAN path,
/// this receives ALL CAN frames including command responses, enabling
/// full parameter read/write and confirmed motor control.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'candle_ffi.dart';
import 'comms_log.dart';
import 'interfaces.dart';
import 'spark_protocol.dart';
import 'status_parser.dart';

/// Information about a Candle device discovered during scanning.
class CandleDeviceInfo {
  final String path;
  final String name;
  final int index;

  const CandleDeviceInfo({
    required this.path,
    required this.name,
    required this.index,
  });

  @override
  String toString() => '$name ($path)';
}

/// Bidirectional CAN connection through the Candle/gs_usb WinUSB interface.
///
/// Implements [ISparkConnection] so it can be used as a drop-in replacement
/// for [SparkConnection] (serial SLCAN).  The key advantage is that
/// `candle_frame_read` returns ALL CAN frames — status broadcasts AND
/// command responses — giving full bidirectional communication.
class CandleConnection implements ISparkConnection {
  final CandleApi _api;
  Pointer<Void> _listPtr = nullptr;
  Pointer<Void> _devHandle = nullptr;
  final int _deviceIndex;

  bool _isOpen = false;
  final String _deviceName;

  /// Stream of parsed responses received from the controller.
  final StreamController<SparkResponse> _responseController =
      StreamController<SparkResponse>.broadcast();

  @override
  StatusFrame0? lastStatus0;
  @override
  StatusFrame1? lastStatus1;
  @override
  StatusFrame2? lastStatus2;

  @override
  bool get isOpen => _isOpen;

  @override
  String get portName => 'CAN:$_deviceName';

  /// Whether we have received at least one new-protocol status frame.
  bool _usingNewProtocol = false;

  /// Timer for polling inbound CAN frames.
  Timer? _pollTimer;

  /// Native frame buffer, allocated once and reused for reads/writes.
  Pointer<GsHostFrame>? _framePtr;

  CandleConnection(this._api, {int deviceIndex = 0, String? deviceName})
      : _deviceIndex = deviceIndex,
        _deviceName = deviceName ?? 'SPARK MAX';

  // -------------------------------------------------------------------------
  // Connection lifecycle
  // -------------------------------------------------------------------------

  @override
  void open() {
    if (_isOpen) return;

    // Scan for devices.
    final listPtrPtr = calloc<Pointer<Void>>();
    try {
      final ok = _api.listScan(listPtrPtr);
      _listPtr = listPtrPtr.value;
      if (!ok || _listPtr == nullptr) {
        throw StateError(
          'Candle scan failed — no WinUSB CAN devices found. '
          'Is the SPARK MAX connected via USB?',
        );
      }
    } finally {
      calloc.free(listPtrPtr);
    }

    final count = _api.listLength(_listPtr);
    if (count == 0 || _deviceIndex >= count) {
      _api.listFree(_listPtr);
      _listPtr = nullptr;
      throw StateError(
        'No Candle device at index $_deviceIndex (found $count devices)',
      );
    }

    // Get device handle.
    final devPtr = calloc<Pointer<Void>>();
    try {
      final ok = _api.devGet(_listPtr, _deviceIndex, devPtr);
      _devHandle = devPtr.value;
      if (!ok || _devHandle == nullptr) {
        _api.listFree(_listPtr);
        _listPtr = nullptr;
        throw StateError('Failed to get Candle device handle');
      }
    } finally {
      calloc.free(devPtr);
    }

    // Open the device.
    if (!_api.devOpen(_devHandle)) {
      final errCode = _api.devLastError(_devHandle);
      final errTextPtr = _api.errorText(errCode);
      final errText = errTextPtr == nullptr ? 'unknown' : errTextPtr.toDartString();
      _api.listFree(_listPtr);
      _listPtr = nullptr;
      _devHandle = nullptr;
      throw StateError('Failed to open Candle device: $errText (code $errCode)');
    }

    // Start CAN channel 0.
    if (!_api.channelStart(_devHandle, 0, 0)) {
      _api.devClose(_devHandle);
      _api.listFree(_listPtr);
      _listPtr = nullptr;
      _devHandle = nullptr;
      throw StateError('Failed to start CAN channel');
    }

    // Allocate native frame buffer for reads/writes.
    _framePtr = calloc<GsHostFrame>();

    _isOpen = true;
    CommsLog.instance.logInfo(portName, 'Candle device opened (bidirectional CAN)');

    // Start polling for incoming CAN frames.
    _startPolling();
  }

  @override
  void close() {
    if (!_isOpen) return;
    _isOpen = false;

    _pollTimer?.cancel();
    _pollTimer = null;

    CommsLog.instance.logInfo(portName, 'Candle device closed');

    _api.channelStop(_devHandle, 0);
    _api.devClose(_devHandle);
    _api.listFree(_listPtr);

    if (_framePtr != null) {
      calloc.free(_framePtr!);
      _framePtr = null;
    }

    _devHandle = nullptr;
    _listPtr = nullptr;
    _responseController.close();
  }

  @override
  void dispose() {
    close();
  }

  // -------------------------------------------------------------------------
  // Sending — CAN frames via Candle API
  // -------------------------------------------------------------------------

  @override
  void sendRaw(Uint8List packet) {
    // For the Candle connection, sendRaw sends a CAN frame.
    // Interpret the packet as: arbId (first 4 bytes LE) + payload (next 8).
    if (!_isOpen || _framePtr == null) throw StateError('Device is not open');

    if (packet.length >= 12) {
      final bd = ByteData.sublistView(packet);
      final cmdWord = bd.getUint32(0, Endian.little);
      final arbId = cmdWord & kArbIdMask;
      final payload = Uint8List.sublistView(packet, 4, 12);
      _sendCanFrame(arbId, payload);
    } else {
      // Short packet — just send whatever bytes as a CAN frame with
      // arbId 0 and the bytes as payload. This covers edge cases.
      _sendCanFrame(0, packet);
    }
  }

  @override
  void sendCommand(int arbId, Uint8List payload) {
    CommsLog.instance.logTx(portName, arbId, payload);
    _sendCanFrame(arbId, payload);
  }

  @override
  Future<SparkResponse> sendAndReceive(
    int arbId,
    Uint8List payload, {
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    sendCommand(arbId, payload);

    const matchMask = 0x1FFFFFC0;

    try {
      return await _responseController.stream
          .where((r) => (r.arbId & matchMask) == (arbId & matchMask))
          .first
          .timeout(timeout);
    } on TimeoutException {
      final apiClass = extractApiClass(arbId);
      final apiIndex = extractApiIndex(arbId);
      CommsLog.instance.logError(
        portName,
        'Timeout waiting for response '
        '(apiClass=0x${apiClass.toRadixString(16)}, '
        'apiIndex=0x${apiIndex.toRadixString(16)})',
      );
      rethrow;
    }
  }

  void _sendCanFrame(int arbId, Uint8List payload) {
    if (!_isOpen || _framePtr == null) throw StateError('Device is not open');

    final frame = _framePtr!.ref;
    frame.echoId = 0;
    frame.canId = arbId | gsCanFlagEff; // 29-bit extended frame
    frame.canDlc = payload.length.clamp(0, 8);
    frame.channel = 0;
    frame.flags = 0;
    frame.reserved = 0;

    for (var i = 0; i < 8; i++) {
      frame.data[i] = i < payload.length ? payload[i] : 0;
    }

    final ok = _api.frameSend(_devHandle, 0, _framePtr!, 1000);
    if (!ok) {
      final errCode = _api.devLastError(_devHandle);
      debugPrint('[CandleConnection] frameSend failed (error $errCode)');
    }
  }

  // -------------------------------------------------------------------------
  // Receiving — poll CAN frames
  // -------------------------------------------------------------------------

  @override
  Stream<SparkResponse> get responses => _responseController.stream;

  /// Start a periodic timer that reads CAN frames from the device.
  ///
  /// Each tick reads up to [_maxFramesPerTick] frames with a short
  /// per-frame timeout.  This keeps latency ≤~2 ms for responses while
  /// not blocking the UI isolate for too long.
  void _startPolling() {
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => _pollFrames(),
    );
  }

  /// Maximum frames to drain per poll tick to avoid blocking the event loop.
  static const int _maxFramesPerTick = 20;

  void _pollFrames() {
    if (!_isOpen || _framePtr == null) return;

    for (var i = 0; i < _maxFramesPerTick; i++) {
      final ok = _api.frameRead(_devHandle, _framePtr!, 0); // non-blocking
      if (!ok) break; // no more frames available

      final frame = _framePtr!.ref;
      final arbId = frame.canId & kArbIdMask;
      final dlc = frame.canDlc.clamp(0, 8);

      final payload = Uint8List(8);
      for (var j = 0; j < 8; j++) {
        payload[j] = j < dlc ? frame.data[j] : 0;
      }

      final response = SparkResponse(
        responseType: kUsbResponseData,
        arbId: arbId,
        payload: payload,
      );

      _processResponse(response);
    }
  }

  /// Process a single decoded response — updates cached status frames
  /// and pushes to the response stream.
  ///
  /// This mirrors [SparkConnection._processResponse] so both connection
  /// types produce identical behavior for downstream consumers.
  void _processResponse(SparkResponse response) {
    CommsLog.instance.logRx(portName, response);

    if (response.apiClass == kApiClassNewStatus) {
      _usingNewProtocol = true;
      final parsed = parseStatusFrame(response);
      if (parsed is ({StatusFrame0 status0, StatusFrame1 partialStatus1})) {
        lastStatus0 = parsed.status0;
        final prev = lastStatus1;
        lastStatus1 = StatusFrame1(
          velocityRpm: prev?.velocityRpm ?? 0.0,
          temperatureC: parsed.partialStatus1.temperatureC,
          busVoltage: parsed.partialStatus1.busVoltage,
          outputCurrentAmps: parsed.partialStatus1.outputCurrentAmps,
        );
      } else if (parsed
          is ({StatusFrame1? velocityUpdate, StatusFrame2 status2})) {
        lastStatus2 = parsed.status2;
        if (parsed.velocityUpdate != null) {
          final prev = lastStatus1;
          lastStatus1 = StatusFrame1(
            velocityRpm: parsed.velocityUpdate!.velocityRpm,
            temperatureC: prev?.temperatureC ?? 0,
            busVoltage: prev?.busVoltage ?? 0.0,
            outputCurrentAmps: prev?.outputCurrentAmps ?? 0.0,
          );
        }
      }
    } else if (response.apiClass == kApiClassStatus && !_usingNewProtocol) {
      final parsed = parseStatusFrame(response);
      if (parsed is StatusFrame0) lastStatus0 = parsed;
      if (parsed is StatusFrame1) lastStatus1 = parsed;
      if (parsed is StatusFrame2) lastStatus2 = parsed;
    }

    if (!_responseController.isClosed) {
      _responseController.add(response);
    }
  }

  // -------------------------------------------------------------------------
  // Static helpers — device enumeration
  // -------------------------------------------------------------------------

  /// Scan for available Candle/WinUSB CAN devices.
  ///
  /// Returns a list of discovered devices, or an empty list if CANBridge.dll
  /// is unavailable or no devices are found.
  static List<CandleDeviceInfo> scanDevices() {
    final api = CandleApi.load();
    if (api == null) return [];

    final listPtrPtr = calloc<Pointer<Void>>();
    try {
      final ok = api.listScan(listPtrPtr);
      final listPtr = listPtrPtr.value;
      if (!ok || listPtr == nullptr) return [];

      final count = api.listLength(listPtr);
      final devices = <CandleDeviceInfo>[];

      final devPtr = calloc<Pointer<Void>>();
      try {
        for (var i = 0; i < count; i++) {
          if (api.devGet(listPtr, i, devPtr) && devPtr.value != nullptr) {
            final pathPtr = api.devGetPath(devPtr.value);
            final namePtr = api.devGetName(devPtr.value);
            devices.add(CandleDeviceInfo(
              path: pathPtr == nullptr ? '' : pathPtr.toDartString(),
              name: namePtr == nullptr ? 'Unknown' : namePtr.toDartString(),
              index: i,
            ));
          }
        }
      } finally {
        calloc.free(devPtr);
      }

      api.listFree(listPtr);
      return devices;
    } finally {
      calloc.free(listPtrPtr);
    }
  }

  /// Create a [CandleConnection] for the device at [deviceIndex].
  ///
  /// Returns `null` if CANBridge.dll is not available.
  static CandleConnection? create({int deviceIndex = 0, String? deviceName}) {
    final api = CandleApi.load();
    if (api == null) return null;
    return CandleConnection(api, deviceIndex: deviceIndex, deviceName: deviceName);
  }
}
