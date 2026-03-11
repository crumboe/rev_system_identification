/// CAN protocol diagnostic tool for SPARK MAX/Flex controllers.
///
/// Sends a series of test commands using different API class/index
/// combinations and reports which ones receive responses.  This helps
/// identify protocol mismatches between the app and firmware.
library;

import 'dart:async';
import 'dart:typed_data';

import 'interfaces.dart';
import 'spark_protocol.dart';

/// Result of a single diagnostic test.
class DiagTestResult {
  final String name;
  final int txArbId;
  final Uint8List txPayload;
  final SparkResponse? response;
  final Duration elapsed;
  final String? error;

  DiagTestResult({
    required this.name,
    required this.txArbId,
    required this.txPayload,
    this.response,
    required this.elapsed,
    this.error,
  });

  bool get success => response != null && error == null;

  String get txArbHex => '0x${txArbId.toRadixString(16).padLeft(8, '0')}';
  String get txPayloadHex =>
      txPayload.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  String get summary {
    final buf = StringBuffer();
    buf.writeln('[$name]');
    buf.writeln('  TX arbId: $txArbHex  '
        'apiClass=0x${extractApiClass(txArbId).toRadixString(16)} '
        'apiIndex=0x${extractApiIndex(txArbId).toRadixString(16)} '
        'devId=${extractDeviceId(txArbId)}');
    buf.writeln('  TX payload: $txPayloadHex');
    buf.writeln('  Elapsed: ${elapsed.inMilliseconds} ms');
    if (response != null) {
      final r = response!;
      buf.writeln('  RESPONSE: type=${r.responseType} '
          'arbId=0x${r.arbId.toRadixString(16).padLeft(8, '0')} '
          'apiClass=0x${r.apiClass.toRadixString(16)} '
          'apiIndex=0x${r.apiIndex.toRadixString(16)} '
          'devId=${r.deviceId}');
      buf.writeln('  RX payload: '
          '${r.payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      buf.writeln('  STATUS: OK');
    } else if (error != null) {
      buf.writeln('  STATUS: FAILED — $error');
    } else {
      buf.writeln('  STATUS: NO RESPONSE');
    }
    return buf.toString();
  }
}

/// Full diagnostic report.
class DiagReport {
  final List<DiagTestResult> results;
  final List<SparkResponse> backgroundFrames;
  final DateTime timestamp;

  DiagReport({
    required this.results,
    required this.backgroundFrames,
    required this.timestamp,
  });

  String get fullReport {
    final buf = StringBuffer();
    buf.writeln('=== CAN Protocol Diagnostic Report ===');
    buf.writeln('Time: $timestamp');
    buf.writeln('');

    // Summary table
    buf.writeln('--- Summary ---');
    for (final r in results) {
      final status = r.success ? 'OK' : 'FAIL';
      buf.writeln('  [$status] ${r.name} (${r.elapsed.inMilliseconds} ms)');
    }
    buf.writeln('');

    // Background frames captured
    buf.writeln('--- Background frames captured: ${backgroundFrames.length} ---');
    for (final f in backgroundFrames) {
      buf.writeln('  arbId=0x${f.arbId.toRadixString(16).padLeft(8, '0')} '
          'apiClass=0x${f.apiClass.toRadixString(16)} '
          'apiIndex=0x${f.apiIndex.toRadixString(16)} '
          'devId=${f.deviceId} '
          'payload=${f.payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
    }
    buf.writeln('');

    // Detailed results
    buf.writeln('--- Detailed Results ---');
    for (final r in results) {
      buf.writeln(r.summary);
    }

    return buf.toString();
  }
}

/// Runs CAN protocol diagnostics against a connected SPARK controller.
class CanDiagnostic {
  final ISparkConnection _conn;
  final void Function(String) _log;

  /// Timeout for waiting on a response to each test command.
  final Duration _timeout;

  CanDiagnostic(
    this._conn, {
    void Function(String)? log,
    Duration timeout = const Duration(milliseconds: 750),
  })  : _log = log ?? _defaultLog,
        _timeout = timeout;

  static void _defaultLog(String msg) {
    // ignore: avoid_print
    print(msg);
  }

