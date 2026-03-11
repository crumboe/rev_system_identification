/// Firmware 26.x heartbeat manager for keeping SPARK controllers enabled.
///
/// Uses the SECONDARY_HEARTBEAT frame from CANSparkFrames.h:
///   API Class=11 (0x0B), Index=2, 8-byte enabled_sparks_bitfield.
/// Each bit in the 64-bit bitfield enables the SPARK with that CAN device ID.
///
/// Must be sent every ≤100ms (80ms recommended) or the controller will
/// disable its output.
library;

import 'dart:async';

import 'interfaces.dart';
import 'spark_protocol.dart';

/// Manages the FRC heartbeat for a [SparkConnection].
///
/// Usage:
/// ```dart
/// final hb = HeartbeatManager(connection);
/// hb.start();        // begin sending heartbeat (motor enabled)
/// hb.disable();      // stop enabling the motor (sends disabled heartbeat)
/// hb.stop();         // stop sending heartbeat entirely
/// ```
class HeartbeatManager implements IHeartbeatManager {
  final ISparkConnection _connection;

  bool _running = false;
  bool _enabled = false;
  int _deviceId;

  /// The heartbeat period in milliseconds.
  /// HC2 uses 25ms (SECONDARY_HEARTBEAT_INTERVAL from HeartbeatSender).
  static const int periodMs = 25;

  bool get isRunning => _running;
  bool get isEnabled => _enabled;

  /// Update the device ID used in the heartbeat arb ID.
  set deviceId(int id) => _deviceId = id;
  int get deviceId => _deviceId;

  HeartbeatManager(this._connection, {int deviceId = 0})
      : _deviceId = deviceId;

  /// Start sending heartbeats in a timer-based loop.
  ///
  /// Since flutter_libserialport is not isolate-safe (it uses FFI pointers
  /// bound to the main isolate), we use a Timer on the main isolate instead.
  /// For production-critical timing, a native plugin could be used.
  void start({bool enabled = true}) {
    if (_running) {
      _enabled = enabled;
      return;
    }
    _running = true;
    _enabled = enabled;
    _startTimer();
  }

  /// Stop sending heartbeats entirely. The motor will coast/brake to a stop.
  void stop() {
    _running = false;
    _enabled = false;
    _timer?.cancel();
    _timer = null;
  }

  /// Enable the motor (heartbeat keeps being sent with enabled flag).
  void enable() {
    _enabled = true;
  }

  /// Disable the motor but keep sending heartbeat
  /// (motor stops but controller stays connected).
  void disable() {
    _enabled = false;
  }

  /// Send a single heartbeat packet immediately.
  /// Useful for one-shot enable/disable.
  void sendOnce({bool enabled = true}) {
    _sendHeartbeat(enabled: enabled);
  }

  // -----------------------------------------------------------------------
  // Timer-based heartbeat (main isolate)
  // -----------------------------------------------------------------------

  Timer? _timer;
  final _stopwatch = Stopwatch();

  void _startTimer() {
    _stopwatch.start();
    _timer = Timer.periodic(
      const Duration(milliseconds: periodMs),
      (_) => _sendHeartbeat(enabled: _enabled),
    );
  }

  void _sendHeartbeat({required bool enabled}) {
    if (!_connection.isOpen) return;

    // Secondary heartbeat: API Class=11, Index=2, 8-byte bitfield.
    // Each bit enables the SPARK with that CAN device ID.
    //
    // HC2 pattern: always send the heartbeat frame — when disabled, send
    // all-zeros payload (clears device bit). This keeps the controller in
    // a known state rather than relying on heartbeat timeout.
    //
    // IMPORTANT: The arb ID uses deviceId=0 (broadcast), NOT the target
    // device ID. The *payload* bitfield selects which device to enable.
    final arbId = buildArbId(
      apiClass: kApiClassSecondaryHeartbeat,
      apiIndex: kSecondaryHeartbeatIndex,
      deviceId: 0, // broadcast — HC2 confirmed
    );
    final payload = enabled
        ? buildSecondaryHeartbeatPayload(_deviceId)
        : buildSecondaryHeartbeatPayload(-1); // -1 → no bits set → all zeros

    try {
      _connection.sendCommand(arbId, payload);

      // HC2 also sends a REV universal secondary heartbeat (broadcast to
      // all devices regardless of CAN ID). 1-byte payload: 0x01 = enabled.
      _connection.sendCommand(
        kRevUniversalSecondaryHeartbeatId,
        buildUniversalHeartbeatPayload(enabled),
      );
    } catch (_) {
      // Connection may have been lost — caller should detect via
      // SparkConnection.isOpen and handle accordingly.
    }
  }

  /// Dispose of resources.
  void dispose() {
    stop();
    _stopwatch.stop();
  }
}
