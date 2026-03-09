/// CAN Protocol Explorer v4 — comprehensive transport & protocol diagnostic.
///
/// This diagnostic goes beyond the previous versions by:
/// 1. Verifying transport (status frames prove bidirectional CAN works)
/// 2. Testing parameter WRITE (0x0E) to see if responses come back
/// 3. Testing system ID Query (0x02/0x06) which should also produce responses
/// 4. Testing modern parameter READ (0x0F) with full traffic capture
/// 5. Testing legacy parameter READ (0x01) for comparison
/// 6. Capturing ALL traffic after each command — not just the expected response
/// 7. Reporting the connection's protocol mode (binary vs SLCAN)
///
/// This should definitively reveal whether:
/// - Only status frames flow (transport limitation)
/// - All responses flow but param read protocol is wrong
/// - The device needs a different command format for reads
library;

import 'dart:async';
import 'dart:typed_data';

import 'interfaces.dart';
import 'spark_protocol.dart';

/// Result of one diagnostic step.
class V4TestResult {
  final String name;
  final String description;
  final int? txArbId;
  final Uint8List? txPayload;
  final List<SparkResponse> allCapturedFrames;
  final Duration elapsed;
  final String? error;

  V4TestResult({
    required this.name,
    this.description = '',
    this.txArbId,
    this.txPayload,
    this.allCapturedFrames = const [],
    required this.elapsed,
    this.error,
  });

  String get summary {
    final buf = StringBuffer();
    buf.writeln('[$name]');
    if (description.isNotEmpty) buf.writeln('  $description');
    if (txArbId != null) {
      buf.writeln('  TX arbId: 0x${txArbId!.toRadixString(16).padLeft(8, '0')}  '
          'apiClass=0x${extractApiClass(txArbId!).toRadixString(16)} '
          'apiIndex=0x${extractApiIndex(txArbId!).toRadixString(16)} '
          'devId=${extractDeviceId(txArbId!)}');
    }
    if (txPayload != null) {
      buf.writeln('  TX payload: ${_hexDump(txPayload!)}');
    }
    buf.writeln('  Elapsed: ${elapsed.inMilliseconds} ms');
    buf.writeln('  Frames captured: ${allCapturedFrames.length}');

    // Categorize captured frames.
    // apiClass 0x2E = new status, 0x06 = legacy status, 0x2F = periodic broadcast.
    // All three are background traffic — not command responses.
    final statusFrames = <SparkResponse>[];
    final nonStatusFrames = <SparkResponse>[];
    for (final f in allCapturedFrames) {
      if (_isPeriodicFrame(f)) {
        statusFrames.add(f);
      } else {
        nonStatusFrames.add(f);
      }
    }

    if (statusFrames.isNotEmpty) {
      buf.writeln('  Status frames: ${statusFrames.length} '
          '(apiClasses: ${statusFrames.map((f) => '0x${f.apiClass.toRadixString(16)}').toSet().join(', ')})');
    }
    if (nonStatusFrames.isNotEmpty) {
      buf.writeln('  NON-STATUS frames: ${nonStatusFrames.length}');
      for (final f in nonStatusFrames) {
        buf.writeln('    -> arbId=0x${f.arbId.toRadixString(16).padLeft(8, '0')} '
            'type=${f.responseType} '
            'apiClass=0x${f.apiClass.toRadixString(16)} '
            'apiIndex=0x${f.apiIndex.toRadixString(16)} '
            'devId=${f.deviceId} '
            'payload=${_hexDump(f.payload)}');
      }
    }

    if (error != null) {
      buf.writeln('  ERROR: $error');
    } else if (nonStatusFrames.isEmpty) {
      buf.writeln('  RESULT: No non-status response received');
    } else {
      buf.writeln('  RESULT: Got ${nonStatusFrames.length} non-status frame(s)');
    }
    return buf.toString();
  }

  /// Returns true for periodic background frames (status + broadcasts).
  static bool _isPeriodicFrame(SparkResponse f) =>
      f.apiClass == kApiClassNewStatus ||
      f.apiClass == kApiClassStatus ||
      f.apiClass == 0x2F; // periodic broadcast frame

  static String _hexDump(Uint8List data) =>
      data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
}

/// Full diagnostic report.
class V4DiagReport {
  final List<V4TestResult> results;
  final int detectedDeviceId;
  final bool transportVerified;
  final String protocolMode;
  final DateTime timestamp;

  V4DiagReport({
    required this.results,
    required this.detectedDeviceId,
    required this.transportVerified,
    required this.protocolMode,
    required this.timestamp,
  });