  /// Run the full diagnostic suite.
  ///
  /// [deviceId] is the target CAN device ID (0 = broadcast/USB default).
  /// If unknown, the diagnostic will first try to detect it from status
  /// frames.
  Future<DiagReport> run({int deviceId = 0}) async {
    final results = <DiagTestResult>[];
    final bgFrames = <SparkResponse>[];

    // Collect all background frames during the diagnostic.
    final bgSub = _conn.responses.listen((r) {
      bgFrames.add(r);
    });

    _log('Starting CAN diagnostic (target deviceId=$deviceId)...');
    _log('');

    // If deviceId is 0, try to detect from incoming status frames.
    int detectedId = deviceId;
    if (deviceId == 0) {
      _log('Attempting to detect device ID from status frames...');
      try {
        final statusFrame = await _conn.responses
            .where((r) =>
                r.apiClass == kApiClassNewStatus ||
                r.apiClass == kApiClassStatus)
            .first
            .timeout(const Duration(milliseconds: 500));
        detectedId = statusFrame.deviceId;
        _log('Detected device ID: $detectedId');
      } catch (_) {
        _log('Could not detect device ID from status frames, using 0');
      }
      _log('');
    }

    // --- Test 1: Identify (legacy) — System API, known working baseline ---
    results.add(await _testFireAndForget(
      name: 'Identify (legacy: apiClass=0x02, apiIndex=0x00)',
      arbId: buildArbId(
        apiClass: kApiClassSystem,
        apiIndex: kSystemIndexIdentify,
        deviceId: detectedId,
      ),
      payload: Uint8List(0),
    ));

    // --- Test 2: Identify (modern) — FrameRate API class 0x07, index 0x07 ---
    results.add(await _testFireAndForget(
      name: 'Identify (modern: apiClass=0x07, apiIndex=0x07)',
      arbId: buildArbId(
        apiClass: kApiClassFrameRate,
        apiIndex: 0x07,
        deviceId: detectedId,
      ),
      payload: Uint8List(0),
    ));

    // --- Test 3: Legacy Parameter Read (apiClass=0x01, apiIndex=0x01) ---
    // This is what getParameter() currently uses.
    results.add(await _testRequestResponse(
      name: 'Param Read LEGACY (apiClass=0x01, apiIndex=0x01) paramId=0 (CAN ID)',
      txArbId: buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: detectedId,
      ),
      txPayload: _buildLegacyParamGetPayload(kParamCanId),
      expectApiClass: kApiClassParameter,
      expectApiIndex: kParamIndexGet,
    ));

    // --- Test 4: Modern Parameter Read (apiClass=0x0F, apiIndex=0x00) ---
    // Request at index 0, response expected at index 1.
    results.add(await _testRequestResponse(
      name: 'Param Read MODERN (apiClass=0x0F, apiIndex=0x00) paramId=0 (CAN ID)',
      txArbId: buildArbId(
        apiClass: kApiClassParameterRead,
        apiIndex: kParamReadIndexRequest,
        deviceId: detectedId,
      ),
      txPayload: _buildModernParamReadPayload(kParamCanId),
      expectApiClass: kApiClassParameterRead,
      expectApiIndex: kParamReadIndexResponse,
    ));

    // --- Test 5: Legacy Param Read with device ID 0 ---
    results.add(await _testRequestResponse(
      name: 'Param Read LEGACY devId=0 (apiClass=0x01, apiIndex=0x01) paramId=0',
      txArbId: buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: 0,
      ),
      txPayload: _buildLegacyParamGetPayload(kParamCanId),
      expectApiClass: kApiClassParameter,
      expectApiIndex: kParamIndexGet,
    ));

    // --- Test 6: Modern Param Read with device ID 0 ---
    results.add(await _testRequestResponse(
      name: 'Param Read MODERN devId=0 (apiClass=0x0F, apiIndex=0x00) paramId=0',
      txArbId: buildArbId(
        apiClass: kApiClassParameterRead,
        apiIndex: kParamReadIndexRequest,
        deviceId: 0,
      ),
      txPayload: _buildModernParamReadPayload(kParamCanId),
      expectApiClass: kApiClassParameterRead,
      expectApiIndex: kParamReadIndexResponse,
    ));

