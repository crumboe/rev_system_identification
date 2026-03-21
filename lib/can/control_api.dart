/// High-level API for sending control commands and system commands to
/// SPARK MAX/Flex controllers.
library;

import 'dart:async';
import 'dart:typed_data';

import 'interfaces.dart';
import 'spark_protocol.dart';

/// Provides typed methods for motor control and system commands.
class ControlApi implements IControlApi {
  final ISparkConnection _conn;
  final int _deviceId;

  ControlApi(this._conn, {int deviceId = 0}) : _deviceId = deviceId;

  // -----------------------------------------------------------------------
  // Setpoint commands (API Class 0x00, different indices per control mode)
  // -----------------------------------------------------------------------

  /// Map from control type constant to the fw26 API index.
  static const Map<int, int> _controlTypeToApiIndex = {
    kControlTypeDutyCycle: kControlIndexDutyCycle,       // index 2
    kControlTypeVelocity: kControlIndexVelocity,         // index 0
    kControlTypePosition: kControlIndexPosition,         // index 4
    kControlTypeVoltage: kControlIndexVoltage,           // index 5
    kControlTypeMAXMotionPosition: kControlIndexMAXMotionPosition, // index 8
    kControlTypeMAXMotionVelocity: kControlIndexMAXMotionVelocity, // index 9
  };