  String get fullReport {
    final buf = StringBuffer();
    buf.writeln('╔══════════════════════════════════════════════════════════╗');
    buf.writeln('║     CAN Protocol Explorer v4 — Diagnostic Report       ║');
    buf.writeln('╚══════════════════════════════════════════════════════════╝');
    buf.writeln('Time: $timestamp');
    buf.writeln('Protocol mode: $protocolMode');
    buf.writeln('Transport verified: $transportVerified');
    buf.writeln('Detected device ID: $detectedDeviceId');
    buf.writeln('');

    // Summary table.
    buf.writeln('┌─────────────────────────────────────────────────────────┐');
    buf.writeln('│ Summary                                                 │');
    buf.writeln('├─────────────────────────────────────────────────────────┤');
    for (final r in results) {
      final hasNonPeriodic =
          r.allCapturedFrames.any((f) => !V4TestResult._isPeriodicFrame(f));
      final status = r.error != null
          ? 'ERR'
          : hasNonPeriodic
              ? 'OK '
              : '---';
      buf.writeln('│ [$status] ${r.name.padRight(52)}│');
    }
    buf.writeln('└─────────────────────────────────────────────────────────┘');
    buf.writeln('');

    // Detailed results.
    for (final r in results) {
      buf.writeln(r.summary);
    }

    // Analysis.
    buf.writeln('');
    buf.writeln('═══ Analysis ═══');
    _writeAnalysis(buf);

    return buf.toString();
  }

  void _writeAnalysis(StringBuffer buf) {
    if (!transportVerified) {
      buf.writeln('CRITICAL: Transport not verified — no status frames received.');
      buf.writeln('The device may not be sending data. Check:');
      buf.writeln('  - Is the heartbeat running?');
      buf.writeln('  - Is the COM port correct?');
      buf.writeln('  - Is the device powered?');
      return;
    }

    buf.writeln('Transport OK — status frames confirmed on apiClass=0x2E.');

    // Check which tests got non-status responses.
    final writeResult = results.where((r) => r.name.contains('Param WRITE')).toList();
    final readModernResult = results.where((r) => r.name.contains('Param READ Modern')).toList();
    final readLegacyResult = results.where((r) => r.name.contains('Param READ Legacy')).toList();
    final idQueryResult = results.where((r) => r.name.contains('System ID Query')).toList();

    bool hasNonPeriodic(V4TestResult r) => r.allCapturedFrames.any((f) =>
        !V4TestResult._isPeriodicFrame(f));

    final writeWorks = writeResult.isNotEmpty && hasNonPeriodic(writeResult.first);
    final readModernWorks = readModernResult.isNotEmpty && hasNonPeriodic(readModernResult.first);
    final readLegacyWorks = readLegacyResult.isNotEmpty && hasNonPeriodic(readLegacyResult.first);
    final idQueryWorks = idQueryResult.isNotEmpty && hasNonPeriodic(idQueryResult.first);

    buf.writeln('');
    buf.writeln('Response matrix:');
    buf.writeln('  Parameter WRITE (0x0E):  ${writeWorks ? "RESPONSE" : "no response"}');
    buf.writeln('  Parameter READ modern (0x0F): ${readModernWorks ? "RESPONSE" : "no response"}');
    buf.writeln('  Parameter READ legacy (0x01): ${readLegacyWorks ? "RESPONSE" : "no response"}');
    buf.writeln('  System ID Query (0x02):  ${idQueryWorks ? "RESPONSE" : "no response"}');

    if (writeWorks && !readModernWorks) {
      buf.writeln('');
      buf.writeln('FINDING: Writes get responses but reads do not.');
      buf.writeln('The parameter READ protocol (0x0F) may use a different format.');
      buf.writeln('Check the write response for clues about the response format.');
    } else if (!writeWorks && !readModernWorks && !idQueryWorks) {
      buf.writeln('');
      buf.writeln('FINDING: NO command gets a non-status response over USB.');
      buf.writeln('Possible causes:');
      buf.writeln('  1. The firmware routes command responses to CAN bus only, not USB');
      buf.writeln('  2. Responses use a USB response type that is not being parsed');
      buf.writeln('  3. The binary protocol requires a different USB command type');
      buf.writeln('  4. A firmware configuration or handshake is needed first');
    } else if (idQueryWorks && !readModernWorks) {
      buf.writeln('');
      buf.writeln('FINDING: System commands get responses but parameter reads do not.');
      buf.writeln('The parameter protocol may require a specific mode or format.');
    }
  }
}