    // --- Test 7: Modern Param Read for Motor Type (paramId=2) ---
    results.add(await _testRequestResponse(
      name: 'Param Read MODERN devId=$detectedId paramId=2 (Motor Type)',
      txArbId: buildArbId(
        apiClass: kApiClassParameterRead,
        apiIndex: kParamReadIndexRequest,
        deviceId: detectedId,
      ),
      txPayload: _buildModernParamReadPayload(kParamMotorType),
      expectApiClass: kApiClassParameterRead,
      expectApiIndex: kParamReadIndexResponse,
    ));

    // --- Test 8: Modern Param Read for IdleMode (paramId=6) ---
    results.add(await _testRequestResponse(
      name: 'Param Read MODERN devId=$detectedId paramId=6 (Idle Mode)',
      txArbId: buildArbId(
        apiClass: kApiClassParameterRead,
        apiIndex: kParamReadIndexRequest,
        deviceId: detectedId,
      ),
      txPayload: _buildModernParamReadPayload(kParamIdleMode),
      expectApiClass: kApiClassParameterRead,
      expectApiIndex: kParamReadIndexResponse,
    ));

    // --- Test 9: Legacy Parameter Read with full 8-byte zero-padded payload ---
    results.add(await _testRequestResponse(
      name: 'Param Read LEGACY 8-byte padded (apiClass=0x01, apiIndex=0x01) paramId=0',
      txArbId: buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: detectedId,
      ),
      txPayload: buildParamReadPayload(kParamCanId),
      expectApiClass: kApiClassParameter,
      expectApiIndex: kParamIndexGet,
    ));

    // --- Test 10: Modern Param Read, listen for ANY response ---
    // This catches the case where the response comes on an unexpected
    // API class/index.
    results.add(await _testAnyResponse(
      name: 'Param Read MODERN + listen for ANY response from device',
      txArbId: buildArbId(
        apiClass: kApiClassParameterRead,
        apiIndex: kParamReadIndexRequest,
        deviceId: detectedId,
      ),
      txPayload: _buildModernParamReadPayload(kParamCanId),
      deviceId: detectedId,
    ));

    // --- Test 11: Legacy Param Read, listen for ANY response ---
    results.add(await _testAnyResponse(
      name: 'Param Read LEGACY + listen for ANY response from device',
      txArbId: buildArbId(
        apiClass: kApiClassParameter,
        apiIndex: kParamIndexGet,
        deviceId: detectedId,
      ),
      txPayload: _buildLegacyParamGetPayload(kParamCanId),
      deviceId: detectedId,
    ));

    await bgSub.cancel();

    final report = DiagReport(
      results: results,
      backgroundFrames: bgFrames,
      timestamp: DateTime.now(),
    );

    _log('');
    _log(report.fullReport);

