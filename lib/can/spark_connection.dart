/// USB-serial connection to a SPARK MAX/Flex controller.
///
/// Opens a COM port at 115200 8N1, sends 12-byte command packets, receives
/// 12-byte response packets, and demuxes status frames from ack/data
/// responses.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'interfaces.dart';
import 'spark_protocol.dart';
import 'status_parser.dart';

/// Represents a live USB-serial connection to one SPARK controller.
class SparkConnection implements ISparkConnection {
  final SerialPort _port;
  SerialPortReader? _reader;

  /// Stream of parsed status frames received from the controller.
  final StreamController<SparkResponse> _responseController =
      StreamController<SparkResponse>.broadcast();

  /// Latest parsed status frames, updated as they arrive.
  StatusFrame0? lastStatus0;
  StatusFrame1? lastStatus1;
  StatusFrame2? lastStatus2;

  /// Raw byte buffer for reassembling 12-byte packets.
  final _rxBuffer = BytesBuilder(copy: false);

  bool _isOpen = false;
  bool get isOpen => _isOpen;

  /// The COM port name (e.g. "COM3").
  String get portName => _port.name ?? 'unknown';

  SparkConnection(this._port);

  // -------------------------------------------------------------------------
  // Connection lifecycle
  // -------------------------------------------------------------------------

  /// Open the serial port and start listening for responses.
  ///
  /// Throws [SerialPortError] if the port cannot be opened.
  void open() {
    if (_isOpen) return;

    final config = SerialPortConfig()
      ..baudRate = 115200
      ..bits = 8
      ..parity = SerialPortParity.none
      ..stopBits = 1
      ..setFlowControl(SerialPortFlowControl.none);

    if (!_port.openReadWrite()) {
      throw SerialPortError(
        'Failed to open ${_port.name}: ${SerialPort.lastError}',
      );
    }
    _port.config = config;
    _isOpen = true;

    // Start reading in the background.
    _reader = SerialPortReader(_port, timeout: 100);
    _reader!.stream.listen(
      _onDataReceived,
      onError: (Object e) {
        // Port may have been disconnected.
        close();
      },
    );
  }

  /// Close the connection and release the port.
  void close() {
    if (!_isOpen) return;
    _isOpen = false;
    _reader?.close();
    _reader = null;
    _port.close();
    _responseController.close();
  }

  /// Dispose of resources.  Call this instead of [close] when the connection
  /// will never be reopened.
  void dispose() {
    close();
    _port.dispose();
  }

  // -------------------------------------------------------------------------
  // Sending
  // -------------------------------------------------------------------------

  /// Send a raw 12-byte packet.
  void sendRaw(Uint8List packet) {
    assert(packet.length == 12);
    if (!_isOpen) throw StateError('Port is not open');
    _port.write(packet);
  }

  /// Send a command to the connected controller.
  ///
  /// [arbId] is the 29-bit CAN arb ID, [payload] is ≤ 8 bytes.
  void sendCommand(int arbId, Uint8List payload) {
    sendRaw(encodePacket(arbId, payload));
  }

  /// Send a command and wait for the ack/data response.
  ///
  /// Times out after [timeout] (default 500 ms).
  Future<SparkResponse> sendAndReceive(
    int arbId,
    Uint8List payload, {
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    sendCommand(arbId, payload);

    // Wait for a response whose arb ID matches (modulo response type bits).
    return _responseController.stream
        .where((r) =>
            (r.arbId & 0x1FFFFFFF) == (arbId & 0x1FFFFFFF) ||
            r.apiClass == extractApiClass(arbId))
        .first
        .timeout(timeout);
  }

  // -------------------------------------------------------------------------
  // Receiving
  // -------------------------------------------------------------------------

  /// Stream of all responses (status frames, acks, data).
  Stream<SparkResponse> get responses => _responseController.stream;

  /// Stream of only status frames, parsed into typed objects.
  Stream<Object> get statusFrames => _responseController.stream
      .where((r) => r.apiClass == kApiClassStatus)
      .map((r) => parseStatusFrame(r))
      .where((obj) => obj != null)
      .cast<Object>();

  void _onDataReceived(Uint8List data) {
    _rxBuffer.add(data);

    // Process all complete 12-byte packets in the buffer.
    while (_rxBuffer.length >= 12) {
      final bytes = _rxBuffer.takeBytes();
      final packet = Uint8List.sublistView(bytes, 0, 12);
      final remainder = bytes.length > 12
          ? Uint8List.sublistView(bytes, 12)
          : null;

      final response = decodePacket(packet);

      // Update cached status frames.
      if (response.apiClass == kApiClassStatus) {
        final parsed = parseStatusFrame(response);
        if (parsed is StatusFrame0) lastStatus0 = parsed;
        if (parsed is StatusFrame1) lastStatus1 = parsed;
        if (parsed is StatusFrame2) lastStatus2 = parsed;
      }

      if (!_responseController.isClosed) {
        _responseController.add(response);
      }

      if (remainder != null && remainder.isNotEmpty) {
        _rxBuffer.add(remainder);
      }
    }
  }

  // -------------------------------------------------------------------------
  // Port enumeration
  // -------------------------------------------------------------------------

  /// List available serial ports on the system.
  static List<String> availablePorts() {
    return SerialPort.availablePorts;
  }

  /// Get a human-readable description for a port.
  static String portDescription(String portName) {
    final port = SerialPort(portName);
    final desc = port.description ?? portName;
    port.dispose();
    return desc;
  }

  /// Get the manufacturer string for a port.
  static String? portManufacturer(String portName) {
    final port = SerialPort(portName);
    final mfr = port.manufacturer;
    port.dispose();
    return mfr;
  }

  /// Create a [SparkConnection] for the given COM port name.
  static SparkConnection fromPortName(String portName) {
    return SparkConnection(SerialPort(portName));
  }
}
