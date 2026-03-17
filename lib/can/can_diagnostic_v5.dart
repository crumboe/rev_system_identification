/// CAN Raw Byte Diagnostic v5 — captures raw serial bytes around each command.
///
/// Previous diagnostics parse frames before reporting.  This one records
/// the raw byte stream BEFORE parsing so we can see if responses arrive
/// but get eaten by the parser.
///
/// Tests:
/// 1. Baseline — 500 ms passive capture (should be all SLCAN status frames)
/// 2. SLCAN Identify — send identify, capture raw bytes for 500 ms
/// 3. SLCAN Param Read — send param read, capture raw bytes for 500 ms
/// 4. Binary Identify (real devId) — send binary 12-byte, capture raw bytes
/// 5. Binary Param Read (real devId) — send binary 12-byte, capture raw bytes
///
/// For each test, the raw bytes are hex-dumped so we can manually spot
/// non-SLCAN (binary) response data.
library;

import 'dart:typed_data';

import 'interfaces.dart';
import 'spark_protocol.dart';

class V5DiagnosticReport {
  final String fullReport;
  V5DiagnosticReport(this.fullReport);
}

class CanDiagnosticV5 {
  final ISparkConnection _conn;
  final void Function(String) _log;

  /// How long to capture raw bytes after each command.
  final Duration _captureWindow;

  CanDiagnosticV5(
    this._conn, {
    void Function(String)? log,
    Duration captureWindow = const Duration(milliseconds: 500),
  })  : _log = log ?? ((_) {}),
        _captureWindow = captureWindow;

