/// Device setup screen: COM port selection, connection, identification,
/// device parameter configuration, and follower configuration.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../can/spark_protocol.dart';
import '../../devices/device_manager.dart';
import '../../mechanisms/mechanism.dart';
import '../../state/app_state.dart';

class DeviceScreen extends ConsumerStatefulWidget {
  const DeviceScreen({super.key});

  @override
  ConsumerState<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends ConsumerState<DeviceScreen> {
  List<PortInfo> _ports = [];
  String? _selectedPort;
  bool _connecting = false;
  String? _errorMessage;

  /// Sentinel port names for simulated devices.
  static const _simFlywheel = '__SIM_FLYWHEEL__';
  static const _simArm = '__SIM_ARM__';
  static const _simElevator = '__SIM_ELEVATOR__';

  static const _simPorts = [_simFlywheel, _simArm, _simElevator];

  @override
  void initState() {
    super.initState();
    _refreshPorts();
  }

  void _refreshPorts() {
    final dm = ref.read(deviceManagerProvider);
    setState(() {
      _ports = dm.scanPorts();
      _errorMessage = null;
    });
  }

  /// Returns the port list with simulated device entries prepended.
  List<PortInfo> get _portsWithSim => [
        const PortInfo(
          name: _simFlywheel,
          description: 'Simulated Flywheel (no hardware needed)',
        ),
        const PortInfo(
          name: _simArm,
          description: 'Simulated Arm (no hardware needed)',
        ),
        const PortInfo(
          name: _simElevator,
          description: 'Simulated Elevator (no hardware needed)',
        ),
        ..._ports,
      ];

  Future<void> _connect() async {
    if (_selectedPort == null) return;

    setState(() {
      _connecting = true;
      _errorMessage = null;
    });

    try {
      final dm = ref.read(deviceManagerProvider);
      if (_simPorts.contains(_selectedPort)) {
        final type = switch (_selectedPort) {
          _simArm => 'arm',
          _simElevator => 'elevator',
          _ => 'flywheel',
        };
        await dm.connectSimulated(mechanismType: type);
        _applySimulatedConfig(type);
      } else {
        await dm.connect(_selectedPort!, label: 'Leader');
      }
      setState(() => _connecting = false);
    } catch (e) {
      setState(() {
        _connecting = false;
        _errorMessage = 'Failed to connect: $e';
      });
    }
  }

  /// Pre-populate mechanism config and test params for simulated devices.
  ///
  /// The simulated physics models use specific internal units and ranges.
  /// These conversion factors translate encoder-native rotations/RPM into
  /// the user-facing units (degrees, inches, etc.) so that soft-limit
  /// checks and data recording work correctly.
  void _applySimulatedConfig(String type) {
    final configNotifier = ref.read(mechanismConfigProvider.notifier);
    final paramsNotifier = ref.read(testParamsProvider.notifier);

    switch (type) {
      case 'arm':
        // Arm physics: internal deg/s → encoder RPM (÷360 ×60).
        // Conversion: rotations→degrees = 360, RPM→deg/s = 6.
        // Soft limits match ArmPhysics defaults: −45° to +90°.
        configNotifier.setConfig(const MechanismConfig(
          type: MechanismType.arm,
          gearRatio: 1.0,
          positionConversionFactor: 360.0,
          velocityConversionFactor: 6.0,
          forwardSoftLimit: 85.0,  // 5° margin inside 90° hard stop
          reverseSoftLimit: -40.0, // 5° margin inside −45° hard stop
          currentLimitAmps: 40.0,
        ));
        paramsNotifier.loadDefaults(MechanismType.arm);

      case 'elevator':
        // Elevator physics: 1.504 in/rotation.
        // Conversion: rotations→inches = 1.504, RPM→in/s = 1.504/60.
        // Soft limits match ElevatorPhysics defaults: 0–48 in.
        configNotifier.setConfig(MechanismConfig(
          type: MechanismType.elevator,
          gearRatio: 1.0,
          positionConversionFactor: 1.504,
          velocityConversionFactor: 1.504 / 60.0,
          forwardSoftLimit: 46.0,  // 2" margin inside 48" hard stop
          reverseSoftLimit: 2.0,   // 2" margin inside 0" hard stop
          currentLimitAmps: 40.0,
        ));
        paramsNotifier.loadDefaults(MechanismType.elevator);

      default:
        // Flywheel: rotations and RPM are native, no soft limits needed.
        configNotifier.setConfig(const MechanismConfig(
          type: MechanismType.flywheel,
          gearRatio: 1.0,
          positionConversionFactor: 1.0,
          velocityConversionFactor: 1.0,
          currentLimitAmps: 40.0,
        ));
        paramsNotifier.loadDefaults(MechanismType.flywheel);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dm = ref.watch(deviceManagerProvider);
    final devices = dm.devices;

    return ScaffoldPage.scrollable(
      header: const PageHeader(title: Text('Device Setup')),
      children: [
        // Port selection section
        const Text(
          'Serial Port',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Flexible(
              child: ComboBox<String>(
                placeholder: const Text('Select COM port'),
                isExpanded: true,
                value: _selectedPort,
                items: _portsWithSim
                    .map((p) => ComboBoxItem<String>(
                          value: p.name,
                          child: Text(
                            _simPorts.contains(p.name)
                                ? '\u{1F9EA} ${p.description}'
                                : '${p.name} — ${p.description}'
                                  '${p.isLikelySpark ? ' \u2605' : ''}',
                          ),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _selectedPort = v),
              ),
            ),
            const SizedBox(width: 8),
            Button(
              onPressed: _refreshPorts,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.refresh, size: 14),
                  SizedBox(width: 6),
                  Text('Refresh'),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _selectedPort != null && !_connecting
                  ? _connect
                  : null,
              child: _connecting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: ProgressRing(strokeWidth: 2),
                    )
                  : const Text('Connect'),
            ),
          ],
        ),
        if (_errorMessage != null) ...[
          const SizedBox(height: 8),
          InfoBar(
            title: const Text('Connection Error'),
            content: Text(_errorMessage!),
            severity: InfoBarSeverity.error,
          ),
        ],

        const SizedBox(height: 24),

        // Connected devices section
        const Text(
          'Connected Devices',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        if (devices.isEmpty)
          const InfoBar(
            title: Text('No devices connected'),
            content: Text(
              'Select a COM port above and click Connect to begin.',
            ),
            severity: InfoBarSeverity.info,
          )
        else
          ...devices.expand((device) => [
                _DeviceCard(
                  device: device,
                  onDisconnect: () {
                    dm.disconnect(device);
                    setState(() {});
                  },
                  onIdentify: () => device.identify(),
                  onReReadCanId: () async {
                    await dm.reReadCanId(device);
                    setState(() {});
                  },
                ),
                if (device.isConnected)
                  _DeviceConfigPanel(device: device),
              ]),

        const SizedBox(height: 24),

        // Follower configuration section
        if (devices.isNotEmpty) ...[
          const Text(
            'Follower Configuration',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          InfoBar(
            title: const Text('USB connects to one device at a time'),
            content: const Text(
              'CAN commands cannot be relayed to other devices through USB. '
              'To configure followers, swap the USB cable to each follower '
              'motor one at a time.\n\n'
              'Workflow:\n'
              '1. Connect your leader motor — note its CAN ID shown above\n'
              '2. Disconnect the leader, plug USB into a follower motor\n'
              '3. Connect here, enter the leader\'s CAN ID, and click '
              '"Configure as Follower"\n'
              '4. Repeat for each additional follower\n'
              '5. Reconnect the leader motor for testing\n\n'
              'Follower settings are burned to flash and persist across power cycles.',
            ),
            severity: InfoBarSeverity.info,
            isLong: true,
          ),
          const SizedBox(height: 12),
          _FollowerConfigPanel(dm: dm, devices: devices),
        ],
      ],
    );
  }
}

class _DeviceCard extends StatefulWidget {
  final SparkDevice device;
  final VoidCallback onDisconnect;
  final VoidCallback onIdentify;
  final Future<void> Function() onReReadCanId;

  const _DeviceCard({
    required this.device,
    required this.onDisconnect,
    required this.onIdentify,
    required this.onReReadCanId,
  });

  @override
  State<_DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<_DeviceCard> {
  bool _reReading = false;

  Future<void> _handleReReadCanId() async {
    setState(() => _reReading = true);
    try {
      await widget.onReReadCanId();
    } finally {
      if (mounted) setState(() => _reReading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final canIdUnknown =
        !widget.device.canIdReadSucceeded && !widget.device.isSimulated;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Row(
              children: [
                // CAN ID badge — amber background when the read failed.
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: canIdUnknown
                        ? Colors.warningPrimaryColor.withValues(alpha: 0.20)
                        : theme.accentColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        canIdUnknown ? '?' : '${widget.device.canId}',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: canIdUnknown
                              ? Colors.warningPrimaryColor
                              : theme.accentColor,
                        ),
                      ),
                      Text(
                        'CAN ID',
                        style: TextStyle(
                          fontSize: 9,
                          color: canIdUnknown
                              ? Colors.warningPrimaryColor
                              : theme.accentColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  widget.device.isConnected
                      ? FluentIcons.plug_connected
                      : FluentIcons.plug_disconnected,
                  color: widget.device.isConnected ? Colors.green : Colors.red,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            widget.device.label,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (widget.device.isSimulated) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.warningPrimaryColor
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'SIMULATED',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.warningPrimaryColor,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        '${widget.device.connection.portName} \u2022 '
                        '${widget.device.isLeader ? "Leader" : "Follower"}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (canIdUnknown) ...[
                  Button(
                    onPressed: _reReading ? null : _handleReReadCanId,
                    child: _reReading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: ProgressRing(strokeWidth: 2),
                          )
                        : const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(FluentIcons.refresh, size: 12),
                              SizedBox(width: 4),
                              Text('Re-read CAN ID'),
                            ],
                          ),
                  ),
                  const SizedBox(width: 8),
                ],
                Button(
                  onPressed: widget.onIdentify,
                  child: const Text('Identify'),
                ),
                const SizedBox(width: 8),
                Button(
                  onPressed: widget.onDisconnect,
                  child: const Text('Disconnect'),
                ),
              ],
            ),
          ),
          // Show actionable diagnostic note if the CAN ID could not be read.
          if (widget.device.connectionNote != null) ...[
            const SizedBox(height: 4),
            InfoBar(
              title: const Text('Connection diagnostic'),
              content: Text(widget.device.connectionNote!),
              severity: InfoBarSeverity.warning,
              isLong: true,
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Device Configuration Panel
// ---------------------------------------------------------------------------

/// Panel that reads all configurable parameters from a connected SPARK device,
/// displays them in editable fields, and provides a Save button to write
/// changes back and burn flash.
class _DeviceConfigPanel extends StatefulWidget {
  final SparkDevice device;

  const _DeviceConfigPanel({required this.device});

  @override
  State<_DeviceConfigPanel> createState() => _DeviceConfigPanelState();
}

class _DeviceConfigPanelState extends State<_DeviceConfigPanel> {
  bool _loading = true;
  bool _saving = false;
  String? _statusMessage;
  InfoBarSeverity _statusSeverity = InfoBarSeverity.success;

  // Editable parameter values.
  int _motorType = kMotorTypeBrushless;
  int _idleMode = kIdleModeCoast;
  bool _motorInverted = false;
  double _smartCurrentLimit = 40.0;
  double _openLoopRampRate = 0.0;
  double _closedLoopRampRate = 0.0;

  // Snapshot of values read from device, to detect changes.
  int _origMotorType = kMotorTypeBrushless;
  int _origIdleMode = kIdleModeCoast;
  bool _origMotorInverted = false;
  double _origSmartCurrentLimit = 40.0;
  double _origOpenLoopRampRate = 0.0;
  double _origClosedLoopRampRate = 0.0;

  @override
  void initState() {
    super.initState();
    _readAllParams();
  }

  bool get _hasChanges =>
      _motorType != _origMotorType ||
      _idleMode != _origIdleMode ||
      _motorInverted != _origMotorInverted ||
      _smartCurrentLimit != _origSmartCurrentLimit ||
      _openLoopRampRate != _origOpenLoopRampRate ||
      _closedLoopRampRate != _origClosedLoopRampRate;

  /// Ensure the heartbeat is running so the device responds to queries.
  /// Returns whether the heartbeat was already running before this call.
  Future<bool> _ensureHeartbeat() async {
    final wasRunning = widget.device.heartbeat.isRunning;
    if (!wasRunning) {
      widget.device.heartbeat.start(enabled: false);
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return wasRunning;
  }

  /// Stop the heartbeat if we started it (i.e. it was not previously running).
  void _restoreHeartbeat(bool wasRunning) {
    if (!wasRunning) widget.device.heartbeat.stop();
  }

  Future<void> _readAllParams() async {
    setState(() {
      _loading = true;
      _statusMessage = null;
    });

    try {
      final params = widget.device.parameters;

      final wasRunning = await _ensureHeartbeat();

      final motorType =
          (await params.getParameter(kParamMotorType)).round();
      final idleMode =
          (await params.getParameter(kParamIdleMode)).round();
      final inverted =
          (await params.getParameter(kParamMotorInverted)).round() != 0;
      final currentLimit =
          await params.getParameter(kParamSmartCurrentLimit);
      final olRamp =
          await params.getParameter(kParamOpenLoopRampRate);
      final clRamp =
          await params.getParameter(kParamClosedLoopRampRate);

      _restoreHeartbeat(wasRunning);

      if (!mounted) return;
      setState(() {
        _motorType = motorType;
        _idleMode = idleMode;
        _motorInverted = inverted;
        _smartCurrentLimit = currentLimit;
        _openLoopRampRate = olRamp;
        _closedLoopRampRate = clRamp;

        _origMotorType = motorType;
        _origIdleMode = idleMode;
        _origMotorInverted = inverted;
        _origSmartCurrentLimit = currentLimit;
        _origOpenLoopRampRate = olRamp;
        _origClosedLoopRampRate = clRamp;

        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _statusSeverity = InfoBarSeverity.error;
        _statusMessage = 'Failed to read parameters: $e';
      });
    }
  }

  Future<void> _saveAllParams() async {
    setState(() {
      _saving = true;
      _statusMessage = null;
    });

    try {
      final params = widget.device.parameters;

      final wasRunning = await _ensureHeartbeat();

      if (_motorType != _origMotorType) {
        await params.setMotorType(_motorType);
      }
      if (_idleMode != _origIdleMode) {
        await params.setIdleMode(_idleMode);
      }
      if (_motorInverted != _origMotorInverted) {
        await params.setMotorInverted(_motorInverted);
      }
      if (_smartCurrentLimit != _origSmartCurrentLimit) {
        await params.setSmartCurrentLimit(_smartCurrentLimit);
      }
      if (_openLoopRampRate != _origOpenLoopRampRate) {
        await params.setOpenLoopRampRate(_openLoopRampRate);
      }
      if (_closedLoopRampRate != _origClosedLoopRampRate) {
        await params.setParameter(
            kParamClosedLoopRampRate, _closedLoopRampRate);
      }

      await params.burnFlash();

      _restoreHeartbeat(wasRunning);

      if (!mounted) return;

      // Snapshot current values as the new originals.
      _origMotorType = _motorType;
      _origIdleMode = _idleMode;
      _origMotorInverted = _motorInverted;
      _origSmartCurrentLimit = _smartCurrentLimit;
      _origOpenLoopRampRate = _openLoopRampRate;
      _origClosedLoopRampRate = _closedLoopRampRate;

      setState(() {
        _saving = false;
        _statusSeverity = InfoBarSeverity.success;
        _statusMessage = 'Parameters saved and burned to flash.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _statusSeverity = InfoBarSeverity.error;
        _statusMessage = 'Failed to save parameters: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 8, right: 8),
      child: Expander(
        header: const Text('Device Configuration'),
        content: _loading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: ProgressRing(),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InfoBar(
                    title: const Text('⚠ Motor Type'),
                    content: const Text(
                      'Setting the wrong motor type can damage your motor. '
                      'Verify before saving.',
                    ),
                    severity: InfoBarSeverity.warning,
                  ),
                  const SizedBox(height: 12),
                  _paramRow(
                    'Motor Type',
                    RadioGroup<int>(
                      groupValue: _motorType,
                      onChanged: (v) {
                        if (v != null) setState(() => _motorType = v);
                      },
                      child: Row(
                        children: [
                          RadioButton<int>(
                            value: kMotorTypeBrushless,
                            content: const Text('Brushless'),
                          ),
                          const SizedBox(width: 16),
                          RadioButton<int>(
                            value: kMotorTypeBrushed,
                            content: const Text('Brushed'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _paramRow(
                    'Idle Mode',
                    RadioGroup<int>(
                      groupValue: _idleMode,
                      onChanged: (v) {
                        if (v != null) setState(() => _idleMode = v);
                      },
                      child: Row(
                        children: [
                          RadioButton<int>(
                            value: kIdleModeCoast,
                            content: const Text('Coast'),
                          ),
                          const SizedBox(width: 16),
                          RadioButton<int>(
                            value: kIdleModeBrake,
                            content: const Text('Brake'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _paramRow(
                    'Motor Inverted',
                    ToggleSwitch(
                      checked: _motorInverted,
                      onChanged: (v) =>
                          setState(() => _motorInverted = v),
                    ),
                  ),
                  _paramRow(
                    'Smart Current Limit (A)',
                    SizedBox(
                      width: 120,
                      child: NumberBox<double>(
                        value: _smartCurrentLimit,
                        // SPARK MAX/Flex supports 1–80 A smart current limit.
                        min: 1,
                        max: 80,
                        onChanged: (v) => setState(
                            () => _smartCurrentLimit = v ?? 40.0),
                      ),
                    ),
                  ),
                  _paramRow(
                    'Open-Loop Ramp Rate (s)',
                    SizedBox(
                      width: 120,
                      child: NumberBox<double>(
                        value: _openLoopRampRate,
                        min: 0,
                        max: 100,
                        onChanged: (v) => setState(
                            () => _openLoopRampRate = v ?? 0.0),
                      ),
                    ),
                  ),
                  _paramRow(
                    'Closed-Loop Ramp Rate (s)',
                    SizedBox(
                      width: 120,
                      child: NumberBox<double>(
                        value: _closedLoopRampRate,
                        min: 0,
                        max: 100,
                        onChanged: (v) => setState(
                            () => _closedLoopRampRate = v ?? 0.0),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      FilledButton(
                        onPressed:
                            _saving || !_hasChanges ? null : _saveAllParams,
                        child: _saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: ProgressRing(strokeWidth: 2),
                              )
                            : const Text('Save to Device'),
                      ),
                      const SizedBox(width: 8),
                      Button(
                        onPressed: _saving ? null : _readAllParams,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(FluentIcons.refresh, size: 12),
                            SizedBox(width: 4),
                            Text('Read from Device'),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Button(
                        onPressed: _saving ? null : _showAllRegisters,
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(FluentIcons.table, size: 12),
                            SizedBox(width: 4),
                            Text('All Registers'),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (_statusMessage != null) ...[
                    const SizedBox(height: 8),
                    InfoBar(
                      title: Text(_statusSeverity ==
                              InfoBarSeverity.success
                          ? 'Success'
                          : 'Error'),
                      content: Text(_statusMessage!),
                      severity: _statusSeverity,
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  /// Open a popup that reads all known SPARK parameters and shows them in a
  /// human-readable table. The table can be copied to the clipboard in
  /// tab-separated format for pasting into a spreadsheet.
  Future<void> _showAllRegisters() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _AllRegistersDialog(device: widget.device),
    );
  }

  Widget _paramRow(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(width: 220, child: Text(label)),
          child,
        ],
      ),
    );
  }
}

class _FollowerConfigPanel extends StatefulWidget {
  final DeviceManager dm;
  final List<SparkDevice> devices;

  const _FollowerConfigPanel({
    required this.dm,
    required this.devices,
  });

  @override
  State<_FollowerConfigPanel> createState() => _FollowerConfigPanelState();
}

class _FollowerConfigPanelState extends State<_FollowerConfigPanel> {
  int _leaderCanId = 0;
  bool _configuring = false;
  String? _result;
  InfoBarSeverity _resultSeverity = InfoBarSeverity.success;

  @override
  Widget build(BuildContext context) {
    final currentDevice = widget.devices.last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Show current device info
        InfoBar(
          title: Text(
            'Currently connected: ${currentDevice.connection.portName} '
            '(CAN ID ${currentDevice.canId})',
          ),
          content: Text(
            currentDevice.isLeader
                ? 'This device is set as Leader. To make it a follower, '
                  'enter the leader\'s CAN ID below.'
                : 'This device is already configured as a Follower.',
          ),
          severity: InfoBarSeverity.warning,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            const Text('Leader CAN ID: '),
            SizedBox(
              width: 100,
              child: NumberBox<int>(
                value: _leaderCanId,
                min: 0,
                max: 62,
                onChanged: (v) => setState(() => _leaderCanId = v ?? 0),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: widget.devices.isNotEmpty &&
                      !_configuring &&
                      _leaderCanId != currentDevice.canId
                  ? _configureFollower
                  : null,
              child: _configuring
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: ProgressRing(strokeWidth: 2),
                    )
                  : const Text('Configure as Follower'),
            ),
            if (_leaderCanId == currentDevice.canId) ...[
              const SizedBox(width: 12),
              const Text(
                '⚠ Leader CAN ID cannot match this device',
                style: TextStyle(fontSize: 12, color: Color(0xFFFF8C00)),
              ),
            ],
          ],
        ),
        if (_result != null) ...[
          const SizedBox(height: 8),
          InfoBar(
            title: const Text('Result'),
            content: Text(_result!),
            severity: _resultSeverity,
          ),
        ],
      ],
    );
  }

  Future<void> _configureFollower() async {
    final device = widget.devices.last;
    setState(() {
      _configuring = true;
      _result = null;
    });

    try {
      await widget.dm.configureAsFollower(
        device,
        leaderCanId: _leaderCanId,
      );
      setState(() {
        _configuring = false;
        _resultSeverity = InfoBarSeverity.success;
        _result =
            'Successfully configured ${device.connection.portName} (CAN ID '
            '${device.canId}) as follower of CAN ID $_leaderCanId. '
            'Settings burned to flash.';
      });
    } catch (e) {
      setState(() {
        _configuring = false;
        _resultSeverity = InfoBarSeverity.error;
        _result = 'Error: $e';
      });
    }
  }
}

// ---------------------------------------------------------------------------
// All Registers Dialog
// ---------------------------------------------------------------------------

/// One entry in the known-parameter catalogue.
class _ParamDescriptor {
  final int id;
  final String name;
  final String? notes;

  const _ParamDescriptor(this.id, this.name, {this.notes});
}

/// Full catalogue of known SPARK controller parameters.
const List<_ParamDescriptor> _kAllParams = [
  _ParamDescriptor(0,   'CAN ID',                        notes: '0–62'),
  _ParamDescriptor(2,   'Motor Type',                    notes: '0=Brushed, 1=Brushless'),
  _ParamDescriptor(6,   'Idle Mode',                     notes: '0=Coast, 1=Brake'),
  _ParamDescriptor(13,  'PID Slot 0 – P',                notes: 'Proportional gain'),
  _ParamDescriptor(14,  'PID Slot 0 – I',                notes: 'Integral gain'),
  _ParamDescriptor(15,  'PID Slot 0 – D',                notes: 'Derivative gain'),
  _ParamDescriptor(16,  'PID Slot 0 – F / kV',           notes: 'Velocity feedforward'),
  _ParamDescriptor(17,  'PID Slot 0 – I Zone',           notes: 'Integral zone'),
  _ParamDescriptor(18,  'PID Slot 0 – D Filter',         notes: 'D-term filter'),
  _ParamDescriptor(19,  'PID Slot 0 – Min Output',       notes: '-1.0 to 0'),
  _ParamDescriptor(20,  'PID Slot 0 – Max Output',       notes: '0 to 1.0'),
  _ParamDescriptor(21,  'PID Slot 1 – P'),
  _ParamDescriptor(22,  'PID Slot 1 – I'),
  _ParamDescriptor(23,  'PID Slot 1 – D'),
  _ParamDescriptor(24,  'PID Slot 1 – F / kV'),
  _ParamDescriptor(25,  'PID Slot 1 – I Zone'),
  _ParamDescriptor(26,  'PID Slot 1 – D Filter'),
  _ParamDescriptor(27,  'PID Slot 1 – Min Output'),
  _ParamDescriptor(28,  'PID Slot 1 – Max Output'),
  _ParamDescriptor(45,  'Motor Inverted',                notes: '0=Normal, 1=Inverted'),
  _ParamDescriptor(54,  'Forward Soft Limit Enabled',    notes: '0=Disabled, 1=Enabled'),
  _ParamDescriptor(55,  'Reverse Soft Limit Enabled',    notes: '0=Disabled, 1=Enabled'),
  _ParamDescriptor(56,  'Open-Loop Ramp Rate (s)'),
  _ParamDescriptor(59,  'Smart Current Stall Limit (A)'),
  _ParamDescriptor(60,  'Smart Current Free Limit (A)'),
  _ParamDescriptor(61,  'Smart Current Config'),
  _ParamDescriptor(75,  'Compensated Nominal Voltage (V)'),
  _ParamDescriptor(112, 'Position Conversion Factor'),
  _ParamDescriptor(113, 'Velocity Conversion Factor'),
  _ParamDescriptor(114, 'Closed-Loop Ramp Rate (s)'),
  _ParamDescriptor(115, 'Forward Soft Limit (rot)'),
  _ParamDescriptor(116, 'Reverse Soft Limit (rot)'),
  _ParamDescriptor(155, 'Product ID',                    notes: 'Read-only'),
  _ParamDescriptor(156, 'Firmware Major Version',        notes: 'Read-only'),
  _ParamDescriptor(157, 'Firmware Minor Version',        notes: 'Read-only'),
  _ParamDescriptor(166, 'MAXMotion Cruise Velocity'),
  _ParamDescriptor(167, 'MAXMotion Max Acceleration'),
  _ParamDescriptor(168, 'MAXMotion Max Jerk'),
  _ParamDescriptor(169, 'MAXMotion Allowed Error'),
  _ParamDescriptor(170, 'MAXMotion Position Mode',       notes: '0=Trapezoidal, 1=S-Curve'),
  _ParamDescriptor(194, 'Follower Leader ID'),
  _ParamDescriptor(195, 'Follower Config',               notes: '0x1A=REV, 0x1B=Talon'),
  _ParamDescriptor(198, 'Parameter Table Version'),
  _ParamDescriptor(204, 'Slot 0 FF – kS',               notes: 'Static friction (V)'),
  _ParamDescriptor(205, 'Slot 0 FF – kA',               notes: 'Acceleration gain'),
  _ParamDescriptor(206, 'Slot 0 FF – kG',               notes: 'Gravity compensation (V)'),
  _ParamDescriptor(207, 'Slot 0 FF – kCos',             notes: 'Cosine gravity (V)'),
  _ParamDescriptor(208, 'Slot 0 FF – kCos Ratio'),
  _ParamDescriptor(209, 'Slot 1 FF – kS'),
  _ParamDescriptor(210, 'Slot 1 FF – kA'),
  _ParamDescriptor(211, 'Slot 1 FF – kG'),
  _ParamDescriptor(212, 'Slot 1 FF – kCos'),
  _ParamDescriptor(213, 'Slot 1 FF – kCos Ratio'),
];

/// Represents the read result for one parameter.
class _ParamResult {
  final _ParamDescriptor descriptor;
  final double? value;   // null means the read failed
  final String? error;

  const _ParamResult({
    required this.descriptor,
    this.value,
    this.error,
  });

  String get displayValue {
    if (error != null) return '—';
    if (value == null) return '—';
    // Show integers without decimals when the value is whole-number.
    final v = value!;
    return v == v.truncateToDouble() ? v.toInt().toString() : v.toStringAsFixed(6).replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
}

/// Dialog that reads every known SPARK parameter and shows them in a table.
///
/// Opens as a modal overlay; includes a "Copy to Clipboard" button that
/// formats the table as TSV for easy pasting into Google Sheets / Excel.
class _AllRegistersDialog extends StatefulWidget {
  final SparkDevice device;

  const _AllRegistersDialog({required this.device});

  @override
  State<_AllRegistersDialog> createState() => _AllRegistersDialogState();
}

class _AllRegistersDialogState extends State<_AllRegistersDialog> {
  List<_ParamResult>? _results;
  bool _loading = true;
  String? _copyConfirmation;

  @override
  void initState() {
    super.initState();
    _fetchAll();
  }

  Future<void> _fetchAll() async {
    final params = widget.device.parameters;

    // Ensure the heartbeat is running while we query.
    final wasRunning = widget.device.heartbeat.isRunning;
    if (!wasRunning) {
      widget.device.heartbeat.start(enabled: false);
      await Future.delayed(const Duration(milliseconds: 200));
    }

    final results = <_ParamResult>[];
    for (final desc in _kAllParams) {
      try {
        final value = await params.getParameter(desc.id);
        results.add(_ParamResult(descriptor: desc, value: value));
      } catch (e) {
        results.add(_ParamResult(descriptor: desc, error: e.toString()));
      }
    }

    if (!wasRunning) widget.device.heartbeat.stop();

    if (mounted) {
      setState(() {
        _results = results;
        _loading = false;
      });
    }
  }

  void _copyToClipboard() {
    final rows = _results;
    if (rows == null) return;

    // Build TSV: header row + data rows.
    final sb = StringBuffer();
    sb.writeln('ID\tName\tValue\tNotes');
    for (final r in rows) {
      final notes = r.descriptor.notes ?? '';
      sb.writeln('${r.descriptor.id}\t${r.descriptor.name}\t${r.displayValue}\t$notes');
    }

    Clipboard.setData(ClipboardData(text: sb.toString()));
    setState(() => _copyConfirmation = 'Copied to clipboard!');
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copyConfirmation = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 680, maxHeight: 640),
      title: Row(
        children: [
          const Icon(FluentIcons.table, size: 16),
          const SizedBox(width: 8),
          const Expanded(child: Text('All Registers')),
          if (!_loading)
            Button(
              onPressed: _copyToClipboard,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(FluentIcons.copy, size: 12),
                  const SizedBox(width: 4),
                  Text(_copyConfirmation ?? 'Copy to Clipboard'),
                ],
              ),
            ),
        ],
      ),
      content: _loading
          ? const SizedBox(
              height: 200,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ProgressRing(),
                    SizedBox(height: 12),
                    Text('Reading parameters from device…'),
                  ],
                ),
              ),
            )
          : _RegistersTable(results: _results!),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// The scrollable table shown inside [_AllRegistersDialog].
class _RegistersTable extends StatelessWidget {
  final List<_ParamResult> results;

  const _RegistersTable({required this.results});

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final headerStyle = theme.typography.bodyStrong;
    final monoStyle = theme.typography.body?.copyWith(
      fontFamily: 'Consolas, monospace',
    );

    return SizedBox(
      // Fixed height keeps the dialog compact; user can scroll the table.
      height: 460,
      child: SingleChildScrollView(
        child: Table(
          columnWidths: const {
            0: FixedColumnWidth(48),   // ID
            1: FlexColumnWidth(3),     // Name
            2: FixedColumnWidth(120),  // Value
            3: FlexColumnWidth(2),     // Notes
          },
          border: TableBorder.all(
            color: theme.resources.controlStrokeColorDefault,
            width: 1,
          ),
          children: [
            // Header row
            TableRow(
              decoration: BoxDecoration(
                color: theme.resources.subtleFillColorSecondary,
              ),
              children: [
                _cell(Text('ID', style: headerStyle), isHeader: true),
                _cell(Text('Name', style: headerStyle), isHeader: true),
                _cell(Text('Value', style: headerStyle), isHeader: true),
                _cell(Text('Notes', style: headerStyle), isHeader: true),
              ],
            ),
            // Data rows
            for (final r in results)
              TableRow(
                children: [
                  _cell(Text('${r.descriptor.id}', style: monoStyle)),
                  _cell(Text(r.descriptor.name)),
                  _cell(
                    Text(
                      r.displayValue,
                      style: monoStyle?.copyWith(
                        color: r.error != null
                            ? Colors.errorSecondary
                            : null,
                      ),
                    ),
                  ),
                  _cell(
                    Text(
                      r.descriptor.notes ?? '',
                      style: theme.typography.caption,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static Widget _cell(Widget child, {bool isHeader = false}) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 8,
        vertical: isHeader ? 6 : 4,
      ),
      child: child,
    );
  }
}
