/// Device management: enumerating, connecting, and tracking SPARK controllers.
library;

import 'dart:async';

import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:flutter/foundation.dart';

import '../can/interfaces.dart';
import '../can/spark_connection.dart';
import '../can/heartbeat.dart';
import '../can/parameter_api.dart';
import '../can/control_api.dart';
import '../simulation/simulated_physics.dart';
import '../simulation/flywheel_physics.dart';
import '../simulation/arm_physics.dart';
import '../simulation/elevator_physics.dart';
import '../simulation/simulated_device.dart';

/// Information about a discovered serial port that may be a SPARK controller.
class PortInfo {
  final String name;
  final String description;
  final String? manufacturer;
  final int? vendorId;
  final int? productId;

  const PortInfo({
    required this.name,
    required this.description,
    this.manufacturer,
    this.vendorId,
    this.productId,
  });

  /// Whether this port is likely a REV SPARK controller.
  bool get isLikelySpark {
    final mfr = manufacturer?.toLowerCase() ?? '';
    final desc = description.toLowerCase();
    return mfr.contains('rev') ||
        desc.contains('spark') ||
        desc.contains('rev') ||
        desc.contains('usb serial');
  }

  @override
  String toString() => '$name ($description)';
}

/// Represents a fully-connected SPARK controller with all API layers.
class SparkDevice {
  final ISparkConnection connection;
  final IHeartbeatManager heartbeat;
  final IParameterApi parameters;
  final IControlApi control;

  /// User-assigned label for this device (e.g., "Leader", "Follower 1").
  String label;

  /// The CAN device ID (6-bit, 0–63).
  int canId;

  /// Whether this device is the leader in follower configurations.
  bool isLeader;

  /// Whether this device is a simulated (non-hardware) device.
  final bool isSimulated;

  SparkDevice({
    required this.connection,
    required this.heartbeat,
    required this.parameters,
    required this.control,
    this.label = 'Motor',
    this.canId = 0,
    this.isLeader = true,
    this.isSimulated = false,
  });

  /// Whether the CAN ID was successfully read from the device on connect.
  ///
  /// `false` means either this is a fresh default (not yet read) or the
  /// read failed.  When `false` and [canId] == 0, show a warning in the UI.
  bool canIdReadSucceeded = false;

  /// Human-readable note set when the connection has diagnostics to surface
  /// (e.g. why the CAN ID could not be read, or a safety-lockout hint).
  String? connectionNote;

  bool get isConnected => connection.isOpen;

  /// Blink the controller LED for identification.
  Future<void> identify() => control.identify();

  /// Dispose all resources.
  void dispose() {
    heartbeat.dispose();
    connection.dispose();
  }
}

/// Manages the lifecycle of connected SPARK controllers.
class DeviceManager {
  final List<SparkDevice> _devices = [];

  /// All currently-connected devices.
  List<SparkDevice> get devices => List.unmodifiable(_devices);

  /// The primary (leader) device, if any.
  SparkDevice? get leader => _devices.isEmpty ? null : _devices.first;

  /// Stream controller for device list changes.
  final _devicesChanged = StreamController<List<SparkDevice>>.broadcast();
  Stream<List<SparkDevice>> get devicesChanged => _devicesChanged.stream;

  // -----------------------------------------------------------------------
  // Port enumeration
  // -----------------------------------------------------------------------

  /// Scan for available serial ports and return info about each.
  List<PortInfo> scanPorts() {
    final portNames = SerialPort.availablePorts;
    return portNames.map((name) {
      final port = SerialPort(name);
      final info = PortInfo(
        name: name,
        description: port.description ?? name,
        manufacturer: port.manufacturer,
        vendorId: port.vendorId,
        productId: port.productId,
      );
      port.dispose();
      return info;
    }).toList();
  }

  // -----------------------------------------------------------------------
  // Connection
  // -----------------------------------------------------------------------

