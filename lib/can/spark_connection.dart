/// USB-serial connection to a SPARK MAX/Flex controller.
///
/// Opens a COM port at 115200 8N1, sends command packets, receives response
/// packets, and demuxes status frames from ack/data responses.
///
/// The SPARK MAX uses SLCAN (Serial Line CAN) text protocol:
///
/// * **Commands** are sent as SLCAN extended frames:
///   `T<8-hex arb-ID><DLC><hex data>\r`
///
/// * **Status / broadcast frames** come back as SLCAN text.
///
/// * **Command responses** may arrive as SLCAN text or (potentially)
///   as binary 12-byte packets.
///
/// The receive path handles both SLCAN text and binary packets to be safe.
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

  /// Raw byte buffer for incoming data — processes both SLCAN text and
  /// binary 12-byte packets in a unified stream.
  final _rxBuf = <int>[];

  /// Raw byte capture — when enabled, every received byte is also stored here
  /// for diagnostics to inspect before/after the parser processes them.
  final _rawCapture = <int>[];
  bool rawCaptureEnabled = false;

  /// Take a snapshot of captured raw bytes and clear the buffer.
  List<int> takeRawCapture() {
    final snapshot = List<int>.from(_rawCapture);
    _rawCapture.clear();
    return snapshot;
  }

  bool _isOpen = false;
  bool get isOpen => _isOpen;

  /// The COM port name (e.g. "COM3").
  String get portName => _port.name ?? 'unknown';

  /// Human-readable description of the current protocol mode.
  String get protocolModeDescription => 'SLCAN TX, hybrid SLCAN+binary RX';

  SparkConnection(this._port);

  // -------------------------------------------------------------------------
  // Connection lifecycle
  // -------------------------------------------------------------------------

  /// Open the serial port, run the SLCAN init sequence, and start listening.
  ///
  /// Mirrors the proven Python init sequence from spark_rw_verify.py:
  ///   1. Open port at 115200 8N1
  ///   2. Wait 300 ms for the port/device to settle
  ///   3. Flush any stale data in the receive buffer
  ///   4. Send `S8\r` (set CAN bitrate to 1 Mbps)
  ///   5. Wait 20 ms
  ///   6. Send `O\r`  (open the CAN channel)
  ///   7. Wait 100 ms for the device to process
  ///   8. Flush receive buffer again (discard echo / garbage)
  ///
  /// Throws [SerialPortError] if the port cannot be opened.
  Future<void> open() async {
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

    // Let the port and device settle after open (matches Python's 300 ms).
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Drain any stale bytes sitting in the OS receive buffer.
    _port.flush();

    // SLCAN init: set bitrate to 1 Mbps, then open the CAN channel.
    _port.write(Uint8List.fromList('S8\r'.codeUnits));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    _port.write(Uint8List.fromList('O\r'.codeUnits));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Flush echo / garbage produced by the init commands.
    _port.flush();
    CommsLog.instance.logInfo(portName, 'SLCAN init: S8 + O sent');

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
  // Sending — SLCAN text frames
  // -------------------------------------------------------------------------

  /// Send raw bytes to the serial port.
  ///
  /// Used by the heartbeat (which sends a binary 12-byte packet) and by
  /// diagnostics that need to test raw binary frames.
  void sendRaw(Uint8List packet) {
    if (!_isOpen) throw StateError('Port is not open');
    _port.write(packet);
  }

  /// Send a command to the connected controller.
  ///
  /// [arbId] is the 29-bit CAN arb ID, [payload] is ≤ 8 bytes.
  /// Encodes as an SLCAN extended frame (`T<arbId><DLC><data>\r`) and
  /// writes the ASCII text to the serial port.
  void sendCommand(int arbId, Uint8List payload) {
    CommsLog.instance.logTx(portName, arbId, payload);
    final slcan = encodeSlcanFrame(arbId, payload);
    _port.write(Uint8List.fromList(slcan.codeUnits));
  }

  /// Send a command and wait for the ack/data response.
  ///
  /// Times out after [timeout] (default 500 ms).
  ///
  /// Response matching ignores the device-ID field (lower 6 bits of the arb
  /// ID) because the controller echoes its real CAN ID in every response.
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

  /// Hybrid receive handler — processes mixed SLCAN text and binary packets
  /// from the same byte stream.
  ///
  /// SLCAN frames always start with an ASCII letter ('T', 't', 'r', 'R',
  /// etc.) and end with CR (`\r`, 0x0D).  Binary 12-byte response packets
  /// start with a uint32-LE command word whose MSB (byte index 3) has
  /// bits 31:29 = responseType (0 or 1) and bits 28:24 = devType (0x02),
  /// so byte[3] is always in the range 0x00–0x3F — never a printable ASCII
  /// letter.  We use this to distinguish the two formats.
  void _onDataReceived(Uint8List data) {
    if (rawCaptureEnabled) _rawCapture.addAll(data);
    _rxBuf.addAll(data);
    _drainRxBuf();
  }

  /// Consume as many complete frames (SLCAN or binary) from [_rxBuf] as
  /// possible.
  void _drainRxBuf() {
    while (_rxBuf.isNotEmpty) {
      final first = _rxBuf.first;

      if (first == 0x54 || first == 0x74) {
        // 'T' (0x54) or 't' (0x74) — SLCAN extended/standard frame.
        if (!_tryParseSlcanLine()) return; // need more data
      } else if (first == 0x0D || first == 0x0A) {
        // Stray CR/LF — skip.
        _rxBuf.removeAt(0);
      } else if (_looksLikeBinarySparkPacket()) {
        // Binary 12-byte response whose first byte may be printable ASCII.
        // Must check this BEFORE the generic printable-ASCII skip, because
        // binary responses with apiIndex=1 & deviceId=7 have byte[0]=0x47
        // ('G') which falls in the printable range.
        if (!_tryParseBinaryPacket()) return; // need more data
      } else if (first >= 0x20 && first < 0x7F) {
        // Other printable ASCII — likely an SLCAN command echo
        // (e.g. 'V', 'N', 'O', 'S', 'C', 'z', 'Z').
        // Consume until CR, then discard.
        if (!_skipToNextCr()) return; // need more data
      } else {
        // Non-printable byte that doesn't match a SPARK header — could be
        // a binary packet from a non-SPARK device or corrupted data.
        if (!_tryParseBinaryPacket()) return; // need more data
      }
    }
  }

  /// Check whether the bytes at the head of [_rxBuf] look like a binary
  /// SPARK MAX response packet.
  ///
  /// Binary responses are 12 bytes: uint32-LE command word + 8-byte payload.
  /// The command word is `(responseType << 29) | arbId` where the arbId
  /// contains devType (bits 28:24) and manufacturer (bits 23:16).
  ///
  /// For SPARK MAX: devType=2, manufacturer=5.
  /// In little-endian layout:
  ///   byte[2] = manufacturer = 0x05
  ///   byte[3] = (responseType << 5) | devType
  ///           = 0x02 (rspType=0) or 0x22 (rspType=1)
  bool _looksLikeBinarySparkPacket() {
    if (_rxBuf.length < 4) return false;
    return _rxBuf[2] == 0x05 &&
        (_rxBuf[3] == 0x02 || _rxBuf[3] == 0x22);
  }

  /// Try to extract a complete SLCAN line (up to CR) from [_rxBuf].
  /// Returns false if we need more data.
  bool _tryParseSlcanLine() {
    final crIdx = _rxBuf.indexOf(0x0D); // '\r'
    if (crIdx == -1) return false; // no complete line yet

    final lineBytes = _rxBuf.sublist(0, crIdx);
    // Remove the line + CR (and optional LF).
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
        portName,
        'Unrecognized SLCAN: "${line.length > 80 ? line.substring(0, 80) : line}"',
      );
    }
    return true;
  }

  /// Skip past an unrecognized ASCII line (up to CR).
  bool _skipToNextCr() {
    final crIdx = _rxBuf.indexOf(0x0D);
    if (crIdx == -1) return false;
    var consume = crIdx + 1;
    if (consume < _rxBuf.length && _rxBuf[consume] == 0x0A) consume++;
    final skipped = String.fromCharCodes(_rxBuf.sublist(0, crIdx));
    _rxBuf.removeRange(0, consume);
    CommsLog.instance.logInfo(
      portName,
      'Skipped non-frame text: "${skipped.length > 60 ? skipped.substring(0, 60) : skipped}"',
    );
    return true;
  }

  /// Try to extract a 12-byte binary packet from [_rxBuf].
  /// Returns false if we need more data.
  bool _tryParseBinaryPacket() {
    if (_rxBuf.length < 12) return false;

    final packetBytes = Uint8List.fromList(_rxBuf.sublist(0, 12));
    _rxBuf.removeRange(0, 12);

    final response = decodePacket(packetBytes);
    _processResponse(response);
    return true;
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
