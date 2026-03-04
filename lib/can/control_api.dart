/// High-level API for sending control commands and system commands to
/// SPARK MAX/Flex controllers.
library;

import 'dart:typed_data';

import 'interfaces.dart';
import 'spark_protocol.dart';

/// Provides typed methods for motor control and system commands.
class ControlApi implements IControlApi {
  final ISparkConnection _conn;
  final int _deviceId;

  ControlApi(this._conn, {int deviceId = 0}) : _deviceId = deviceId;

  // -----------------------------------------------------------------------
  // Setpoint commands (API Class 0x00, Index 0x00)
  // -----------------------------------------------------------------------

  /// Send a setpoint command to the controller.
  void setSetpoint(
    double value,
    int controlType, {
    int pidSlot = 0,
  }) {
    final arbId = buildArbId(
      apiClass: kApiClassControl,
      apiIndex: kControlIndexSetpoint,
      deviceId: _deviceId,
    );
    final payload = buildSetpointPayload(value, controlType, pidSlot: pidSlot);
    _conn.sendCommand(arbId, payload);
  }

  /// Set duty cycle output (−1.0 to +1.0).
  void setDutyCycle(double dutyCycle) =>
      setSetpoint(dutyCycle, kControlTypeDutyCycle);

  /// Set velocity setpoint in RPM (closed-loop).
  void setVelocity(double rpm, {int pidSlot = 0}) =>
      setSetpoint(rpm, kControlTypeVelocity, pidSlot: pidSlot);

  /// Set voltage output in volts (open-loop, bus-compensated).
  ///
  /// This is the preferred mode for system identification tests.
  void setVoltage(double volts) =>
      setSetpoint(volts, kControlTypeVoltage);

  /// Set position setpoint in rotations (closed-loop).
  void setPosition(double rotations, {int pidSlot = 0}) =>
      setSetpoint(rotations, kControlTypePosition, pidSlot: pidSlot);

  /// Set SmartMotion setpoint in rotations (profiled closed-loop).
  void setSmartMotion(double rotations, {int pidSlot = 0}) =>
      setSetpoint(rotations, kControlTypeSmartMotion, pidSlot: pidSlot);

  /// Set current setpoint in amps (closed-loop).
  void setCurrent(double amps, {int pidSlot = 0}) =>
      setSetpoint(amps, kControlTypeCurrent, pidSlot: pidSlot);

  /// Send zero voltage (stop the motor).
  void stop() => setVoltage(0.0);

  // -----------------------------------------------------------------------
  // System commands (API Class 0x02)
  // -----------------------------------------------------------------------

  /// Blink the controller's LED for identification.
  Future<SparkResponse> identify() {
    final arbId = buildArbId(
      apiClass: kApiClassSystem,
      apiIndex: kSystemIndexIdentify,
      deviceId: _deviceId,
    );
    return _conn.sendAndReceive(arbId, Uint8List(8));
  }

  /// Clear all active faults.
  Future<SparkResponse> clearFaults() {
    final arbId = buildArbId(
      apiClass: kApiClassSystem,
      apiIndex: kSystemIndexClearFaults,
      deviceId: _deviceId,
    );
    return _conn.sendAndReceive(arbId, Uint8List(8));
  }

  /// Factory reset the controller to default settings.
  Future<SparkResponse> factoryReset() {
    final arbId = buildArbId(
      apiClass: kApiClassSystem,
      apiIndex: kSystemIndexFactoryReset,
      deviceId: _deviceId,
    );
    return _conn.sendAndReceive(
      arbId,
      Uint8List(8),
      timeout: const Duration(seconds: 5),
    );
  }

  // -----------------------------------------------------------------------
  // Frame rate commands (API Class 0x07)
  // -----------------------------------------------------------------------

  /// Set the broadcast rate for a specific status frame.
  ///
  /// [statusIndex] is the status frame index (0–6).
  /// [rateMs] is the period in milliseconds.
  void setStatusFrameRate(int statusIndex, int rateMs) {
    final arbId = buildArbId(
      apiClass: kApiClassFrameRate,
      apiIndex: statusIndex,
      deviceId: _deviceId,
    );
    final payload = buildFrameRatePayload(rateMs);
    _conn.sendCommand(arbId, payload);
  }

  /// Configure frame rates optimized for system identification data
  /// collection (fast velocity & position, slower everything else).
  void configureForSysId() {
    setStatusFrameRate(0, 10); // Applied output — 10ms
    setStatusFrameRate(1, 10); // Velocity, voltage, current — 10ms
    setStatusFrameRate(2, 10); // Position — 10ms
    setStatusFrameRate(3, 500); // Analog — slow
    setStatusFrameRate(4, 500); // Alt encoder — slow
    setStatusFrameRate(5, 500); // Abs encoder — slow
    setStatusFrameRate(6, 500); // Abs encoder vel — slow
  }

  /// Restore default frame rates.
  void restoreDefaultFrameRates() {
    setStatusFrameRate(0, 10);
    setStatusFrameRate(1, 20);
    setStatusFrameRate(2, 20);
    setStatusFrameRate(3, 50);
    setStatusFrameRate(4, 20);
    setStatusFrameRate(5, 200);
    setStatusFrameRate(6, 200);
  }
}