/// Runs the v4 CAN protocol explorer diagnostic.
class CanDiagnosticV4 {
  final ISparkConnection _conn;
  final void Function(String) _log;
  final Duration _captureWindow;

  CanDiagnosticV4(
    this._conn, {
    void Function(String)? log,
    Duration captureWindow = const Duration(milliseconds: 1500),
  })  : _log = log ?? _defaultLog,
        _captureWindow = captureWindow;

  static void _defaultLog(String msg) {
    // ignore: avoid_print
    print(msg);
  }

  /// Run the full protocol explorer diagnostic.
  ///
  /// [deviceId] is the target CAN device ID.
  /// [protocolModeHint] is a string describing the detected protocol mode
  /// (e.g. "binary" or "SLCAN") — pass this from SparkConnection state.
  Future<V4DiagReport> run({
    int deviceId = 0,
    String protocolModeHint = 'unknown',
  }) async {
    final results = <V4TestResult>[];
    _log('╔══════════════════════════════════════════════════╗');
    _log('║     CAN Protocol Explorer v4                    ║');
    _log('╚══════════════════════════════════════════════════╝');
    _log('Protocol mode hint: $protocolModeHint');
    _log('Target deviceId: $deviceId');
    _log('');

    // ── Phase 1: Transport Verification ──────────────────────────────
    _log('Phase 1: Verifying transport (listening 3s for status frames)...');
    final phase1 = await _captureAllFrames(
      name: 'Transport Verification',
      description: 'Listen for 3 seconds — expect status frames on apiClass=0x2E',
      duration: const Duration(seconds: 3),
    );
    results.add(phase1);

    final statusFrames = phase1.allCapturedFrames
        .where((f) => f.apiClass == kApiClassNewStatus || f.apiClass == kApiClassStatus)
        .toList();
    final transportOk = statusFrames.isNotEmpty;

    // Detect device ID from status frames if not provided.
    int detectedId = deviceId;
    if (deviceId == 0 && statusFrames.isNotEmpty) {
      detectedId = statusFrames.first.deviceId;
      _log('  Detected device ID from status: $detectedId');
    }
    _log('  Transport ${transportOk ? "OK" : "FAILED"} — '
        '${statusFrames.length} status frames, '
        '${phase1.allCapturedFrames.length - statusFrames.length} other frames');
    _log('');

    // Log all unique apiClasses seen.
    final apiClasses = <int>{};
    for (final f in phase1.allCapturedFrames) {
      apiClasses.add(f.apiClass);
    }
    _log('  API classes seen: ${apiClasses.map((c) => '0x${c.toRadixString(16)}').join(', ')}');
    _log('');

    // ── Phase 2: System ID Query ─────────────────────────────────────
    _log('Phase 2: System ID Query (apiClass=0x02, apiIndex=0x06)...');
    results.add(await _sendAndCaptureAll(
      name: 'System ID Query (devId=$detectedId)',
      description: 'System command that should produce a response with the CAN ID',
      arbId: buildArbId(
        apiClass: kApiClassSystem,
        apiIndex: kSystemIndexIdQuery,
        deviceId: detectedId,
      ),
      payload: Uint8List(0),
    ));

    // Also try with deviceId=0 (USB convention).
    _log('Phase 2b: System ID Query with devId=0...');
    results.add(await _sendAndCaptureAll(
      name: 'System ID Query (devId=0)',
      description: 'Same command but addressed to device 0 (USB convention)',
      arbId: buildArbId(
        apiClass: kApiClassSystem,
        apiIndex: kSystemIndexIdQuery,
        deviceId: 0,
      ),
      payload: Uint8List(0),
    ));

    // ── Phase 3: Parameter WRITE test ────────────────────────────────
    // Write idle mode = 1 (brake) which is a safe default.
    _log('Phase 3: Parameter WRITE test (apiClass=0x0E, idleMode=1)...');
    {
      final writeArbId = buildArbId(
        apiClass: kApiClassParameterWrite,
        apiIndex: kParamWriteIndexRequest,
        deviceId: detectedId,
      );
      final writePayload = Uint8List(8);
      writePayload[0] = kParamIdleMode; // paramId = 6
      // Value = 1 (brake), as uint32 LE at offset 1.
      ByteData.sublistView(writePayload).setUint32(1, 1, Endian.little);

      results.add(await _sendAndCaptureAll(
        name: 'Param WRITE (0x0E) idleMode=brake devId=$detectedId',
        description: 'Modern write protocol. Expect response on apiClass=0x0E, apiIndex=0x01',
        arbId: writeArbId,
        payload: writePayload,
      ));
    }

    // Also try write with deviceId=0.
    _log('Phase 3b: Parameter WRITE with devId=0...');
    {
      final writeArbId = buildArbId(
        apiClass: kApiClassParameterWrite,
        apiIndex: kParamWriteIndexRequest,
        deviceId: 0,
      );
      final writePayload = Uint8List(8);
      writePayload[0] = kParamIdleMode;
      ByteData.sublistView(writePayload).setUint32(1, 1, Endian.little);

      results.add(await _sendAndCaptureAll(
        name: 'Param WRITE (0x0E) idleMode=brake devId=0',
        description: 'Same write but addressed to device 0',
        arbId: writeArbId,
        payload: writePayload,
      ));
    }

    // ── Phase 4: Modern Parameter READ ───────────────────────────────
    _log('Phase 4: Modern Parameter READ (apiClass=0x0F, paramId=0)...');
    {
      final readArbId = buildArbId(
        apiClass: kApiClassParameterRead,
        apiIndex: kParamReadIndexRequest,
        deviceId: detectedId,
      );
      final readPayload = Uint8List(8);
      readPayload[0] = kParamCanId; // paramId = 0

      results.add(await _sendAndCaptureAll(
        name: 'Param READ Modern (0x0F) paramId=0 devId=$detectedId',
        description: 'Modern read. Expect response on apiClass=0x0F, apiIndex=0x01',
        arbId: readArbId,
        payload: readPayload,
      ));
    }

    // Try with deviceId=0.
    _log('Phase 4b: Modern Parameter READ with devId=0...');
    {
      final readArbId = buildArbId(
        apiClass: kApiClassParameterRead,
        apiIndex: kParamReadIndexRequest,
        deviceId: 0,
      );
      final readPayload = Uint8List(8);
      readPayload[0] = kParamCanId;

      results.add(await _sendAndCaptureAll(
        name: 'Param READ Modern (0x0F) paramId=0 devId=0',
        description: 'Same read but addressed to device 0',
        arbId: readArbId,
        payload: readPayload,
      ));
    }

    // Try with different paramId (Motor Type = 2).
    _log('Phase 4c: Modern Parameter READ paramId=2 (Motor Type)...');
    {
      final readArbId = buildArbId(
        apiClass: kApiClassParameterRead,
        apiIndex: kParamReadIndexRequest,
        deviceId: detectedId,
      );
      final readPayload = Uint8List(8);
      readPayload[0] = kParamMotorType; // paramId = 2

      results.add(await _sendAndCaptureAll(
        name: 'Param READ Modern (0x0F) paramId=2 devId=$detectedId',
        description: 'Read Motor Type parameter',
        arbId: readArbId,
        payload: readPayload,
      ));
    }

    // ── Phase 5: Legacy Parameter READ ───────────────────────────────
    _log('Phase 5: Legacy Parameter READ (apiClass=0x01, apiIndex=0x01)...');
    {
      final readArbId = buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: detectedId,
      );
      final readPayload = Uint8List(8);
      ByteData.sublistView(readPayload).setUint16(0, kParamCanId, Endian.little);

      results.add(await _sendAndCaptureAll(
        name: 'Param READ Legacy (0x01) paramId=0 devId=$detectedId',
        description: 'Legacy read. Expect response on apiClass=0x01, apiIndex=0x01',
        arbId: readArbId,
        payload: readPayload,
      ));
    }

