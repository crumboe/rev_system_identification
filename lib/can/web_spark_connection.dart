/// Web Serial API implementation of [ISparkConnection].
///
/// Uses the browser's Web Serial API (Chromium-only) to communicate with
/// SPARK MAX/Flex controllers over USB-CDC serial.  The SLCAN protocol,
/// status frame parsing, and response demuxing are identical to the native
/// [SparkConnection] — only the transport layer differs.
///
/// This file is only compiled on web targets via the conditional export
/// in `spark_connection.dart`.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'comms_log.dart';
import 'interfaces.dart';
import 'spark_protocol.dart';
import 'status_parser.dart';

// ---------------------------------------------------------------------------
// JS interop bindings for Web Serial API
// ---------------------------------------------------------------------------

/// Minimal bindings for the parts of the Web Serial API we need.
/// The `package:web` types don't yet cover Serial, so we use extension
/// types on JSObject.

@JS('navigator.serial')
external JSObject? get _navigatorSerial;

/// Typed wrapper around the `navigator.serial` object.
Serial? get _serial {
  final raw = _navigatorSerial;
  return raw == null ? null : raw as Serial;
}

extension type Serial._(JSObject _) implements JSObject {
  external JSPromise<JSArray<SerialPort>> getPorts();
  external JSPromise<SerialPort> requestPort([SerialPortRequestOptions? options]);
}

extension type SerialPort._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> open(SerialOptions options);
  external JSPromise<JSAny?> close();
  external web.ReadableStream get readable;
  external web.WritableStream get writable;
}

extension type SerialOptions._(JSObject _) implements JSObject {
  external factory SerialOptions({
    int baudRate,
    int dataBits,
    int stopBits,
    JSString parity,
    JSString flowControl,
  });
}

extension type SerialPortRequestOptions._(JSObject _) implements JSObject {
  external factory SerialPortRequestOptions({
    JSArray<SerialPortFilter> filters,
  });
}

extension type SerialPortFilter._(JSObject _) implements JSObject {
  external factory SerialPortFilter({int usbVendorId, int? usbProductId});
}

// ---------------------------------------------------------------------------
// WebSparkConnection
// ---------------------------------------------------------------------------

/// Web Serial API implementation of the SPARK connection interface.
///
/// Mirrors the native [SparkConnection]'s SLCAN init sequence, hybrid
/// SLCAN+binary receive parser, and status frame caching.
class WebSparkConnection implements ISparkConnection {
  SerialPort? _port;
  final String _label;

  web.ReadableStreamDefaultReader? _reader;
  web.WritableStreamDefaultWriter? _writer;

  bool _isOpen = false;
  @override
  bool get isOpen => _isOpen;

  @override
  String get portName => _label;

  final StreamController<SparkResponse> _responseController =
      StreamController<SparkResponse>.broadcast();

  @override
  StatusFrame0? lastStatus0;
  @override
  StatusFrame1? lastStatus1;
  @override
  StatusFrame2? lastStatus2;
  @override
  StatusFrame5? lastStatus5;
  @override
  NewStatusFrame1? lastNewStatus1;

  final _rxBuf = <int>[];
  final _rawCapture = <int>[];
  bool _usingNewProtocol = false;

  @override
  bool rawCaptureEnabled = false;

  @override
  List<int> takeRawCapture() {
    final snapshot = List<int>.from(_rawCapture);
    _rawCapture.clear();
    return snapshot;
  }

  /// Whether this port was obtained via `navigator.serial.requestPort()`
  /// (user-granted) vs `getPorts()` (previously-granted).
  final bool _userGranted;

  /// Create a connection wrapping a Web Serial port.
  ///
  /// [port] is obtained from `navigator.serial.requestPort()` or
  /// `navigator.serial.getPorts()`.
  /// [label] is a human-readable name shown in the device list.
  WebSparkConnection(SerialPort port, {String label = 'Web Serial', bool userGranted = true})
      : _port = port,
        _label = label,
        _userGranted = userGranted;

  // -----------------------------------------------------------------------
  // Connection lifecycle
  // -----------------------------------------------------------------------

