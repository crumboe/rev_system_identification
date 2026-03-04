/// Abstract interfaces for the SPARK controller API layers.
///
/// These allow substituting simulated implementations for testing
/// without requiring real hardware or serial port FFI dependencies.
library;

import 'dart:typed_data';

import 'parameter_api.dart' show PidGains, ControllerFeedForward;
import 'spark_protocol.dart';
import 'status_parser.dart';

// ---------------------------------------------------------------------------
// Connection interface
// ---------------------------------------------------------------------------

/// Abstract interface for a connection to a SPARK controller.
///
/// Implemented by [SparkConnection] (real USB-serial) and
/// [SimulatedSparkConnection] (in-memory physics simulation).
abstract class ISparkConnection {
  /// Whether the connection is currently open.
  bool get isOpen;

  /// A human-readable name for this connection (e.g. "COM3" or "Simulated").
  String get portName;

  /// The latest parsed Status Frame 0.
  StatusFrame0? get lastStatus0;

  /// The latest parsed Status Frame 1 (velocity, current, voltage).
  StatusFrame1? get lastStatus1;

  /// The latest parsed Status Frame 2 (position).
  StatusFrame2? get lastStatus2;

  /// Open the connection.
  void open();

  /// Close the connection.
  void close();

  /// Dispose of resources permanently.
  void dispose();

  /// Send a raw 12-byte packet.
  void sendRaw(Uint8List packet);

  /// Send a command (arb ID + payload).
  void sendCommand(int arbId, Uint8List payload);

  /// Send a command and await the response.
  Future<SparkResponse> sendAndReceive(
    int arbId,
    Uint8List payload, {
    Duration timeout = const Duration(milliseconds: 500),
  });
}

// ---------------------------------------------------------------------------
// Heartbeat interface
// ---------------------------------------------------------------------------

/// Abstract interface for the FRC heartbeat manager.
abstract class IHeartbeatManager {
  bool get isRunning;
  bool get isEnabled;

  void start({bool enabled = true});
  void stop();
  void enable();
  void disable();
  void sendOnce({bool enabled = true});
  void dispose();
}

// ---------------------------------------------------------------------------
// Parameter API interface
// ---------------------------------------------------------------------------

/// Abstract interface for reading/writing SPARK controller parameters.
abstract class IParameterApi {
  Future<SparkResponse> setParameter(int paramId, double value);
  Future<double> getParameter(int paramId);
  Future<SparkResponse> burnFlash();

  // CAN ID
  Future<int> getCanId();
  Future<void> setCanId(int canId);

  // Motor configuration
  Future<void> setMotorType(int type);
  Future<void> setIdleMode(int mode);
  Future<void> setMotorInverted(bool inverted);
  Future<void> setOpenLoopRampRate(double seconds);

  // Conversion factors
  Future<void> setPositionConversionFactor(double factor);
  Future<void> setVelocityConversionFactor(double factor);
  Future<double> getPositionConversionFactor();
  Future<double> getVelocityConversionFactor();

  // PID Slot 0
  Future<void> setSlot0P(double value);
  Future<void> setSlot0I(double value);
  Future<void> setSlot0D(double value);
  Future<void> setSlot0F(double value);
  Future<void> setSlot0IZone(double value);
  Future<void> setSlot0DFilter(double value);
  Future<void> setSlot0MaxOutput(double value);
  Future<void> setSlot0MinOutput(double value);
  Future<void> setPidSlot0({
    required double p,
    required double i,
    required double d,
    double f = 0.0,
    double iZone = 0.0,
    double dFilter = 0.0,
    double maxOutput = 1.0,
    double minOutput = -1.0,
  });
  Future<PidGains> getPidSlot0();

  // Current limits
  Future<void> setSmartCurrentLimit(double amps);
  Future<void> setSecondaryCurrentLimit(double amps);

  // Soft limits
  Future<void> setForwardSoftLimit(double rotations);
  Future<void> setForwardSoftLimitEnabled(bool enabled);
  Future<void> setReverseSoftLimit(double rotations);
  Future<void> setReverseSoftLimitEnabled(bool enabled);
  Future<void> configureSoftLimits({
    required double forwardLimit,
    required double reverseLimit,
  });
  Future<void> disableSoftLimits();

  // FeedForward Slot 0
  Future<void> setSlot0FfKs(double value);
  Future<void> setSlot0FfKv(double value);
  Future<void> setSlot0FfKa(double value);
  Future<void> setSlot0FfKg(double value);
  Future<void> setSlot0FfKcos(double value);
  Future<void> setSlot0FfKcosRatio(double value);
  Future<void> setFeedForwardSlot0({
    double kS = 0.0,
    double kV = 0.0,
    double kA = 0.0,
    double kG = 0.0,
    double kCos = 0.0,
    double kCosRatio = 0.0,
  });
  Future<ControllerFeedForward> getFeedForwardSlot0();

  // Follower
  Future<void> configureFollower(
    int leaderDeviceId, {
    int followerType,
  });
}

// ---------------------------------------------------------------------------
// Control API interface
// ---------------------------------------------------------------------------

/// Abstract interface for motor control and system commands.
abstract class IControlApi {
  void setSetpoint(double value, int controlType, {int pidSlot = 0});
  void setDutyCycle(double dutyCycle);
  void setVelocity(double rpm, {int pidSlot = 0});
  void setVoltage(double volts);
  void setPosition(double rotations, {int pidSlot = 0});
  void setSmartMotion(double rotations, {int pidSlot = 0});
  void setCurrent(double amps, {int pidSlot = 0});
  void stop();

  Future<SparkResponse> identify();
  Future<SparkResponse> clearFaults();
  Future<SparkResponse> factoryReset();

  void setStatusFrameRate(int statusIndex, int rateMs);
  void configureForSysId();
  void restoreDefaultFrameRates();
}
