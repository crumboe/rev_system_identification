/// Manual jog controller for slowly moving a mechanism.
///
/// Provides a hold-to-jog interface: the motor runs only while [startJog]
/// has been called and [stopJog] has not.  A dead-man's-switch auto-timeout
/// stops the motor after [maxJogDuration] even if the caller fails to call
/// [stopJog].
library;

import 'dart:async';

import '../devices/device_manager.dart';

/// Controls low-voltage jog operations on a SPARK device.
class JogController {
  final SparkDevice device;

  /// Maximum allowed jog voltage (V).  User-selected jog voltage is clamped
  /// to ±[maxJogVoltage].
  final double maxJogVoltage;

  /// Safety timeout — jog automatically stops after this duration.
  final Duration maxJogDuration;

  Timer? _jogTimer;
  Timer? _timeoutTimer;
  double _currentVoltage = 0.0;
  bool _isJogging = false;

  bool get isJogging => _isJogging;
  double get currentVoltage => _currentVoltage;

  JogController({
    required this.device,
    this.maxJogVoltage = 3.0,
    this.maxJogDuration = const Duration(seconds: 5),
  });

  /// Begin jogging at [voltage] volts.
  ///
  /// The voltage is clamped to ±[maxJogVoltage].  The motor will be
  /// commanded at this voltage every 20ms until [stopJog] is called or
  /// [maxJogDuration] is exceeded.
  void startJog(double voltage) {
    if (!device.isConnected) return;

    _currentVoltage = voltage.clamp(-maxJogVoltage, maxJogVoltage);
    _isJogging = true;

    // Enable heartbeat so the controller accepts commands.
    device.heartbeat.start(enabled: true);

    // Send voltage every 20ms (keeps the watchdog alive and updates
    // the setpoint).
    _jogTimer?.cancel();
    _jogTimer = Timer.periodic(
      const Duration(milliseconds: 20),
      (_) {
        if (!device.isConnected) {
          stopJog();
          return;
        }
        device.control.setVoltage(_currentVoltage);
      },
    );

    // Dead-man's-switch: auto-stop after maxJogDuration.
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(maxJogDuration, () => stopJog());
  }

  /// Stop jogging — zero the motor and disable heartbeat.
  void stopJog() {
    _jogTimer?.cancel();
    _jogTimer = null;
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    _currentVoltage = 0.0;
    _isJogging = false;

    if (device.isConnected) {
      try {
        device.control.stop();
        device.heartbeat.disable();
      } catch (_) {}
    }
  }

  /// Clean up timers.
  void dispose() {
    stopJog();
  }
}