  @override
  Future<void> open() async {
    if (_isOpen) return;
    final port = _port;
    if (port == null) throw StateError('No serial port assigned');

    // The browser throws InvalidStateError if the port is already open
    // (e.g. after a disconnect that didn't fully close it). In that case,
    // close it first and retry.
    try {
      await port.open(SerialOptions(
        baudRate: 115200,
        dataBits: 8,
        stopBits: 1,
        parity: 'none'.toJS,
        flowControl: 'none'.toJS,
      )).toDart;
    } catch (e) {
      // Likely InvalidStateError — port already open. Close and retry once.
      try {
        await port.close().toDart;
      } catch (_) {}
      await port.open(SerialOptions(
        baudRate: 115200,
        dataBits: 8,
        stopBits: 1,
        parity: 'none'.toJS,
        flowControl: 'none'.toJS,
      )).toDart;
    }

    _writer = port.writable.getWriter();
    _isOpen = true;
    CommsLog.instance.logInfo(_label, 'Port opened at 115200 8N1');

    // Settle delay (matches native 300 ms).
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // SLCAN init: set bitrate to 1 Mbps, open CAN channel.
    await _writeBytes('S8\r'.codeUnits);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await _writeBytes('O\r'.codeUnits);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    CommsLog.instance.logInfo(_label, 'SLCAN init: S8 + O sent');

    // Start the read loop.
    _startReadLoop(port);
  }

  /// Continuously read from the serial port's readable stream.
  void _startReadLoop(SerialPort port) {
    _reader = port.readable.getReader() as web.ReadableStreamDefaultReader;
    _readLoop();
  }

  Future<void> _readLoop() async {
    final reader = _reader;
    if (reader == null) return;

    try {
      while (_isOpen) {
        final result = await reader.read().toDart;
        if (result.done) break;
        final chunk = result.value;
        if (chunk != null) {
          final bytes = (chunk as JSUint8Array).toDart;
          _onDataReceived(bytes);
        }
      }
    } catch (e) {
      if (_isOpen) {
        CommsLog.instance.logError(_label, 'Read error: $e');
        close();
      }
    }
  }

  @override
  void close() {
    if (!_isOpen) return;
    _isOpen = false;
    CommsLog.instance.logInfo(_label, 'Port closed');

    try {
      _reader?.cancel().toDart.ignore();
    } catch (_) {}
    try {
      _writer?.close().toDart.ignore();
    } catch (_) {}

    _reader = null;
    _writer = null;

    // Close the underlying browser serial port so it can be re-opened later
    // (by auto-reconnect or a fresh requestPort() call).
    try {
      _port?.close().toDart.ignore();
    } catch (_) {}

    _responseController.close();
  }

  @override
  void dispose() {
    close();
    _port = null;
  }

  // -----------------------------------------------------------------------
  // Sending
  // -----------------------------------------------------------------------

  @override
  void sendRaw(Uint8List packet) {
    if (!_isOpen) throw StateError('Port is not open');
    _writeBytes(packet);
  }

