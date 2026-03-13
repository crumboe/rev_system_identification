/// Device management: enumerating, connecting, and tracking SPARK controllers.
library;

import 'dart:async';

import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:flutter/foundation.dart';

import '../can/interfaces.dart';
import '../can/spark_connection.dart';
import '../can/spark_protocol.dart';
import '../can/heartbeat.dart';
import '../can/parameter_api.dart';
import '../can/control_api.dart';
import '../simulation/simulated_physics.dart';
import '../simulation/flywheel_physics.dart';
import '../simulation/arm_physics.dart';
import '../simulation/elevator_physics.dart';
import '../simulation/simulated_device.dart';
import '../data/test_data.dart';
import '../mechanisms/mechanism.dart';

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

/// The type of connection used to communicate with a SPARK controller.
enum ConnectionType {
  /// Serial SLCAN (CDC COM port).
  serial,
}

/// Represents a fully-connected SPARK controller with all API layers.
class SparkDevice {
  final ISparkConnection connection;
  final IHeartbeatManager heartbeat;
  IParameterApi parameters;
  IControlApi control;

  /// User-assigned label for this device (e.g., "Leader", "Follower 1").
  String label;

  /// The CAN device ID (6-bit, 0–63).
  int canId;

  /// The type of connection used.
  final ConnectionType connectionType;

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
    this.connectionType = ConnectionType.serial,
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

  /// Timer for periodic device re-scan when no devices are connected.
  Timer? _rescanTimer;

  /// Callback invoked when a device is auto-reconnected after disconnect.
  /// UI layers can listen to [devicesChanged] instead, but this provides
  /// an explicit signal for showing reconnect notifications.
  void Function(SparkDevice)? onAutoReconnect;

