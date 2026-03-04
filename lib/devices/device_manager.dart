/// Device management: enumerating, connecting, and tracking SPARK controllers.
library;

import 'dart:async';

import 'package:flutter_libserialport/flutter_libserialport.dart';

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
  /// Reads the device's CAN ID automatically after connecting.
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
    try {
      device.canId = await parameters.getCanId();
    } catch (_) {
      // If reading fails, leave canId at default 0.
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
    final control = SimulatedControlApi(physics);

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

  /// Dispose all devices and close streams.
  void dispose() {
    disconnectAll();
    _devicesChanged.close();
  }
}