  @override
  void sendCommand(int arbId, Uint8List payload) {
    CommsLog.instance.logTx(_label, arbId, payload);
    final slcan = encodeSlcanFrame(arbId, payload);
    _writeBytes(Uint8List.fromList(slcan.codeUnits));
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
      CommsLog.instance.logError(
        _label,
        'Timeout waiting for response '
        '(apiClass=0x${extractApiClass(arbId).toRadixString(16)}, '
        'apiIndex=0x${extractApiIndex(arbId).toRadixString(16)})',
      );
      rethrow;
    }
  }

  @override
  Stream<SparkResponse> get responses => _responseController.stream;

  // -----------------------------------------------------------------------
  // Writing helper
  // -----------------------------------------------------------------------

  Future<void> _writeBytes(List<int> bytes) async {
    final writer = _writer;
    if (writer == null) return;
    final data = Uint8List.fromList(bytes);
    await writer.write(data.toJS).toDart;
  }

  // -----------------------------------------------------------------------
  // Receiving — identical parsing logic to native SparkConnection
  // -----------------------------------------------------------------------

  void _onDataReceived(Uint8List data) {
    if (rawCaptureEnabled) _rawCapture.addAll(data);
    _rxBuf.addAll(data);
    _drainRxBuf();
  }

  void _drainRxBuf() {
    while (_rxBuf.isNotEmpty) {
      final first = _rxBuf.first;

      if (first == 0x54 || first == 0x74) {
        if (!_tryParseSlcanLine()) return;
      } else if (first == 0x0D || first == 0x0A) {
        _rxBuf.removeAt(0);
        continue;
      } else if (_looksLikeBinarySparkPacket()) {
        if (!_tryParseBinaryPacket()) return;
      } else if (first >= 0x20 && first < 0x7F) {
        if (!_skipToNextCr()) return;
      } else {
        if (!_tryParseBinaryPacket()) return;
      }
    }
  }

  bool _looksLikeBinarySparkPacket() {
    if (_rxBuf.length < 4) return false;
    return _rxBuf[2] == 0x05 && (_rxBuf[3] == 0x02 || _rxBuf[3] == 0x22);
  }

  bool _tryParseSlcanLine() {
    final crIdx = _rxBuf.indexOf(0x0D);
    if (crIdx == -1) return false;

    final lineBytes = _rxBuf.sublist(0, crIdx);
    var consume = crIdx + 1;
    if (consume < _rxBuf.length && _rxBuf[consume] == 0x0A) consume++;
    _rxBuf.removeRange(0, consume);

    final line = String.fromCharCodes(lineBytes);
    if (line.isEmpty) return true;

    final response = decodeSlcanFrame(line);
    if (response != null) {
      _processResponse(response);
    } else {
      CommsLog.instance.logInfo(
        _label,
        'Unrecognized SLCAN: "${line.length > 80 ? line.substring(0, 80) : line}"',
      );
    }
    return true;
  }

  bool _skipToNextCr() {
    final crIdx = _rxBuf.indexOf(0x0D);
    if (crIdx == -1) return false;
    var consume = crIdx + 1;
    if (consume < _rxBuf.length && _rxBuf[consume] == 0x0A) consume++;
    final skipped = String.fromCharCodes(_rxBuf.sublist(0, crIdx));
    _rxBuf.removeRange(0, consume);
    CommsLog.instance.logInfo(
      _label,
      'Skipped non-frame text: "${skipped.length > 60 ? skipped.substring(0, 60) : skipped}"',
    );
    return true;
  }

  bool _tryParseBinaryPacket() {
    if (_rxBuf.length < 12) return false;

    final packetBytes = Uint8List.fromList(_rxBuf.sublist(0, 12));
    _rxBuf.removeRange(0, 12);

    final response = decodePacket(packetBytes);
    _processResponse(response);
    return true;
  }

  void _processResponse(SparkResponse response) {
    // Log the received packet.
    CommsLog.instance.logRx(_label, response);

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
      } else if (parsed is NewStatusFrame1) {
        lastNewStatus1 = parsed;
      }
    } else if (response.apiClass == kApiClassStatus && !_usingNewProtocol) {
      final parsed = parseStatusFrame(response);
      if (parsed is StatusFrame0) lastStatus0 = parsed;
      if (parsed is StatusFrame1) lastStatus1 = parsed;
      if (parsed is StatusFrame2) lastStatus2 = parsed;
      if (parsed is StatusFrame5) lastStatus5 = parsed;
    }

    if (!_responseController.isClosed) {
      _responseController.add(response);
    }
  }

  // -----------------------------------------------------------------------
  // Web Serial API helpers (static)
  // -----------------------------------------------------------------------

  /// Whether the Web Serial API is available in this browser.
  static bool get isAvailable => _serial != null;

  /// Request the user to select a serial port (requires user gesture).
  ///
  /// Filters for STM32 USB VID (0x0483), which is used by SPARK MAX/Flex.
  /// Returns a [WebSparkConnection] wrapping the granted port.
  static Future<WebSparkConnection> requestPort() async {
    final serial = _serial;
    if (serial == null) {
      throw UnsupportedError(
        'Web Serial API is not available in this browser. '
        'Use Chrome, Edge, or Opera for hardware support.',
      );
    }

    final port = await serial.requestPort(
      SerialPortRequestOptions(
        filters: [
          SerialPortFilter(usbVendorId: 0x0483),
        ].toJS,
      ),
    ).toDart;

    return WebSparkConnection(port, label: 'SPARK (Web Serial)', userGranted: true);
  }

  /// Get previously-granted serial ports (no user gesture needed).
  static Future<List<WebSparkConnection>> getGrantedPorts() async {
    final serial = _serial;
    if (serial == null) return [];

    final ports = await serial.getPorts().toDart;
    return [
      for (var i = 0; i < ports.length; i++)
        WebSparkConnection(
          ports[i],
          label: 'SPARK #${i + 1} (Web Serial)',
          userGranted: false,
        ),
    ];
  }
}