  Future<V5DiagnosticReport> run({
    required int deviceId,
    String protocolModeHint = 'unknown',
  }) async {
    final buf = StringBuffer();
    buf.writeln('╔══════════════════════════════════════════════════════════╗');
    buf.writeln('║       Raw Byte Diagnostic v5 — Byte-Level Capture      ║');
    buf.writeln('╚══════════════════════════════════════════════════════════╝');
    buf.writeln('Time: ${DateTime.now()}');
    buf.writeln('Protocol mode: $protocolModeHint');
    buf.writeln('Device ID: $deviceId');
    buf.writeln('Capture window: ${_captureWindow.inMilliseconds} ms per test');
    buf.writeln();

    // --- Test 1: Baseline passive capture ---
    _log('Test 1: Baseline passive capture');
    buf.writeln(_sectionHeader('Test 1: Baseline (passive, no command)'));
    var raw = await _captureRaw(sendBytes: null);
    _analyzeRaw(buf, raw, null);

    // --- Test 2: SLCAN Identify ---
    _log('Test 2: SLCAN Identify');
    final identArbId = buildArbId(
      apiClass: kApiClassFrameRate,
      apiIndex: 0x07,
      deviceId: deviceId,
    );
    final identSlcan = encodeSlcanFrame(identArbId, Uint8List(0));
    final identSlcanBytes = Uint8List.fromList(identSlcan.codeUnits);
    buf.writeln(_sectionHeader('Test 2: SLCAN Identify'));
    buf.writeln('  TX arbId: 0x${identArbId.toRadixString(16).padLeft(8, '0')}');
    buf.writeln('  TX bytes: ${_hexLine(identSlcanBytes)}');
    buf.writeln('  TX ASCII: ${_printableAscii(identSlcanBytes)}');
    raw = await _captureRaw(sendBytes: identSlcanBytes);
    _analyzeRaw(buf, raw, identSlcanBytes);

    // --- Test 3: SLCAN Param Read (modern 0x0F) ---
    _log('Test 3: SLCAN Param Read');
    final readArbId = buildArbId(
      apiClass: 0x0F,
      apiIndex: 0x00,
      deviceId: deviceId,
    );
    final readPayload = Uint8List(8); // paramId=0
    final readSlcan = encodeSlcanFrame(readArbId, readPayload);
    final readSlcanBytes = Uint8List.fromList(readSlcan.codeUnits);
    buf.writeln(_sectionHeader('Test 3: SLCAN Param Read (0x0F, paramId=0)'));
    buf.writeln('  TX arbId: 0x${readArbId.toRadixString(16).padLeft(8, '0')}');
    buf.writeln('  TX bytes: ${_hexLine(readSlcanBytes)}');
    buf.writeln('  TX ASCII: ${_printableAscii(readSlcanBytes)}');
    raw = await _captureRaw(sendBytes: readSlcanBytes);
    _analyzeRaw(buf, raw, readSlcanBytes);

    // --- Test 4: Binary Identify (real deviceId) ---
    _log('Test 4: Binary Identify (real devId)');
    final identBin = encodePacket(identArbId, Uint8List(0));
    buf.writeln(_sectionHeader('Test 4: Binary Identify (real devId=$deviceId)'));
    buf.writeln('  TX arbId: 0x${identArbId.toRadixString(16).padLeft(8, '0')}');
    buf.writeln('  TX bytes: ${_hexLine(identBin)}');
    raw = await _captureRaw(sendBytes: identBin);
    _analyzeRaw(buf, raw, identBin);

    // --- Test 5: Binary Param Read (real deviceId) ---
    _log('Test 5: Binary Param Read (real devId)');
    final readBin = encodePacket(readArbId, readPayload);
    buf.writeln(_sectionHeader('Test 5: Binary Param Read (real devId=$deviceId)'));
    buf.writeln('  TX arbId: 0x${readArbId.toRadixString(16).padLeft(8, '0')}');
    buf.writeln('  TX bytes: ${_hexLine(readBin)}');
    raw = await _captureRaw(sendBytes: readBin);
    _analyzeRaw(buf, raw, readBin);

    // --- Test 6: Binary Identify (devId=0) ---
    _log('Test 6: Binary Identify (devId=0)');
    final identArbId0 = identArbId & ~0x3F;
    final identBin0 = encodePacket(identArbId0, Uint8List(0));
    buf.writeln(_sectionHeader('Test 6: Binary Identify (devId=0)'));
    buf.writeln('  TX arbId: 0x${identArbId0.toRadixString(16).padLeft(8, '0')}');
    buf.writeln('  TX bytes: ${_hexLine(identBin0)}');
    raw = await _captureRaw(sendBytes: identBin0);
    _analyzeRaw(buf, raw, identBin0);

    // --- Test 7: Binary Param Read (devId=0) ---
    _log('Test 7: Binary Param Read (devId=0)');
    final readArbId0 = readArbId & ~0x3F;
    final readBin0 = encodePacket(readArbId0, readPayload);
    buf.writeln(_sectionHeader('Test 7: Binary Param Read (devId=0)'));
    buf.writeln('  TX arbId: 0x${readArbId0.toRadixString(16).padLeft(8, '0')}');
    buf.writeln('  TX bytes: ${_hexLine(readBin0)}');
    raw = await _captureRaw(sendBytes: readBin0);
    _analyzeRaw(buf, raw, readBin0);

    // --- Test 8: SLCAN heartbeat burst + param read ---
    _log('Test 8: SLCAN heartbeat burst then param read');
    buf.writeln(_sectionHeader(
        'Test 8: SLCAN Heartbeat Burst → Param Read'));
    buf.writeln('  Strategy: send 10 SLCAN heartbeats (20ms apart),');
    buf.writeln('  then SLCAN param read, then capture');
    {
      // Send 10 heartbeats via SLCAN to "wake" the device.
      for (var i = 0; i < 10; i++) {
        final hbArbId = buildArbId(
          apiClass: kApiClassSecondaryHeartbeat,
          apiIndex: kSecondaryHeartbeatIndex,
          deviceId: deviceId,
        );
        final hbPayload = buildSecondaryHeartbeatPayload(deviceId);
        final hbSlcan = encodeSlcanFrame(hbArbId, hbPayload);
        _conn.sendRaw(Uint8List.fromList(hbSlcan.codeUnits));
        await Future.delayed(const Duration(milliseconds: 80));
      }
      buf.writeln('  Sent 10 SLCAN heartbeats');
      // Now send the param read.
      raw = await _captureRaw(sendBytes: readSlcanBytes);
      buf.writeln('  TX arbId: 0x${readArbId.toRadixString(16).padLeft(8, '0')}');
      buf.writeln('  TX bytes: ${_hexLine(readSlcanBytes)}');
      buf.writeln('  TX ASCII: ${_printableAscii(readSlcanBytes)}');
      _analyzeRaw(buf, raw, readSlcanBytes);
    }

    // --- Test 9: SLCAN control commands (V, N, F) ---
    _log('Test 9: SLCAN control commands');
    buf.writeln(_sectionHeader('Test 9: SLCAN Control Commands'));
    buf.writeln('  Sending V (version), N (serial), F (flags) commands');
    buf.writeln('  If device has SLCAN state machine, it will respond');
    {
      // Send V\r  (get hardware/firmware version)
      buf.writeln('\n  --- V (version) ---');
      final vCmd = Uint8List.fromList('V\r'.codeUnits);
      buf.writeln('  TX: ${_hexLine(vCmd)}  ASCII: ${_printableAscii(vCmd)}');
      raw = await _captureRaw(sendBytes: vCmd);
      _analyzeRaw(buf, raw, vCmd);

      // Send N\r  (get serial number)
      buf.writeln('  --- N (serial number) ---');
      final nCmd = Uint8List.fromList('N\r'.codeUnits);
      buf.writeln('  TX: ${_hexLine(nCmd)}  ASCII: ${_printableAscii(nCmd)}');
      raw = await _captureRaw(sendBytes: nCmd);
      _analyzeRaw(buf, raw, nCmd);

      // Send F\r  (get status flags)
      buf.writeln('  --- F (status flags) ---');
      final fCmd = Uint8List.fromList('F\r'.codeUnits);
      buf.writeln('  TX: ${_hexLine(fCmd)}  ASCII: ${_printableAscii(fCmd)}');
      raw = await _captureRaw(sendBytes: fCmd);
      _analyzeRaw(buf, raw, fCmd);
    }

    // --- Test 10: Full SLCAN init → param read ---
    _log('Test 10: SLCAN init then param read');
    buf.writeln(_sectionHeader('Test 10: SLCAN Init (C→S6→O) → Param Read'));
    buf.writeln('  Standard SLCAN init should open the CAN channel');
    buf.writeln('  and enable TX-ACK + response routing');
    {
      // Close CAN
      buf.writeln('\n  --- C (close) ---');
      final cCmd = Uint8List.fromList('C\r'.codeUnits);
      _conn.sendRaw(cCmd);
      raw = await _captureRaw(sendBytes: null);
      buf.writeln('  After C: ${raw.length} bytes');
      _analyzeRaw(buf, raw, null);

      // Set bitrate 500k
      buf.writeln('  --- S6 (500kbps) ---');
      final s6Cmd = Uint8List.fromList('S6\r'.codeUnits);
      _conn.sendRaw(s6Cmd);
      raw = await _captureRaw(sendBytes: null);
      buf.writeln('  After S6: ${raw.length} bytes');
      _analyzeRaw(buf, raw, null);

      // Open CAN
      buf.writeln('  --- O (open) ---');
      final oCmd = Uint8List.fromList('O\r'.codeUnits);
      _conn.sendRaw(oCmd);
      raw = await _captureRaw(sendBytes: null);
      buf.writeln('  After O: ${raw.length} bytes');
      _analyzeRaw(buf, raw, null);

      // Wait a beat, then send param read
      await Future.delayed(const Duration(milliseconds: 100));
      buf.writeln('  --- Param Read after init ---');
      raw = await _captureRaw(sendBytes: readSlcanBytes);
      buf.writeln('  TX arbId: 0x${readArbId.toRadixString(16).padLeft(8, '0')}');
      buf.writeln('  TX ASCII: ${_printableAscii(readSlcanBytes)}');
      _analyzeRaw(buf, raw, readSlcanBytes);
    }

    buf.writeln();
    buf.writeln('═══ End of Raw Byte Diagnostic v5 ═══');

    final report = buf.toString();
    _log('v5 diagnostic complete');
    return V5DiagnosticReport(report);
  }