    return report;
  }

  // -----------------------------------------------------------------------
  // Test helpers
  // -----------------------------------------------------------------------

  /// Send a fire-and-forget command (no response expected, e.g. identify).
  Future<DiagTestResult> _testFireAndForget({
    required String name,
    required int arbId,
    required Uint8List payload,
  }) async {
    _log('Testing: $name');
    final sw = Stopwatch()..start();

    try {
      _conn.sendCommand(arbId, payload);
      // Give a brief window to see if any response arrives.
      SparkResponse? resp;
      try {
        resp = await _conn.responses
            .where((r) =>
                r.apiClass != kApiClassNewStatus &&
                r.apiClass != kApiClassStatus)
            .first
            .timeout(const Duration(milliseconds: 300));
      } catch (_) {
        // No non-status response expected for fire-and-forget.
      }
      sw.stop();
      _log('  -> Sent OK (${sw.elapsedMilliseconds} ms)${resp != null ? ' — got unexpected response!' : ''}');
      return DiagTestResult(
        name: name,
        txArbId: arbId,
        txPayload: payload,
        response: resp,
        elapsed: sw.elapsed,
      );
    } catch (e) {
      sw.stop();
      _log('  -> ERROR: $e');
      return DiagTestResult(
        name: name,
        txArbId: arbId,
        txPayload: payload,
        elapsed: sw.elapsed,
        error: e.toString(),
      );
    }
  }

  /// Send a request and wait for a response matching the expected
  /// API class and index.
  Future<DiagTestResult> _testRequestResponse({
    required String name,
    required int txArbId,
    required Uint8List txPayload,
    required int expectApiClass,
    required int expectApiIndex,
  }) async {
    _log('Testing: $name');
    final sw = Stopwatch()..start();

    try {
      _conn.sendCommand(txArbId, txPayload);

      final expectedArb = buildArbId(
        apiClass: expectApiClass,
        apiIndex: expectApiIndex,
      );
      const matchMask = 0x1FFFFFC0;

      final response = await _conn.responses
          .where((r) => (r.arbId & matchMask) == (expectedArb & matchMask))
          .first
          .timeout(_timeout);
      sw.stop();

      _log('  -> RESPONSE in ${sw.elapsedMilliseconds} ms: '
          'arbId=0x${response.arbId.toRadixString(16).padLeft(8, '0')} '
          'payload=${response.payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');

      return DiagTestResult(
        name: name,
        txArbId: txArbId,
        txPayload: txPayload,
        response: response,
        elapsed: sw.elapsed,
      );
    } on TimeoutException {
      sw.stop();
      _log('  -> TIMEOUT after ${sw.elapsedMilliseconds} ms');
      return DiagTestResult(
        name: name,
        txArbId: txArbId,
        txPayload: txPayload,
        elapsed: sw.elapsed,
        error: 'Timeout (no response in ${_timeout.inMilliseconds} ms)',
      );
    } catch (e) {
      sw.stop();
      _log('  -> ERROR: $e');
      return DiagTestResult(
        name: name,
        txArbId: txArbId,
        txPayload: txPayload,
        elapsed: sw.elapsed,
        error: e.toString(),
      );
    }
  }

  /// Send a request and listen for ANY non-status response from the device
  /// (regardless of API class/index).
  Future<DiagTestResult> _testAnyResponse({
    required String name,
    required int txArbId,
    required Uint8List txPayload,
    required int deviceId,
  }) async {
    _log('Testing: $name');
    final sw = Stopwatch()..start();

    try {
      _conn.sendCommand(txArbId, txPayload);

      // Listen for any frame that is NOT a periodic status frame.
      final response = await _conn.responses
          .where((r) =>
              r.apiClass != kApiClassNewStatus &&
              r.apiClass != kApiClassStatus)
          .first
          .timeout(_timeout);
      sw.stop();

      _log('  -> GOT RESPONSE in ${sw.elapsedMilliseconds} ms: '
          'arbId=0x${response.arbId.toRadixString(16).padLeft(8, '0')} '
          'apiClass=0x${response.apiClass.toRadixString(16)} '
          'apiIndex=0x${response.apiIndex.toRadixString(16)} '
          'payload=${response.payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');

      return DiagTestResult(
        name: name,
        txArbId: txArbId,
        txPayload: txPayload,
        response: response,
        elapsed: sw.elapsed,
      );
    } on TimeoutException {
      sw.stop();
      _log('  -> TIMEOUT (no non-status response in ${_timeout.inMilliseconds} ms)');
      return DiagTestResult(
        name: name,
        txArbId: txArbId,
        txPayload: txPayload,
        elapsed: sw.elapsed,
        error: 'Timeout (no non-status response)',
      );
    } catch (e) {
      sw.stop();
      _log('  -> ERROR: $e');
      return DiagTestResult(
        name: name,
        txArbId: txArbId,
        txPayload: txPayload,
        elapsed: sw.elapsed,
        error: e.toString(),
      );
    }
  }

  // -----------------------------------------------------------------------
  // Payload builders
  // -----------------------------------------------------------------------

  /// Legacy param get: uint16 paramId at offset 0 (2 bytes).
  Uint8List _buildLegacyParamGetPayload(int paramId) {
    final payload = Uint8List(8);
    ByteData.sublistView(payload).setUint16(0, paramId, Endian.little);
    return payload;
  }

  /// Modern param read: byte 0 = paramId (1 byte).
  Uint8List _buildModernParamReadPayload(int paramId) {
    final payload = Uint8List(8);
    payload[0] = paramId & 0xFF;
    return payload;
  }
}
