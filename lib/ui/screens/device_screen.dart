/// Device setup screen: COM port selection, connection, identification,
/// device parameter configuration, and follower configuration.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  bool _autoConnecting = false;
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

  Future<void> _autoConnect() async {
    setState(() {
      _autoConnecting = true;
      _errorMessage = null;
    });

    try {
      final dm = ref.read(deviceManagerProvider);
      await dm.autoConnect(label: 'Leader');
      setState(() => _autoConnecting = false);
    } catch (e) {
      setState(() {
        _autoConnecting = false;
        _errorMessage = 'Auto-connect failed: $e';
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
        // Arm physics: internal deg/s â†’ encoder RPM (Ã·360 Ã—60).
        // Conversion: rotationsâ†’degrees = 360, RPMâ†’deg/s = 6.
        // Soft limits match ArmPhysics defaults: âˆ’45Â° to +90Â°.
        configNotifier.setConfig(const MechanismConfig(
          type: MechanismType.arm,
          gearRatio: 1.0,
          positionConversionFactor: 360.0,
          velocityConversionFactor: 6.0,
          forwardSoftLimit: 85.0,  // 5Â° margin inside 90Â° hard stop
          reverseSoftLimit: -40.0, // 5Â° margin inside âˆ’45Â° hard stop
          currentLimitAmps: 40.0,
        ));
        paramsNotifier.loadDefaults(MechanismType.arm);

      case 'elevator':
        // Elevator physics: 1.504 in/rotation.
        // Conversion: rotationsâ†’inches = 1.504, RPMâ†’in/s = 1.504/60.
        // Soft limits match ElevatorPhysics defaults: 0â€“48 in.
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
        // Auto-connect section
        const Text(
          'Connect',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              onPressed:
                  !_connecting && !_autoConnecting ? _autoConnect : null,
              child: _autoConnecting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: ProgressRing(strokeWidth: 2),
                    )
                  : const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.plug_connected, size: 14),
                        SizedBox(width: 6),
                        Text('Auto Connect'),
                      ],
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
          ],
        ),
        const SizedBox(height: 16),

        // Manual port selection (fallback / advanced)
        const Text(
          'Manual Port Selection',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
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
                                : '${p.name} â€” ${p.description}'
                                  '${p.isLikelySpark ? ' \u2605' : ''}',
                          ),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _selectedPort = v),
              ),
            ),
            const SizedBox(width: 8),
            Button(
              onPressed: _selectedPort != null && !_connecting && !_autoConnecting
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
              '1. Connect your leader motor â€” note its CAN ID shown above\n'
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
                // CAN ID badge â€” amber background when the read failed.
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
                          if (!widget.device.isSimulated) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: theme.accentColor
                                        .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'SERIAL',
                                style: TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  color: theme.accentColor,
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
              width: 160,
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
                'âš  Leader CAN ID cannot match this device',
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
