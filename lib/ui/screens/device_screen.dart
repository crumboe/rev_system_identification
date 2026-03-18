/// Device setup screen: COM port selection, connection, identification,
/// device parameter configuration, and follower configuration.
library;

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../can/status_parser.dart';
import '../../data/test_data.dart';
import '../../devices/device_manager.dart';
import '../../devices/serial_port_factory.dart'
    show isWebSerialAvailable, requestWebSerialPort, getGrantedWebSerialPorts;
import '../../mechanisms/mechanism.dart';
import '../../simulation/simulated_device.dart';
import '../../state/app_state.dart';
import '../widgets/logo_header.dart';

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
    if (kIsWeb) _autoReconnectWeb();
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
        final device = await dm.connectSimulated(mechanismType: type);
        _applySimulatedConfig(type, device: device);
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

  /// Request a Web Serial port via browser prompt and connect.
  Future<void> _connectWebSerial() async {
    setState(() {
      _connecting = true;
      _errorMessage = null;
    });

    try {
      final dm = ref.read(deviceManagerProvider);
      final connection = await requestWebSerialPort();
      await connection.open();
      await dm.connectFromConnection(connection, label: 'Leader');
      setState(() => _connecting = false);
    } catch (e) {
      setState(() {
        _connecting = false;
        _errorMessage = 'Web Serial connection failed: $e';
      });
    }
  }

  /// Auto-reconnect previously-granted Web Serial ports on page load.
  Future<void> _autoReconnectWeb() async {
    try {
      final dm = ref.read(deviceManagerProvider);
      // Skip if a device is already connected (e.g. widget rebuilt).
      if (dm.devices.isNotEmpty) return;

      final ports = await getGrantedWebSerialPorts();
      for (final connection in ports) {
        await connection.open();
        await dm.connectFromConnection(connection, label: 'Leader');
      }
      if (ports.isNotEmpty && mounted) setState(() {});
    } catch (e) {
      // Show the error so the user knows auto-reconnect failed.
      if (mounted) {
        setState(() => _errorMessage = 'Auto-reconnect failed: $e');
      }
    }
  }

  /// Pre-populate mechanism config and test params for simulated devices.
  ///
  /// The simulated physics models use specific internal units and ranges.
  /// These conversion factors translate encoder-native rotations/RPM into
  /// the user-facing units (degrees, inches, etc.) so that soft-limit
  /// checks and data recording work correctly.
  void _applySimulatedConfig(String type, {SparkDevice? device}) {
    final configNotifier = ref.read(mechanismConfigProvider.notifier);
    final paramsNotifier = ref.read(testParamsProvider.notifier);

    double pcf = 1.0;
    double vcf = 1.0;

    switch (type) {
      case 'arm':
        pcf = 360.0;
        vcf = 6.0;
        configNotifier.setConfig(const MechanismConfig(
          type: MechanismType.arm,
          positionConversionFactor: 360.0,
          velocityConversionFactor: 6.0,
          forwardSoftLimit: 85.0,
          reverseSoftLimit: -40.0,
          currentLimitAmps: 40.0,
        ));
        paramsNotifier.loadDefaults(MechanismType.arm);

      case 'elevator':
        pcf = 1.504;
        vcf = 1.504 / 60.0;
        configNotifier.setConfig(MechanismConfig(
          type: MechanismType.elevator,
          positionConversionFactor: pcf,
          velocityConversionFactor: vcf,
          forwardSoftLimit: 46.0,
          reverseSoftLimit: 2.0,
          currentLimitAmps: 40.0,
          useImperialUnits: true,
        ));
        paramsNotifier.loadDefaults(MechanismType.elevator);

      default:
        configNotifier.setConfig(const MechanismConfig(
          type: MechanismType.flywheel,
          positionConversionFactor: 1.0,
          velocityConversionFactor: 1.0,
          currentLimitAmps: 40.0,
        ));
        paramsNotifier.loadDefaults(MechanismType.flywheel);
    }

    // Write conversion factors to the simulated device's parameter store
    // so status frames report in user units from the start.
    if (device != null) {
      device.parameters.setPositionConversionFactor(pcf);
      device.parameters.setVelocityConversionFactor(vcf);
    }
  }

  /// Disconnect a project-loaded simulated device WITHOUT clearing gains or
  /// test data, so the user can immediately substitute a real controller.
  void _substituteWithRealController(SparkDevice device) {
    final dm = ref.read(deviceManagerProvider);
    dm.disconnect(device);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final dm = ref.watch(deviceManagerProvider);
    final devices = dm.devices;
    final ff = ref.watch(feedforwardGainsProvider);

    // Detect a simulated device loaded from a saved project.
    final projectSimDevice = devices.where(
      (d) => d.isSimulated && d.label.endsWith('(Project)'),
    ).firstOrNull;

    return ScaffoldPage.scrollable(
      header: const LogoPageHeader(title: 'Device Setup'),
      children: [
        // Auto-connect section
        const Text(
          'Connect',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),

        // Web Serial: single connect button + simulated devices
        if (kIsWeb) ...[
          if (isWebSerialAvailable) ...[
            Row(
              children: [
                FilledButton(
                  onPressed: !_connecting ? _connectWebSerial : null,
                  child: _connecting
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
                            Text('Connect via Web Serial'),
                          ],
                        ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const InfoBar(
              title: Text('Web Serial'),
              content: Text(
                'Click "Connect via Web Serial" to open the browser\'s device '
                'chooser. Select your SPARK MAX/Flex controller from the list. '
                'Previously-connected devices reconnect automatically on page load.',
              ),
              severity: InfoBarSeverity.info,
            ),
          ] else ...[
            const InfoBar(
              title: Text('Hardware not supported'),
              content: Text(
                'Your browser does not support Web Serial. '
                'Use Chrome, Edge, or Opera for USB device access. '
                'Simulation mode works in all browsers.',
              ),
              severity: InfoBarSeverity.warning,
            ),
          ],
          const SizedBox(height: 16),

          // Simulated device selection (available on web too)
          const Text(
            'Simulated Devices',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Flexible(
                child: ComboBox<String>(
                  placeholder: const Text('Select simulated device'),
                  isExpanded: true,
                  value: _simPorts.contains(_selectedPort) ? _selectedPort : null,
                  items: [
                    ComboBoxItem<String>(
                      value: _simFlywheel,
                      child: const Text('\u{1F9EA} Simulated Flywheel (no hardware needed)'),
                    ),
                    ComboBoxItem<String>(
                      value: _simArm,
                      child: const Text('\u{1F9EA} Simulated Arm (no hardware needed)'),
                    ),
                    ComboBoxItem<String>(
                      value: _simElevator,
                      child: const Text('\u{1F9EA} Simulated Elevator (no hardware needed)'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _selectedPort = v),
                ),
              ),
              const SizedBox(width: 8),
              Button(
                onPressed: _selectedPort != null && _simPorts.contains(_selectedPort) && !_connecting
                    ? _connect
                    : null,
                child: const Text('Connect'),
              ),
            ],
          ),
        ]

        // Native: Auto Connect + port scanning + manual selection
        else ...[
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
                                  : '${p.name} \u2014 ${p.description}'
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
        ],
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
        else ...[
          // Banner shown when a project-loaded simulated device is active.
          if (projectSimDevice != null && ff != null) ...[
            InfoBar(
              title: const Text('Using simulated model from loaded project'),
              content: const Text(
                'The physics are grounded in the identified feedforward gains. '
                'Connect a real controller below to substitute it — '
                'all project data (gains, test runs) will be preserved.',
              ),
              severity: InfoBarSeverity.warning,
              action: Button(
                onPressed: () => _substituteWithRealController(projectSimDevice),
                child: const Text('Disconnect Simulation'),
              ),
            ),
            const SizedBox(height: 8),
          ],
          ...devices.expand((device) => [
                _DeviceCard(
                  device: device,
                  onDisconnect: () {
                    dm.disconnect(device);
                    // Clear test runs and computed PID/FF results.
                    ref.read(testRunsProvider.notifier).clear();
                    ref.read(feedforwardGainsProvider.notifier).state = null;
                    ref.read(pidResultProvider.notifier).state = null;
                    ref.read(posPidResultProvider.notifier).state = null;
                    ref.read(sysIdResultsProvider.notifier).state = null;
                    ref.read(validationResultProvider.notifier).state = null;
                    setState(() {});
                  },
                  onIdentify: () => device.identify(),
                  onReReadCanId: () async {
                    await dm.reReadCanId(device);
                    setState(() {});
                  },
                  onSetCanId: (newCanId) async {
                    await dm.setCanId(device, newCanId);
                    setState(() {});
                  },
                ),
              ]),
        ],

        const SizedBox(height: 24),

        // Simulation parameters section (only for simulated devices)
        if (devices.any((d) => d.isSimulated)) ...[
          _SimParamsPanel(
            onReloadSim: () => setState(() {}),
          ),
          const SizedBox(height: 24),
        ],

        // Faults & Warnings section
        if (devices.isNotEmpty) ...[
          ...devices.expand((device) => [
            _FaultsPanel(device: device),
          ]),
        ],

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
  final Future<void> Function(int newCanId) onSetCanId;

  const _DeviceCard({
    required this.device,
    required this.onDisconnect,
    required this.onIdentify,
    required this.onReReadCanId,
    required this.onSetCanId,
  });

  @override
  State<_DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<_DeviceCard> {
  bool _reReading = false;
  bool _settingCanId = false;

  Future<void> _handleReReadCanId() async {
    setState(() => _reReading = true);
    try {
      await widget.onReReadCanId();
    } finally {
      if (mounted) setState(() => _reReading = false);
    }
  }

  Future<void> _showSetCanIdDialog() async {
    final controller = TextEditingController(
      text: widget.device.canIdReadSucceeded
          ? widget.device.canId.toString()
          : '',
    );
    String? errorText;

    final result = await showDialog<int>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return ContentDialog(
              title: const Text('Set CAN ID'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Enter a new CAN ID (0–62). This will be written to '
                    'the controller and persisted to flash.',
                  ),
                  const SizedBox(height: 12),
                  InfoLabel(
                    label: 'CAN ID',
                    child: TextBox(
                      controller: controller,
                      placeholder: '0–62',
                      autofocus: true,
                      onSubmitted: (_) {
                        final id = int.tryParse(controller.text);
                        if (id != null && id >= 0 && id <= 62) {
                          Navigator.of(context).pop(id);
                        } else {
                          setDialogState(() {
                            errorText = 'Must be an integer from 0 to 62.';
                          });
                        }
                      },
                    ),
                  ),
                  if (errorText != null) ...[                    const SizedBox(height: 4),
                    Text(
                      errorText!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.errorPrimaryColor,
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                Button(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final id = int.tryParse(controller.text);
                    if (id != null && id >= 0 && id <= 62) {
                      Navigator.of(context).pop(id);
                    } else {
                      setDialogState(() {
                        errorText = 'Must be an integer from 0 to 62.';
                      });
                    }
                  },
                  child: const Text('Set'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();

    if (result != null && mounted) {
      setState(() => _settingCanId = true);
      try {
        await widget.onSetCanId(result);
      } finally {
        if (mounted) setState(() => _settingCanId = false);
      }
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
                  onPressed: _settingCanId ? null : _showSetCanIdDialog,
                  child: _settingCanId
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: ProgressRing(strokeWidth: 2),
                        )
                      : const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(FluentIcons.edit, size: 12),
                            SizedBox(width: 4),
                            Text('Set CAN ID'),
                          ],
                        ),
                ),
                const SizedBox(width: 8),
                Button(
                  onPressed: widget.onDisconnect,
                  child: const Text('Disconnect'),
                ),
              ],
            ),
          ),
          // Show ideal feedforward gains for simulated devices.
          if (widget.device.isSimulated) ...[
            const SizedBox(height: 4),
            Builder(builder: (context) {
              final physics =
                  (widget.device.connection as SimulatedSparkConnection)
                      .physics;
              final hasGravity = physics.kG != 0.0;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Ideal FF Gains:  kS = ${physics.kS.toStringAsFixed(3)},  '
                  'kV = ${physics.kV.toStringAsFixed(4)},  '
                  'kA = ${physics.kA.toStringAsFixed(4)}'
                  '${hasGravity ? ',  kG = ${physics.kG.toStringAsFixed(3)}' : ''}',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.inactiveColor,
                    fontFamily: 'Consolas',
                  ),
                ),
              );
            }),
          ],
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

// ---------------------------------------------------------------------------
// Simulation Parameters panel — configure physical properties for sim.
// ---------------------------------------------------------------------------

class _SimParamsPanel extends ConsumerStatefulWidget {
  final VoidCallback onReloadSim;
  const _SimParamsPanel({required this.onReloadSim});

  @override
  ConsumerState<_SimParamsPanel> createState() => _SimParamsPanelState();
}

class _SimParamsPanelState extends ConsumerState<_SimParamsPanel> {
  bool _applying = false;

  Future<void> _applyAndReload() async {
    setState(() => _applying = true);
    try {
      final dm = ref.read(deviceManagerProvider);
      final device = dm.leader;
      if (device == null || !device.isSimulated) return;

      final config = ref.read(mechanismConfigProvider);
      final gains =
          ref.read(feedforwardGainsProvider) ?? _referenceGainsForConfig(config);

      dm.disconnect(device);
      await dm.connectSimulatedFromProject(gains: gains, config: config);

      // Write conversion factors to match.
      final newDevice = dm.leader;
      if (newDevice != null) {
        newDevice.parameters.setPositionConversionFactor(
            config.positionConversionFactor);
        newDevice.parameters.setVelocityConversionFactor(
            config.velocityConversionFactor);
      }

      // Clear test runs collected under old physics.
      ref.read(testRunsProvider.notifier).clear();
      ref.read(feedforwardGainsProvider.notifier).state = null;
      ref.read(pidResultProvider.notifier).state = null;
      ref.read(posPidResultProvider.notifier).state = null;
      ref.read(sysIdResultsProvider.notifier).state = null;
      ref.read(validationResultProvider.notifier).state = null;

      widget.onReloadSim();
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  FeedforwardGains _referenceGainsForConfig(MechanismConfig config) {
    final vcf = config.velocityConversionFactor;
    final pcf = config.positionConversionFactor;
    return switch (config.type) {
      MechanismType.arm => () {
          final inv = vcf > 0 ? 6.0 / vcf : 1.0;
          return FeedforwardGains(
              kS: 0.20, kV: 0.018 * inv, kA: 0.002 * inv, kG: 0.80);
        }(),
      MechanismType.elevator => () {
          final scale = (vcf > 0 && pcf > 0) ? vcf * 60.0 / pcf : 1.0;
          final inv = scale > 0 ? 1.0 / scale : 1.0;
          return FeedforwardGains(
              kS: 0.18, kV: 0.12 * inv, kA: 0.015 * inv, kG: 0.55);
        }(),
      MechanismType.flywheel || MechanismType.simple => () {
          final inv = vcf > 0 ? 1.0 / vcf : 1.0;
          return FeedforwardGains(
              kS: 0.14, kV: 0.0185 * inv, kA: 0.003 * inv, kG: 0.0);
        }(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final config = ref.watch(mechanismConfigProvider);
    final configNotifier = ref.read(mechanismConfigProvider.notifier);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FluentIcons.settings, color: theme.accentColor),
              const SizedBox(width: 8),
              Text(
                'Simulation Physical Properties',
                style: theme.typography.subtitle,
              ),
            ],
          ),
          const SizedBox(height: 8),
          const InfoBar(
            title: Text('Customize the simulated mechanism'),
            content: Text(
              'Adjust the physical properties below to change the simulated '
              'mechanism\'s behavior. Click "Apply & Reload" to rebuild the '
              'simulation with the new parameters. Previous test data will '
              'be cleared.',
            ),
            severity: InfoBarSeverity.info,
            isLong: true,
          ),
          const SizedBox(height: 12),

          // Flywheel params
          if (config.type == MechanismType.flywheel ||
              config.type == MechanismType.simple) ...[
            _simParamRow(
              label: 'Flywheel Mass (kg)',
              value: config.simulatedFlywheelMassKg,
              placeholder: '1.0 (default)',
              onChanged: (v) => configNotifier.setSimulatedFlywheelMassKg(v),
            ),
            _simParamRow(
              label: 'Flywheel Radius (m)',
              value: config.simulatedFlywheelRadiusM,
              placeholder: '0.05 (default)',
              onChanged: (v) => configNotifier.setSimulatedFlywheelRadiusM(v),
            ),
            _scaleInfoRow(
              'Inertia scale',
              _flywheelInertiaScale(config),
            ),
          ],

          // Arm params
          if (config.type == MechanismType.arm) ...[
            _simParamRow(
              label: 'Arm Mass (lbs)',
              value: config.simulatedArmMassLbs,
              placeholder: '10.0 (default)',
              onChanged: (v) => configNotifier.setSimulatedArmMassLbs(v),
            ),
            _simParamRow(
              label: 'Arm Length (in)',
              value: config.simulatedArmLengthIn,
              placeholder: '20.0 (default)',
              onChanged: (v) => configNotifier.setSimulatedArmLengthIn(v),
            ),
            Builder(builder: (_) {
              final scales = _armDynamicScales(config);
              return _scaleInfoRow(
                'Dynamics',
                scales == null
                    ? 'kA \u00d71.00, kG \u00d71.00, kS \u00d71.00'
                    : 'kA \u00d7${scales.kAScale.toStringAsFixed(2)}, '
                        'kG \u00d7${scales.kGScale.toStringAsFixed(2)}, '
                        'kS \u00d7${scales.kSScale.toStringAsFixed(2)}',
              );
            }),
          ],

          // Elevator params
          if (config.type == MechanismType.elevator) ...[
            _simParamRow(
              label: 'Carriage Mass (kg)',
              value: config.simulatedElevatorCarriageMassKg,
              placeholder: '5.0 (default)',
              onChanged: (v) =>
                  configNotifier.setSimulatedElevatorCarriageMassKg(v),
            ),
            Builder(builder: (_) {
              final scale = _elevatorMassScale(config);
              return _scaleInfoRow(
                'Mass scale',
                scale == null
                    ? 'kA \u00d71.00, kG \u00d71.00'
                    : 'kA \u00d7${scale.toStringAsFixed(2)}, '
                        'kG \u00d7${scale.toStringAsFixed(2)}',
              );
            }),
          ],

          const SizedBox(height: 12),
          FilledButton(
            onPressed: _applying ? null : _applyAndReload,
            child: _applying
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: ProgressRing(strokeWidth: 2),
                  )
                : const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(FluentIcons.refresh, size: 14),
                      SizedBox(width: 6),
                      Text('Apply & Reload Simulation'),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _simParamRow({
    required String label,
    required double? value,
    required String placeholder,
    required ValueChanged<double?> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 180,
            child: Text(label),
          ),
          SizedBox(
            width: 180,
            child: NumberBox<double>(
              value: value,
              placeholder: placeholder,
              onChanged: onChanged,
              clearButton: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _scaleInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(width: 180, child: Text(label)),
          Text(
            value,
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 12,
              color: FluentTheme.of(context).inactiveColor,
            ),
          ),
        ],
      ),
    );
  }

  String _flywheelInertiaScale(MechanismConfig config) {
    final m = config.simulatedFlywheelMassKg;
    final r = config.simulatedFlywheelRadiusM;
    if (m == null && r == null) return 'kA \u00d71.00';
    final mass = (m != null && m > 0) ? m : 1.0;
    final radius = (r != null && r > 0) ? r : 0.05;
    final massRatio = mass / 1.0;
    final radiusRatio = radius / 0.05;
    final scale = (massRatio * radiusRatio * radiusRatio).clamp(0.1, 50.0);
    return 'kA \u00d7${scale.toStringAsFixed(2)}';
  }

  ({double kAScale, double kGScale, double kSScale})?
      _armDynamicScales(MechanismConfig config) {
    final massLbs = config.simulatedArmMassLbs;
    final lengthIn = config.simulatedArmLengthIn;
    if (massLbs == null || lengthIn == null || massLbs <= 0 || lengthIn <= 0) {
      return null;
    }
    final massRatio = massLbs / 10.0;
    final lengthRatio = lengthIn / 20.0;
    final kAScale = (massRatio * lengthRatio * lengthRatio).clamp(0.2, 12.0);
    final kGScale = (massRatio * lengthRatio).clamp(0.2, 12.0);
    final kSScale = (0.85 + 0.15 * kGScale).clamp(0.6, 2.0);
    return (kAScale: kAScale, kGScale: kGScale, kSScale: kSScale);
  }

  double? _elevatorMassScale(MechanismConfig config) {
    final m = config.simulatedElevatorCarriageMassKg;
    if (m != null && m > 0) return (m / 5.0).clamp(0.1, 20.0);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Faults & Warnings panel — polls NewStatusFrame1 and shows fault chips.
// ---------------------------------------------------------------------------

class _FaultsPanel extends StatefulWidget {
  final SparkDevice device;
  const _FaultsPanel({required this.device});

  @override
  State<_FaultsPanel> createState() => _FaultsPanelState();
}

class _FaultsPanelState extends State<_FaultsPanel> {
  Timer? _timer;
  NewStatusFrame1? _status;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _status = widget.device.connection.lastNewStatus1;
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final s = widget.device.connection.lastNewStatus1;
      if (s != _status) {
        setState(() => _status = s);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final device = widget.device;
    final status = _status;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(FluentIcons.warning, color: theme.accentColor),
              const SizedBox(width: 8),
              Text(
                'Faults — ${device.connection.portName} '
                '(CAN ${device.canId})',
                style: theme.typography.subtitle,
              ),
              const Spacer(),
              FilledButton(
                onPressed: _clearing
                    ? null
                    : () async {
                        setState(() => _clearing = true);
                        await device.control.clearFaults();
                        // Give the controller a moment to update status.
                        await Future.delayed(
                            const Duration(milliseconds: 300));
                        setState(() {
                          _status = device.connection.lastNewStatus1;
                          _clearing = false;
                        });
                      },
                child: _clearing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: ProgressRing(strokeWidth: 2),
                      )
                    : const Text('Clear Faults'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (status == null)
            Text(
              'Waiting for fault status…',
              style: theme.typography.body
                  ?.copyWith(fontStyle: FontStyle.italic),
            )
          else if (!status.hasFaults)
            Row(
              children: [
                Icon(FluentIcons.completed,
                    color: Colors.green, size: 18),
                const SizedBox(width: 6),
                Text('No faults', style: theme.typography.body),
              ],
            )
          else ...[
            if (status.hasActiveFaults) ...[
              Text('Active Faults', style: theme.typography.bodyStrong),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: status.activeFaultBits
                    .map((f) => _faultChip(f.label, Colors.red))
                    .toList(),
              ),
              const SizedBox(height: 10),
            ],
            if (status.hasStickyFaults) ...[
              Text('Sticky Faults', style: theme.typography.bodyStrong),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: status.stickyFaultBits
                    .map((f) => _faultChip(f.label, Colors.orange))
                    .toList(),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _faultChip(String label, AccentColor color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.lightest,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color.darkest,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}