  /// Send bytes (if any) and capture raw serial data for [_captureWindow].
  Future<List<int>> _captureRaw({Uint8List? sendBytes}) async {
    _conn.rawCaptureEnabled = true;
    _conn.takeRawCapture(); // clear any stale data

    // Small delay to let a few status frames come in before we send.
    await Future.delayed(const Duration(milliseconds: 50));
    _conn.takeRawCapture(); // discard pre-command data

    if (sendBytes != null) {
      _conn.sendRaw(sendBytes);
    }

    await Future.delayed(_captureWindow);
    final raw = _conn.takeRawCapture();
    _conn.rawCaptureEnabled = false;
    return raw;
  }

  /// Analyze raw bytes and write findings to [buf].
  void _analyzeRaw(StringBuffer buf, List<int> raw, Uint8List? txBytes) {
    buf.writeln('  RX bytes: ${raw.length}');

    if (raw.isEmpty) {
      buf.writeln('  ⚠ NO DATA RECEIVED');
      buf.writeln();
      return;
    }

    // Hexdump first 512 bytes (enough to see a few frames).
    buf.writeln('  Raw hex (first ${raw.length.clamp(0, 512)} bytes):');
    _hexDump(buf, raw, maxBytes: 512);

    // Scan for non-SLCAN content.
    // SLCAN frames are: T<8hex><1hex><data hex>\r
    // All bytes should be printable ASCII (0x20-0x7E) plus CR (0x0D) and LF (0x0A).
    final nonAscii = <int>[];
    final nonAsciiPositions = <int>[];
    for (var i = 0; i < raw.length; i++) {
      final b = raw[i];
      if (b != 0x0D && b != 0x0A && (b < 0x20 || b > 0x7E)) {
        nonAscii.add(b);
        nonAsciiPositions.add(i);
      }
    }

    if (nonAscii.isEmpty) {
      buf.writeln('  Analysis: ALL bytes are printable ASCII + CR/LF (pure SLCAN)');
    } else {
      buf.writeln('  Analysis: Found ${nonAscii.length} non-ASCII bytes!');
      buf.writeln('  Non-ASCII positions (first 32):');
      for (var i = 0; i < nonAscii.length && i < 32; i++) {
        final pos = nonAsciiPositions[i];
        final b = nonAscii[i];
        // Show surrounding context (±4 bytes).
        final ctxStart = (pos - 4).clamp(0, raw.length);
        final ctxEnd = (pos + 5).clamp(0, raw.length);
        final ctx = raw.sublist(ctxStart, ctxEnd);
        buf.writeln('    offset $pos: 0x${b.toRadixString(16).padLeft(2, '0')}  '
            'context: ${_hexLine(Uint8List.fromList(ctx))}');
      }
    }

    // Count SLCAN frames.
    final crCount = raw.where((b) => b == 0x0D).length;
    buf.writeln('  CR (0x0D) count: $crCount (≈ $crCount SLCAN frames)');

    // Extract all SLCAN lines and check for non-status apiClasses.
    final lines = _extractSlcanLines(raw);
    final nonStatusLines = <String>[];
    for (final line in lines) {
      if (line.length >= 10 && line[0] == 'T') {
        final arbId = int.tryParse(line.substring(1, 9), radix: 16);
        if (arbId != null) {
          final apiClass = extractApiClass(arbId);
          if (apiClass != 0x2E && apiClass != 0x06 && apiClass != 0x2F) {
            nonStatusLines.add(line);
          }
        }
      } else if (line.isNotEmpty && line[0] != 'T') {
        // Non-T SLCAN line — could be a response echo.
        nonStatusLines.add(line);
      }
    }

    if (nonStatusLines.isNotEmpty) {
      buf.writeln('  ★ NON-STATUS SLCAN lines found: ${nonStatusLines.length}');
      for (final l in nonStatusLines) {
        buf.writeln('    "$l"');
      }
    } else {
      buf.writeln('  All ${lines.length} SLCAN lines are status/broadcast frames');
    }

    buf.writeln();
  }

