/// USB-serial connection to a SPARK MAX/Flex controller.
///
/// Opens a COM port at 115200 8N1, sends command packets, receives response
/// packets, and demuxes status frames from ack/data responses.
///
/// Two wire formats are supported and auto-detected on the first received
/// data:
///
/// * **Binary 12-byte packets** — the legacy SPARK USB-serial protocol.
///   Each packet is a 4-byte command word (uint32 LE) + 8-byte payload.
///
/// * **SLCAN text frames** — the Serial Line CAN protocol used by some
///   firmware revisions.  Each frame is a CR-terminated ASCII string:
///   `T<8-hex arb-ID><DLC><hex data>\r[\n]`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_libserialport/flutter_libserialport.dart';

import 'comms_log.dart';
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

  /// Raw byte buffer for reassembling packets.
  final _rxBuffer = BytesBuilder(copy: false);

  /// Whether the controller uses SLCAN text protocol instead of binary.
  bool _slcanMode = false;

  /// Whether the protocol has been auto-detected.
  bool _protocolDetected = false;

  /// Text accumulator for SLCAN line assembly.
  String _slcanText = '';

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
    CommsLog.instance.logInfo(portName, 'Port opened at 115200 8N1');

    // Start reading in the background.
    _reader = SerialPortReader(_port, timeout: 100);
    _reader!.stream.listen(
      _onDataReceived,
      onError: (Object e) {
        // Port may have been disconnected.
        CommsLog.instance.logError(portName, 'Serial port error: $e');
        close();
      },
    );
  }

  /// Close the connection and release the port.
  void close() {
    if (!_isOpen) return;
    _isOpen = false;
    CommsLog.instance.logInfo(portName, 'Port closed');
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
  ///
  /// In SLCAN mode the binary packet is transparently re-encoded as an
  /// SLCAN text frame before being written to the port.
  void sendRaw(Uint8List packet) {
    assert(packet.length == 12);
    if (!_isOpen) throw StateError('Port is not open');
    if (_slcanMode) {
      // Decode the binary packet to extract arb ID + payload, then
      // re-encode as SLCAN text.
      final decoded = decodePacket(packet);
      final frame = encodeSlcanFrame(decoded.arbId, decoded.payload);
      _port.write(Uint8List.fromList(frame.codeUnits));
    } else {
      _port.write(packet);
    }
  }

  /// Send a command to the connected controller.
  ///
  /// [arbId] is the 29-bit CAN arb ID, [payload] is ≤ 8 bytes.
  /// In SLCAN mode the command is sent as an SLCAN text frame.
  void sendCommand(int arbId, Uint8List payload) {
    CommsLog.instance.logTx(portName, arbId, payload);
    if (_slcanMode) {
      if (!_isOpen) throw StateError('Port is not open');
      final frame = encodeSlcanFrame(arbId, payload);
      _port.write(Uint8List.fromList(frame.codeUnits));
    } else {
      sendRaw(encodePacket(arbId, payload));
    }
  }

  /// Send a command and wait for the ack/data response.
  ///
  /// Times out after [timeout] (default 500 ms).
  ///
  /// Response matching ignores the device-ID field (lower 6 bits of the arb
  /// ID) because the controller echoes its real CAN ID in every response,
  /// while outbound USB commands always use device ID 0 (DNC over USB).
  /// Matching on the remaining bits — device type, manufacturer, API class,
  /// and API index — is specific enough to identify the correct response.
  Future<SparkResponse> sendAndReceive(
    int arbId,
    Uint8List payload, {
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    sendCommand(arbId, payload);

    // Mask that keeps device-type (28:24), manufacturer (23:16),
    // API class (15:10), and API index (9:6) while clearing device ID (5:0).
    // 0x1FFFFFC0 = 0x1FFFFFFF & ~0x3F
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

  // -------------------------------------------------------------------------
  // Receiving
  // -------------------------------------------------------------------------

  /// Stream of all responses (status frames, acks, data).
  Stream<SparkResponse> get responses => _responseController.stream;

  /// Stream of only status frames, parsed into typed objects.
  Stream<Object> get statusFrames => _responseController.stream
      .where((r) =>
          r.apiClass == kApiClassStatus ||
          r.apiClass == kApiClassNewStatus)
      .map((r) => parseStatusFrame(r))
      .where((obj) => obj != null)
      .cast<Object>();

  /// Whether we have received at least one new-protocol status frame.
  /// Once true, we prefer new-protocol data over legacy data.
  bool _usingNewProtocol = false;

  void _onDataReceived(Uint8List data) {
    // ----- SLCAN mode: accumulate text and extract CR-delimited lines ------
    if (_slcanMode) {
      _slcanText += String.fromCharCodes(data);
      _processSlcanLines();
      return;
    }

    // ----- Auto-detect protocol from the first data received ---------------
    _rxBuffer.add(data);

    if (!_protocolDetected && _rxBuffer.length >= 4) {
      final peek = _rxBuffer.takeBytes();
      if (isSlcanData(Uint8List.fromList(peek))) {
        _slcanMode = true;
        _protocolDetected = true;
        CommsLog.instance.logInfo(
          portName,
          'Auto-detected SLCAN text protocol',
        );
        _slcanText = String.fromCharCodes(peek);
        _processSlcanLines();
        return;
      }
      // Valid binary — put the bytes back and continue as binary.
      _protocolDetected = true;
      _rxBuffer.add(peek);
    }

    if (!_protocolDetected) return; // need more data

    // ----- Binary mode: extract 12-byte packets ----------------------------
    _processBinaryPackets();
  }

  /// Process complete SLCAN text lines from [_slcanText].
  void _processSlcanLines() {
    while (true) {
      final crIdx = _slcanText.indexOf('\r');
      if (crIdx == -1) break;

      final line = _slcanText.substring(0, crIdx);

      // Consume \r and optional \n.
      var next = crIdx + 1;
      if (next < _slcanText.length && _slcanText.codeUnitAt(next) == 0x0A) {
        next++;
      }
      _slcanText = _slcanText.substring(next);

      if (line.isEmpty) continue;

      final response = decodeSlcanFrame(line);
      if (response != null) {
        _processResponse(response);
      }
    }
  }

  /// Process complete binary 12-byte packets from [_rxBuffer].
  void _processBinaryPackets() {
    while (_rxBuffer.length >= 12) {
      final bytes = _rxBuffer.takeBytes();
      final packet = Uint8List.sublistView(bytes, 0, 12);
      final remainder = bytes.length > 12
          ? Uint8List.sublistView(bytes, 12)
          : null;

      final response = decodePacket(packet);
      _processResponse(response);

      if (remainder != null && remainder.isNotEmpty) {
        _rxBuffer.add(remainder);
      }
    }
  }

  /// Process a single decoded response — shared by both binary and SLCAN
  /// code paths.
  void _processResponse(SparkResponse response) {
    // Log the received packet (status frames included but labeled as such).
    CommsLog.instance.logRx(portName, response);

    // Update cached status frames — support BOTH legacy and new protocol.
    //
    // Legacy protocol (apiClass 0x06, firmware <25.0):
    //   Status 0 → applied output, faults
    //   Status 1 → velocity, temp, voltage, current
    //   Status 2 → position
    //
    // New protocol (apiClass 0x2E, firmware ≥25.0):
    //   New Status 0 → applied output, voltage, current, temp
    //   New Status 2 → velocity + position
    //
    // Once we see a new-protocol frame, we stop updating from legacy
    // frames (which send dummy data on ≥25.0 firmware).
    if (response.apiClass == kApiClassNewStatus) {
      _usingNewProtocol = true;
      final parsed = parseStatusFrame(response);
      if (parsed is ({StatusFrame0 status0, StatusFrame1 partialStatus1})) {
        // New Status 0 provides applied output AND voltage/current/temp.
        lastStatus0 = parsed.status0;
        // Merge voltage/current/temp from new Status 0 with velocity from
        // new Status 2 (which may have arrived separately).
        final prev = lastStatus1;
        lastStatus1 = StatusFrame1(
          velocityRpm: prev?.velocityRpm ?? 0.0,
          temperatureC: parsed.partialStatus1.temperatureC,
          busVoltage: parsed.partialStatus1.busVoltage,
          outputCurrentAmps: parsed.partialStatus1.outputCurrentAmps,
        );
      } else if (parsed
          is ({StatusFrame1? velocityUpdate, StatusFrame2 status2})) {
        // New Status 2 provides velocity + position.
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
      // Only use legacy frames if we haven't seen new-protocol frames.
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