  /// Connect to a SPARK controller on the given COM port.
  ///
  /// Reads the device's CAN ID automatically after connecting (retried up to
  /// three times).  If the read still fails, [SparkDevice.connectionNote] is
  /// set to an actionable explanation and [SparkDevice.canIdReadSucceeded] is
  /// left `false`.  The device is still usable for motor control — USB
  /// commands are device-ID-agnostic.
  ///
  /// Returns the connected [SparkDevice].
  /// Throws if the port cannot be opened.
  Future<SparkDevice> connect(String portName, {String label = 'Motor'}) async {
    final connection = SparkConnection.fromPortName(portName);
    connection.open();

    final heartbeat = HeartbeatManager(connection);
    final parameters = ParameterApi(connection);
    final control = ControlApi(connection);

    final device = SparkDevice(
      connection: connection,
      heartbeat: heartbeat,
      parameters: parameters,
      control: control,
      label: label,
    );

    // Read the device's CAN ID from parameter 0.
    // Retry up to three times to handle slow controller start-up.
    const maxAttempts = 3;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        device.canId = await parameters.getCanId();
        device.canIdReadSucceeded = true;
        break;
      } catch (e) {
        if (attempt < maxAttempts - 1) {
          // Brief pause before the next attempt.
          await Future.delayed(_retryDelay);
        } else {
          // Surface a helpful diagnostic after all retries are exhausted.
          final reason = _shortError(e);
          device.connectionNote =
              'CAN ID unreadable ($reason). '
              'Motor control may still work — USB commands do not require '
              'a known CAN ID. If this persists, power-cycle the controller '
              'and reconnect (a previous CAN-bus connection can lock out USB).';
          debugPrint(
            '[DeviceManager] getCanId failed after $maxAttempts attempts '
            'on $portName: $e',
          );
        }
      }
    }

    _devices.add(device);
    _notifyChanged();
    return device;
  }

  /// Connect a simulated device (no hardware required).
  ///
  /// Creates a physics-based model with known system constants
  /// that students can verify through the sysid workflow.
  /// [mechanismType] selects flywheel, arm, or elevator physics.
  Future<SparkDevice> connectSimulated({
    String? mechanismType,
  }) async {
    final SimulatedPhysics physics;
    switch (mechanismType) {
      case 'arm':
        physics = ArmPhysics();
      case 'elevator':
        physics = ElevatorPhysics();
      default:
        physics = FlywheelPhysics();
    }

    final connection = SimulatedSparkConnection(physics);
    connection.open();

    final heartbeat = SimulatedHeartbeatManager();
    final parameters = SimulatedParameterApi();
    final control = SimulatedControlApi(physics, parameters);

    // Wire up closed-loop PID+FF controller for the simulation.
    final pidFf = SimulatedPidFfController(parameters, physics);
    control.attachPidFfController(pidFf);
    connection.controlApi = control;

    final device = SparkDevice(
      connection: connection,
      heartbeat: heartbeat,
      parameters: parameters,
      control: control,
      label: physics.label,
      canId: 42,
      isSimulated: true,
    );
    device.canIdReadSucceeded = true;

    _devices.add(device);
    _notifyChanged();
    return device;
  }

  /// Disconnect and remove a device.
  void disconnect(SparkDevice device) {
    device.heartbeat.stop();
    device.connection.close();
    _devices.remove(device);
    _notifyChanged();
  }

  /// Disconnect all devices.
  void disconnectAll() {
    for (final device in _devices) {
      device.heartbeat.stop();
      device.connection.close();
    }
    _devices.clear();
    _notifyChanged();
  }

  // -----------------------------------------------------------------------
  // Follower configuration workflow
  // -----------------------------------------------------------------------

  /// Configure a connected device as a follower of [leaderCanId].
  ///
  /// This sets the follower parameters and burns them to flash so the
  /// follower will work even without USB connected.
  Future<void> configureAsFollower(
    SparkDevice device, {
    required int leaderCanId,
    int followerType = 0x1A,
  }) async {
    device.isLeader = false;
    device.label = 'Follower (CAN $leaderCanId)';

    await device.parameters.configureFollower(
      leaderCanId,
      followerType: followerType,
    );
    await device.parameters.burnFlash();
    _notifyChanged();
  }

  void _notifyChanged() {
    if (!_devicesChanged.isClosed) {
      _devicesChanged.add(List.unmodifiable(_devices));
    }
  }

  // -----------------------------------------------------------------------
  // Diagnostics helpers
  // -----------------------------------------------------------------------

  /// Retry interval between CAN ID read attempts.
  static const _retryDelay = Duration(milliseconds: 150);

  /// Re-read the CAN ID for [device] (e.g. after a user power-cycles
  /// the controller and clicks "Re-read CAN ID" in the UI).
  Future<void> reReadCanId(SparkDevice device) async {
    try {
      device.canId = await device.parameters.getCanId();
      device.canIdReadSucceeded = true;
      device.connectionNote = null; // clear any prior warning
    } catch (e) {
      device.connectionNote =
          'CAN ID re-read failed (${_shortError(e)}). '
          'Check that the controller is powered and the USB cable is secure.';
    }
    _notifyChanged();
  }

  /// Produce a short, human-friendly error string from an exception.
  static String _shortError(Object e) {
    if (e is TimeoutException) return 'no response (timeout)';
    if (e is StateError) return 'port closed unexpectedly';
    final s = e.toString();
    const prefix = 'Exception: ';
    return s.startsWith(prefix) ? s.substring(prefix.length) : s;
  }

  /// Dispose all devices and close streams.
  void dispose() {
    disconnectAll();
    _devicesChanged.close();
  }
}