  /// Start periodic scanning for disconnected devices.
  ///
  /// When no devices are connected (or all are disconnected), scans every
  /// 5 seconds for serial devices and auto-connects if found.
  void startAutoRescan() {
    _rescanTimer?.cancel();
    _rescanTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _rescanIfNeeded(),
    );
  }

  /// Stop the periodic re-scan timer.
  void stopAutoRescan() {
    _rescanTimer?.cancel();
    _rescanTimer = null;
  }

  Future<void> _rescanIfNeeded() async {
    // Only re-scan if we have no connected devices.
    final hasConnected = _devices.any((d) => d.isConnected);
    if (hasConnected) return;

    // Remove stale disconnected devices.
    _devices.removeWhere((d) => !d.isConnected && !d.isSimulated);
    if (_devices.isNotEmpty) {
      _notifyChanged();
    }

    try {
      final ports = scanPorts();
      final sparkPorts = ports.where((p) => p.isLikelySpark).toList();
      if (sparkPorts.isNotEmpty) {
        debugPrint(
          '[DeviceManager] Auto-rescan found ${sparkPorts.length} '
          'serial port(s), reconnecting…',
        );
        final device = await connect(
          sparkPorts.first.name,
        );
        onAutoReconnect?.call(device);
      }
    } catch (e) {
      debugPrint('[DeviceManager] Auto-rescan connect failed: $e');
    }
  }

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

  /// Auto-connect to a SPARK controller via serial SLCAN.
  ///
  /// Scans for likely SPARK serial ports and connects to the first one found.
  ///
  /// Returns the connected [SparkDevice].
  /// Throws if no SPARK device could be found or connected.
  Future<SparkDevice> autoConnect({String label = 'Motor'}) async {
    final ports = scanPorts();
    final sparkPorts = ports.where((p) => p.isLikelySpark).toList();
    final targetPorts = sparkPorts.isNotEmpty ? sparkPorts : ports;

    if (targetPorts.isEmpty) {
      throw StateError(
        'No SPARK controller found. Check USB connection and ensure the '
        'device is powered on.',
      );
    }

    return await connect(targetPorts.first.name, label: label);
  }

  /// Connect to a SPARK controller on the given COM port (serial SLCAN).
  ///
  /// Reads the device's CAN ID automatically after connecting.  First tries
  /// device ID 0 (up to three times), then sweeps IDs 0–62 in case the
  /// controller only responds to its own CAN ID even over USB.
  /// If the read still fails, [SparkDevice.connectionNote] is set to an
  /// actionable explanation and [SparkDevice.canIdReadSucceeded] is left
  /// `false`.  The device is still usable for motor control — USB commands
  /// are device-ID-agnostic.
  ///
  /// Returns the connected [SparkDevice].
  /// Throws if the port cannot be opened.
  Future<SparkDevice> connect(String portName, {String label = 'Motor'}) async {
    final connection = SparkConnection.fromPortName(portName);
    await connection.open();

    return _initializeDevice(
      connection,
      connectionType: ConnectionType.serial,
      label: label,
    );
  }

  /// Shared initialization: heartbeat, CAN ID read, API setup.
  Future<SparkDevice> _initializeDevice(
    ISparkConnection connection, {
    required ConnectionType connectionType,
    required String label,
  }) async {
    final heartbeat = HeartbeatManager(connection);
    final parameters = ParameterApi(connection);
    final control = ControlApi(connection);

    final device = SparkDevice(
      connection: connection,
      heartbeat: heartbeat,
      parameters: parameters,
      control: control,
      connectionType: connectionType,
      label: label,
    );

    // Start heartbeat so the controller stays responsive to queries.
    // fw26 requires the heartbeat to be actively sent — there is no
    // "disabled" mode in the payload; the motor won't run without
    // setpoint commands regardless.
    heartbeat.start(enabled: true);
    await Future.delayed(const Duration(milliseconds: 200));

    // Read the device's CAN ID from parameter 0.
    // First try with device ID 0 (the default) up to three times.
    // If that fails, sweep all 63 possible device IDs (0–62) in case the
    // controller only responds to its own CAN ID even over USB.
    const maxAttempts = 3;
    bool found = false;
    for (var attempt = 0; attempt < maxAttempts && !found; attempt++) {
      try {
        device.canId = await parameters.getCanId();
        device.canIdReadSucceeded = true;
        found = true;
      } catch (_) {
        if (attempt < maxAttempts - 1) {
          await Future.delayed(_retryDelay);
        }
      }
    }

    // Fallback: sweep device IDs 0–62.  Some firmware versions require the
    // outbound arb-ID to carry the controller's actual CAN ID, even over
    // USB (despite the spec saying it is "don't care").
    if (!found) {
      debugPrint(
        '[DeviceManager] device ID 0 did not respond on '
        '${connection.portName} — sweeping IDs 0–62…',
      );
      final sweepResult = await _sweepForCanId(connection);
      if (sweepResult != null) {
        device.canId = sweepResult;
        device.canIdReadSucceeded = true;
        found = true;
      }
    }

    if (!found) {
      device.connectionNote =
          'CAN ID unreadable (no response after sweep of IDs 0–$kMaxCanDeviceId). '
          'Motor control may still work — USB commands do not require '
          'a known CAN ID. If this persists, power-cycle the controller '
          'and reconnect (a previous CAN-bus connection can lock out USB).';
      debugPrint(
        '[DeviceManager] getCanId failed after sweep on '
        '${connection.portName}',
      );
    } else {
      // Rebind APIs to the discovered CAN ID so addressed commands
      // (identify, clear faults, parameter writes, etc.) hit the real node.
      _retargetApisToCanId(device);
    }

    // Stop the initialization heartbeat — it will be restarted with motor
    // enabled when the user initiates jogging or a test.
    heartbeat.stop();

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
    await connection.open();

    final heartbeat = SimulatedHeartbeatManager();
    final parameters = SimulatedParameterApi();
    final control = SimulatedControlApi(physics, parameters);

    // Wire up closed-loop PID+FF controller for the simulation.
    final pidFf = SimulatedPidFfController(parameters, physics);
    control.attachPidFfController(pidFf);
    connection.controlApi = control;
    connection.paramApi = parameters;

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

  /// Connect a simulated device whose physics are grounded in [gains].
  ///
  /// Used when loading a saved project: the simulated plant mirrors the
  /// real mechanism identified during a previous session.  The device is
  /// registered in [_devices] like any other connection so the full app
  /// workflow (test, validation, PID playground) operates normally.
  ///
  /// Conversion factors from [config] are written to the simulated
  /// parameter store immediately so status frames use user units.
  Future<SparkDevice> connectSimulatedFromProject({
    required FeedforwardGains gains,
    required MechanismConfig config,
  }) async {
    const noiseLevel = 0.005;
    final type = config.type;
    final SimulatedPhysics physics = switch (type) {
      MechanismType.arm => ArmPhysics(
          kS: gains.kS,
          kV: gains.kV,
          kA: gains.kA > 0 ? gains.kA : 0.002,
          kG: gains.kG,
          noiseLevel: noiseLevel,
        ),
      MechanismType.elevator => ElevatorPhysics(
          kS: gains.kS,
          kV: gains.kV,
          kA: gains.kA > 0 ? gains.kA : 0.015,
          kG: gains.kG,
          noiseLevel: noiseLevel,
        ),
      MechanismType.flywheel || MechanismType.simple => FlywheelPhysics(
          kS: gains.kS,
          kV: gains.kV,
          kA: gains.kA > 0 ? gains.kA : 0.003,
          noiseLevel: noiseLevel,
        ),
    };

    final connection = SimulatedSparkConnection(physics);
    await connection.open();

    final heartbeat = SimulatedHeartbeatManager();
    final parameters = SimulatedParameterApi();
    final control = SimulatedControlApi(physics, parameters);

    final pidFf = SimulatedPidFfController(parameters, physics);
    control.attachPidFfController(pidFf);
    connection.controlApi = control;
    connection.paramApi = parameters;

    parameters.setPositionConversionFactor(config.positionConversionFactor);
    parameters.setVelocityConversionFactor(config.velocityConversionFactor);

    final device = SparkDevice(
      connection: connection,
      heartbeat: heartbeat,
      parameters: parameters,
      control: control,
      label: '${physics.label} (Project)',
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
    await device.parameters.burnFlash(heartbeat: device.heartbeat);
    _notifyChanged();
  }

  /// Set the CAN ID on [device], burn to flash, and retarget APIs.
  ///
  /// The new CAN ID must be in the range 0–62.
  Future<void> setCanId(SparkDevice device, int newCanId) async {
    if (newCanId < 0 || newCanId > kMaxCanDeviceId) {
      throw ArgumentError('CAN ID must be 0–$kMaxCanDeviceId');
    }

    final wasRunning = device.heartbeat.isRunning;
    if (!wasRunning) {
      device.heartbeat.start(enabled: true);
      await Future.delayed(const Duration(milliseconds: 200));
    }

    await device.parameters.setCanId(newCanId);
    await device.parameters.burnFlash(heartbeat: device.heartbeat);

    device.canId = newCanId;
    device.canIdReadSucceeded = true;
    device.connectionNote = null;
    _retargetApisToCanId(device);

    if (!wasRunning) {
      device.heartbeat.stop();
    }

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
    // Ensure the heartbeat is running so the controller responds to queries.
    final wasRunning = device.heartbeat.isRunning;
    if (!wasRunning) {
      device.heartbeat.start(enabled: true);
      await Future.delayed(const Duration(milliseconds: 200));
    }

    bool found = false;

    // First try with the current (or default) device ID.
    try {
      device.canId = await device.parameters.getCanId();
      device.canIdReadSucceeded = true;
      device.connectionNote = null;
      found = true;
    } catch (_) {
      // Fall through to sweep.
    }

    // Fallback: sweep all device IDs 0–62.
    if (!found) {
      final sweepResult = await _sweepForCanId(device.connection);
      if (sweepResult != null) {
        device.canId = sweepResult;
        device.canIdReadSucceeded = true;
        device.connectionNote = null;
        found = true;
      }
    }

    if (!found) {
      device.connectionNote =
          'CAN ID re-read failed (no response after sweep of IDs 0–$kMaxCanDeviceId). '
          'Check that the controller is powered and the USB cable is secure.';
    } else {
      _retargetApisToCanId(device);
    }

    // Stop heartbeat if we started it — it will be restarted when needed.
    if (!wasRunning) {
      device.heartbeat.stop();
    }

    _notifyChanged();
  }

  /// Sweep device IDs 0–[kMaxCanDeviceId], sending a parameter-get for
  /// CAN ID (param 0) on each one.  Returns the discovered CAN ID, or
  /// `null` if no device responded.
  ///
  /// Uses a shorter timeout per attempt to keep the total sweep under ~7 s.
  Future<int?> _sweepForCanId(ISparkConnection conn) async {
    for (var id = 0; id <= kMaxCanDeviceId; id++) {
      try {
        // fw26 param read: apiClass=7, apiIndex=1
        final requestArb = buildArbId(
          apiClass: kApiClassParam,
          apiIndex: kParamIndexRead,
          deviceId: id,
        );

        final payload = buildParamReadPayload(kParamCanId);
        conn.sendCommand(requestArb, payload);

        final response = await conn.responses
            .where((r) {
              final cls = extractApiClass(r.arbId);
              final dev = extractDeviceId(r.arbId);
              // Match class=7 responses from this device where byte[1]=0xFF
              return cls == kApiClassParam &&
                  dev == id &&
                  r.payload[0] == kParamCanId &&
                  r.payload[1] == 0xFF;
            })
            .first
            .timeout(const Duration(milliseconds: 100));

        // Response: [paramId, 0xFF, value(4), typeTag, status]
        final canId = readUint32(response.payload, 2);
        if (canId < 0 || canId > kMaxCanDeviceId) {
          continue;
        }
        debugPrint('[DeviceManager] sweep found device at ID $id '
            '(reports CAN ID $canId)');
        return canId;
      } catch (_) {
        // No response for this device ID — continue sweep.
      }
    }
    return null;
  }

  void _retargetApisToCanId(SparkDevice device) {
    device.parameters = ParameterApi(device.connection, deviceId: device.canId);
    device.control = ControlApi(device.connection, deviceId: device.canId);
    // Update heartbeat to use the discovered CAN device ID so the
    // fw26 heartbeat arb ID (apiClass=6, index=0) targets the right device.
    final hb = device.heartbeat;
    if (hb is HeartbeatManager) {
      hb.deviceId = device.canId;
    }
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
    stopAutoRescan();
    disconnectAll();
    _devicesChanged.close();
  }
}