    // ── Phase 6: Alternative approaches ──────────────────────────────
    // Try using different USB command types in binary mode.
    _log('Phase 6: Binary packet with USB cmd type 1...');
    {
      final arbId = buildArbId(
        apiClass: kApiClassParameterRead,
        apiIndex: kParamReadIndexRequest,
        deviceId: detectedId,
      );
      final payload = Uint8List(8);
      payload[0] = kParamCanId;

      // Build binary packet with USB command type 1 instead of 0.
      final packet = encodePacket(arbId, payload, usbCmdType: 1);
      results.add(await _sendRawAndCaptureAll(
        name: 'Param READ (0x0F) USB cmdType=1',
        description: 'Same read but with USB command type 1 instead of 0',
        rawPacket: packet,
        arbId: arbId,
        payload: payload,
      ));
    }

    // ── Phase 7: Identify (baseline) ─────────────────────────────────
    _log('Phase 7: Identify command (known working baseline)...');
    results.add(await _sendAndCaptureAll(
      name: 'Identify (apiClass=0x07, apiIndex=0x07)',
      description: 'Fire-and-forget identify. Should blink LED, may or may not produce response',
      arbId: buildArbId(
        apiClass: kApiClassFrameRate,
        apiIndex: 0x07,
        deviceId: detectedId,
      ),
      payload: Uint8List(0),
    ));