  /// Send a setpoint command to the controller.
  ///
  /// Firmware 26.x uses distinct API indices per control mode.
  /// Payload is float32 LE + pidSlot + reserved bytes.
  void setSetpoint(
    double value,
    int controlType, {
    int pidSlot = 0,
  }) {
    final apiIndex = _controlTypeToApiIndex[controlType];
    if (apiIndex == null) {
      throw ArgumentError('Unsupported control type: $controlType');
    }
    final arbId = buildArbId(
      apiClass: kApiClassControl,
      apiIndex: apiIndex,
      deviceId: _deviceId,
    );
    final payload = buildSetpointPayload(value, pidSlot: pidSlot);
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

  /// Set MAXMotion position setpoint in rotations (profiled closed-loop).
  void setSmartMotion(double rotations, {int pidSlot = 0}) =>
      setSetpoint(rotations, kControlTypeMAXMotionPosition, pidSlot: pidSlot);

  /// Set current setpoint in amps (closed-loop).
  void setCurrent(double amps, {int pidSlot = 0}) =>
      setSetpoint(amps, kControlTypeCurrent, pidSlot: pidSlot);

  /// Send zero voltage (stop the motor).
  void stop() => setVoltage(0.0);

  // -----------------------------------------------------------------------
  // System commands (API Class 0x02)
  // -----------------------------------------------------------------------

  /// Blink the controller's LED for identification.
  Future<SparkResponse> identify() async {
    final targetId = await _resolveTargetDeviceId();

    // Firmware >=25 uses identify on apiClass 0x07, apiIndex 0x07
    // (frame ID base 0x02051DC0). This command does not reliably emit a
    // dedicated ack frame, so send without waiting for a response.
    final modernArbId = buildArbId(
      apiClass: kApiClassFrameRate,
      apiIndex: 0x07,
      deviceId: targetId,
    );
    _conn.sendCommand(modernArbId, Uint8List(0));

    // Also send legacy identify for older firmware compatibility.
    final legacyArbId = buildArbId(
      apiClass: kApiClassSystem,
      apiIndex: kSystemIndexIdentify,
      deviceId: targetId,
    );
    if (legacyArbId != modernArbId) {
      _conn.sendCommand(legacyArbId, Uint8List(0));
    }

    return SparkResponse(
      responseType: kUsbResponseAck,
      arbId: modernArbId,
      payload: Uint8List(8),
    );
  }

  Future<int> _resolveTargetDeviceId() async {
    if (_deviceId != 0) return _deviceId;
    try {
      return await _conn.responses
          .where((r) =>
              r.apiClass == kApiClassNewStatus || r.apiClass == kApiClassStatus)
          .map((r) => r.deviceId)
          .first
          .timeout(const Duration(milliseconds: 150));
    } on TimeoutException {
      return _deviceId;
    }
  }

  /// Clear all active faults.
  Future<SparkResponse> clearFaults() async {
    final targetId = await _resolveTargetDeviceId();

    // Modern clear-faults frame (SPARK_CLEAR_FAULTS_FRAME_ID base 0x02051B80)
    final modernArbId = buildArbId(
      apiClass: kApiClassStatus,
      apiIndex: 0x0E,
      deviceId: targetId,
    );
    _conn.sendCommand(modernArbId, Uint8List(0));

    // Legacy fallback
    final legacyArbId = buildArbId(
      apiClass: kApiClassSystem,
      apiIndex: kSystemIndexClearFaults,
      deviceId: targetId,
    );
    if (legacyArbId != modernArbId) {
      _conn.sendCommand(legacyArbId, Uint8List(0));
    }

    return SparkResponse(
      responseType: kUsbResponseAck,
      arbId: modernArbId,
      payload: Uint8List(8),
    );
  }

  /// Factory reset the controller to default settings.
  Future<SparkResponse> factoryReset() async {
    final targetId = await _resolveTargetDeviceId();

    // Modern complete-factory-reset frame (base 0x020505C0)
    final modernArbId = buildArbId(
      apiClass: kApiClassParameter,
      apiIndex: 0x07,
      deviceId: targetId,
    );
    _conn.sendCommand(modernArbId, Uint8List(2));

    // Legacy fallback
    final legacyArbId = buildArbId(
      apiClass: kApiClassSystem,
      apiIndex: kSystemIndexFactoryReset,
      deviceId: targetId,
    );
    if (legacyArbId != modernArbId) {
      _conn.sendCommand(legacyArbId, Uint8List(2));
    }

    return SparkResponse(
      responseType: kUsbResponseAck,
      arbId: modernArbId,
      payload: Uint8List(8),
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
  ///
  /// Sends both the legacy frame-rate CAN commands (apiClass 0x07) AND
  /// writes the status-period parameters (IDs 158–165, 199, 224) so that
  /// both old (<25.0) and new (≥25.0) firmware respects the settings.
  ///
  /// A short delay is inserted between each command so the controller has
  /// time to process each frame-rate change before the next arrives.
  Future<void> configureForSysId() async {
    const gap = Duration(milliseconds: 35);
    // Legacy frame-rate commands (apiClass 0x07).
    setStatusFrameRate(0, 10); // Applied output — 10ms
    await Future<void>.delayed(gap);
    setStatusFrameRate(1, 10); // Velocity, voltage, current — 10ms
    await Future<void>.delayed(gap);
    setStatusFrameRate(2, 10); // Position — 10ms
    await Future<void>.delayed(gap);
    setStatusFrameRate(3, 500); // Analog — slow
    await Future<void>.delayed(gap);
    setStatusFrameRate(4, 500); // Alt encoder — slow
    await Future<void>.delayed(gap);
    setStatusFrameRate(5, 10); // Abs encoder position — 10ms (for absolute encoder feedback)
    await Future<void>.delayed(gap);
    setStatusFrameRate(6, 500); // Abs encoder vel — slow
  }

  /// Restore default frame rates.
  Future<void> restoreDefaultFrameRates() async {
    const gap = Duration(milliseconds: 15);
    setStatusFrameRate(0, 10);
    await Future<void>.delayed(gap);
    setStatusFrameRate(1, 20);
    await Future<void>.delayed(gap);
    setStatusFrameRate(2, 20);
    await Future<void>.delayed(gap);
    setStatusFrameRate(3, 50);
    await Future<void>.delayed(gap);
    setStatusFrameRate(4, 20);
    await Future<void>.delayed(gap);
    setStatusFrameRate(5, 200);
    await Future<void>.delayed(gap);
    setStatusFrameRate(6, 200);
  }
}