  List<String> _extractSlcanLines(List<int> raw) {
    final lines = <String>[];
    var start = 0;
    for (var i = 0; i < raw.length; i++) {
      if (raw[i] == 0x0D) {
        final line = String.fromCharCodes(raw.sublist(start, i));
        if (line.isNotEmpty) lines.add(line);
        start = i + 1;
        if (start < raw.length && raw[start] == 0x0A) start++;
      }
    }
    return lines;
  }

  String _sectionHeader(String title) => '\n[$title]';

  String _hexLine(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  String _printableAscii(Uint8List bytes) {
    return String.fromCharCodes(
      bytes.map((b) => (b >= 0x20 && b < 0x7F) ? b : 0x2E), // '.' for non-printable
    );
  }

  void _hexDump(StringBuffer buf, List<int> raw, {int maxBytes = 512}) {
    final len = raw.length.clamp(0, maxBytes);
    for (var offset = 0; offset < len; offset += 16) {
      final end = (offset + 16).clamp(0, len);
      final chunk = raw.sublist(offset, end);
      final hex = chunk.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      final ascii = String.fromCharCodes(
        chunk.map((b) => (b >= 0x20 && b < 0x7F) ? b : 0x2E),
      );
      buf.writeln('    ${offset.toRadixString(16).padLeft(4, '0')}  '
          '${hex.padRight(48)}  $ascii');
    }
    if (raw.length > maxBytes) {
      buf.writeln('    ... (${raw.length - maxBytes} more bytes)');
    }
  }
}