    // ── Phase 8: Full traffic dump ───────────────────────────────────
    _log('Phase 8: Full traffic capture for 5 seconds (passive)...');
    results.add(await _captureAllFrames(
      name: 'Full Traffic Capture (5s passive)',
      description: 'No commands sent — just capturing all background traffic',
      duration: const Duration(seconds: 5),
    ));

    _log('');
    _log('Diagnostic complete.');

    final report = V4DiagReport(
      results: results,
      detectedDeviceId: detectedId,
      transportVerified: transportOk,
      protocolMode: protocolModeHint,
      timestamp: DateTime.now(),
    );

    _log('');
    _log(report.fullReport);

    return report;
  }

  /// Send a command and capture ALL frames for [_captureWindow] afterwards.
  Future<V4TestResult> _sendAndCaptureAll({
    required String name,
    required String description,
    required int arbId,
    required Uint8List payload,
  }) async {
    _log('  Sending: $name');
    final frames = <SparkResponse>[];
    final sw = Stopwatch()..start();

    // Subscribe to ALL responses.
    final sub = _conn.responses.listen((r) {
      frames.add(r);
    });

    try {
      _conn.sendCommand(arbId, payload);
      await Future.delayed(_captureWindow);
      sw.stop();

      final nonPeriodic = frames.where((f) =>
          !V4TestResult._isPeriodicFrame(f)).length;
      _log('  -> Captured ${frames.length} frames ($nonPeriodic non-periodic) '
          'in ${sw.elapsedMilliseconds} ms');

      return V4TestResult(
        name: name,
        description: description,
        txArbId: arbId,
        txPayload: payload,
        allCapturedFrames: List.unmodifiable(frames),
        elapsed: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      _log('  -> ERROR: $e');
      return V4TestResult(
        name: name,
        description: description,
        txArbId: arbId,
        txPayload: payload,
        allCapturedFrames: List.unmodifiable(frames),
        elapsed: sw.elapsed,
        error: e.toString(),
      );
    } finally {
      await sub.cancel();
    }
  }

  /// Send a raw 12-byte packet (for testing different USB command types)
  /// and capture ALL frames for [_captureWindow].
  Future<V4TestResult> _sendRawAndCaptureAll({
    required String name,
    required String description,
    required Uint8List rawPacket,
    required int arbId,
    required Uint8List payload,
  }) async {
    _log('  Sending raw: $name');
    final frames = <SparkResponse>[];
    final sw = Stopwatch()..start();

    final sub = _conn.responses.listen((r) {
      frames.add(r);
    });

    try {
      _conn.sendRaw(rawPacket);
      await Future.delayed(_captureWindow);
      sw.stop();

      final nonPeriodic = frames.where((f) =>
          !V4TestResult._isPeriodicFrame(f)).length;
      _log('  -> Captured ${frames.length} frames ($nonPeriodic non-periodic) '
          'in ${sw.elapsedMilliseconds} ms');

      return V4TestResult(
        name: name,
        description: description,
        txArbId: arbId,
        txPayload: payload,
        allCapturedFrames: List.unmodifiable(frames),
        elapsed: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      _log('  -> ERROR: $e');
      return V4TestResult(
        name: name,
        description: description,
        txArbId: arbId,
        txPayload: payload,
        allCapturedFrames: List.unmodifiable(frames),
        elapsed: sw.elapsed,
        error: e.toString(),
      );
    } finally {
      await sub.cancel();
    }
  }

  /// Passively capture ALL frames for a duration (no command sent).
  Future<V4TestResult> _captureAllFrames({
    required String name,
    required String description,
    required Duration duration,
  }) async {
    final frames = <SparkResponse>[];
    final sw = Stopwatch()..start();

    final sub = _conn.responses.listen((r) {
      frames.add(r);
    });

    await Future.delayed(duration);
    sw.stop();
    await sub.cancel();

    _log('  -> Captured ${frames.length} frames in ${sw.elapsedMilliseconds} ms');

    return V4TestResult(
      name: name,
      description: description,
      allCapturedFrames: List.unmodifiable(frames),
      elapsed: sw.elapsed,
    );
  }
}
