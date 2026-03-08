/// FRC Heartbeat manager for keeping SPARK controllers enabled.
///
/// The heartbeat must be sent every 20 ms or the controller will disable
/// its output within ~100 ms.  This implementation runs a periodic timer
/// on a separate Dart isolate for reliable timing.
library;

import 'dart:async';

import 'interfaces.dart';
import 'spark_protocol.dart';
import 'spark_connection.dart';

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

  /// The heartbeat period in milliseconds.
  static const int periodMs = 20;

  bool get isRunning => _running;
  bool get isEnabled => _enabled;

  HeartbeatManager(this._connection);

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

    final timestampMs = _stopwatch.elapsedMilliseconds;
    final modeFlags = kHeartbeatFlagWatchdog | (enabled ? kHeartbeatFlagEnabled : 0);

    final payload = buildHeartbeatPayload(timestampMs, modeFlags: modeFlags);
    final packet = encodePacket(kHeartbeatArbId, payload);

    try {
      _connection.sendRaw(packet);
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
