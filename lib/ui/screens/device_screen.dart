/// Device setup screen: COM port selection, connection, identification,
/// and follower configuration.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../devices/device_manager.dart';
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

  Future<void> _connect() async {
    if (_selectedPort == null) return;

    setState(() {
      _connecting = true;
      _errorMessage = null;
    });

    try {
      final dm = ref.read(deviceManagerProvider);
      await dm.connect(_selectedPort!, label: 'Leader');
      setState(() => _connecting = false);
    } catch (e) {
      setState(() {
        _connecting = false;
        _errorMessage = 'Failed to connect: $e';
      });
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
                items: _ports
                    .map((p) => ComboBoxItem<String>(
                          value: p.name,
                          child: Text(
                            '${p.name} — ${p.description}'
                            '${p.isLikelySpark ? ' ★' : ''}',
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
          ...devices.map((device) => _DeviceCard(
                device: device,
                onDisconnect: () {
                  dm.disconnect(device);
                  setState(() {});
                },
                onIdentify: () => device.identify(),
              )),

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

class _DeviceCard extends StatelessWidget {
  final SparkDevice device;
  final VoidCallback onDisconnect;
  final VoidCallback onIdentify;

  const _DeviceCard({
    required this.device,
    required this.onDisconnect,
    required this.onIdentify,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        child: Row(
          children: [
            // CAN ID badge
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: theme.accentColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${device.canId}',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: theme.accentColor,
                    ),
                  ),
                  Text(
                    'CAN ID',
                    style: TextStyle(
                      fontSize: 9,
                      color: theme.accentColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              device.isConnected
                  ? FluentIcons.plug_connected
                  : FluentIcons.plug_disconnected,
              color: device.isConnected ? Colors.green : Colors.red,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.label,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${device.connection.portName} • '
                    '${device.isLeader ? "Leader" : "Follower"}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            Button(
              onPressed: onIdentify,
              child: const Text('Identify'),
            ),
            const SizedBox(width: 8),
            Button(
              onPressed: onDisconnect,
              child: const Text('Disconnect'),
            ),
          ],
        ),
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
