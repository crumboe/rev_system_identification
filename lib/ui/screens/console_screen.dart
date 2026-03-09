/// Console screen — real-time communication log for all CAN-over-USB traffic.
///
/// Shows every packet sent to and received from connected SPARK controllers,
/// plus connect/disconnect events and timeout errors.  Useful for diagnosing
/// "CAN ID unreadable" issues and other communication problems.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../can/comms_log.dart';
import '../../state/app_state.dart';

class ConsoleScreen extends ConsumerStatefulWidget {
  const ConsoleScreen({super.key});

  @override
  ConsumerState<ConsoleScreen> createState() => _ConsoleScreenState();
}

class _ConsoleScreenState extends ConsumerState<ConsoleScreen> {
  final ScrollController _scrollController = ScrollController();

  /// Current filter; null means show all.
  CommDirection? _filter;

  /// Whether to auto-scroll to the latest entry.
  bool _autoScroll = true;

  /// Path of the active log file (mirrors [CommsLog.logFilePath]).
  String? _logFilePath;

  List<CommsLogEntry> _entries = [];
  StreamSubscription<List<CommsLogEntry>>? _sub;

  @override
  void initState() {
    super.initState();
    final log = ref.read(commsLogProvider);
    _entries = log.entries.toList();
    _logFilePath = log.logFilePath;
    _sub = log.stream.listen((entries) {
      if (!mounted) return;
      setState(() => _entries = entries.toList());
      if (_autoScroll) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _pickLogFile() async {
    final log = ref.read(commsLogProvider);
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Set CAN Log Save Destination',
      fileName: 'can_log.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (path == null) return;
    await log.startLoggingToFile(path);
    if (mounted) setState(() => _logFilePath = log.logFilePath);
  }

  Future<void> _stopLogFile() async {
    final log = ref.read(commsLogProvider);
    await log.stopLoggingToFile();
    if (mounted) setState(() => _logFilePath = null);
  }

  List<CommsLogEntry> get _filtered {
    final log = ref.read(commsLogProvider);
    if (_filter != null) {
      return _entries.where((e) => e.direction == _filter).toList();
    }
    // Exclude heartbeats from "All" view unless they are enabled for logging
    // (they fire at 50 Hz and would otherwise dominate the view).
    return _entries
        .where((e) => log.logHeartbeats || e.direction != CommDirection.heartbeat)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final filtered = _filtered;

    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Console'),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          compactBreakpointWidth: 600,
          primaryItems: [
            // Filter toggle buttons
            CommandBarButton(
              label: const Text('All'),
              icon: Icon(
                FluentIcons.filter,
                color: _filter == null ? theme.accentColor : null,
              ),
              onPressed: () => setState(() => _filter = null),
            ),
            CommandBarButton(
              label: const Text('TX'),
              icon: Icon(
                FluentIcons.upload,
                color: _filter == CommDirection.tx
                    ? _txColor(theme)
                    : null,
              ),
              onPressed: () => setState(
                () => _filter =
                    _filter == CommDirection.tx ? null : CommDirection.tx,
              ),
            ),
            CommandBarButton(
              label: const Text('RX'),
              icon: Icon(
                FluentIcons.download,
                color: _filter == CommDirection.rx
                    ? _rxColor(theme)
                    : null,
              ),
              onPressed: () => setState(
                () => _filter =
                    _filter == CommDirection.rx ? null : CommDirection.rx,
              ),
            ),
            CommandBarButton(
              label: const Text('Errors'),
              icon: Icon(
                FluentIcons.error_badge,
                color: _filter == CommDirection.error
                    ? Colors.red
                    : null,
              ),
              onPressed: () => setState(
                () => _filter =
                    _filter == CommDirection.error ? null : CommDirection.error,
              ),
            ),
            CommandBarButton(
              label: const Text('Heartbeats'),
              icon: Icon(
                FluentIcons.heart,
                color: ref.read(commsLogProvider).logHeartbeats
                    ? Colors.red
                    : null,
              ),
              onPressed: () {
                final log = ref.read(commsLogProvider);
                log.logHeartbeats = !log.logHeartbeats;
                setState(() {});
              },
            ),
            const CommandBarSeparator(),
            // Auto-scroll toggle
            CommandBarButton(
              label: Text(_autoScroll ? 'Auto-scroll On' : 'Auto-scroll Off'),
              icon: Icon(
                FluentIcons.down,
                color: _autoScroll ? theme.accentColor : null,
              ),
              onPressed: () {
                setState(() => _autoScroll = !_autoScroll);
                if (_autoScroll) _scrollToBottom();
              },
            ),
            // Log file button
            CommandBarButton(
              label: Text(_logFilePath != null ? 'Stop Logging' : 'Set Log File'),
              icon: Icon(
                _logFilePath != null ? FluentIcons.cancel : FluentIcons.save,
                color: _logFilePath != null ? theme.accentColor : null,
              ),
              onPressed: _logFilePath != null ? _stopLogFile : _pickLogFile,
            ),
            // Clear button
            CommandBarButton(
              label: const Text('Clear'),
              icon: const Icon(FluentIcons.delete),
              onPressed: () {
                ref.read(commsLogProvider).clear();
              },
            ),
          ],
        ),
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Entry count banner
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              '${filtered.length} entries'
              '${_filter != null ? ' (filtered: ${_filter!.name.toUpperCase()})' : ''}'
              ' — max ${CommsLog.maxEntries} kept in memory'
              '${_logFilePath != null ? ' — logging to: $_logFilePath' : ''}',
              style: TextStyle(
                fontSize: 11,
                color: theme.resources.textFillColorSecondary,
              ),
            ),
          ),

          // Column header
          _buildHeader(theme),

          // Log list
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          FluentIcons.info,
                          size: 40,
                          color: theme.resources.textFillColorSecondary,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'No communication log entries yet.\n'
                          'Connect a device to begin logging.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: theme.resources.textFillColorSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: filtered.length,
                    itemExtent: 24,
                    itemBuilder: (context, index) =>
                        _buildRow(filtered[index], theme, index),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(FluentThemeData theme) {
    final bg = theme.resources.subtleFillColorSecondary;
    const labelStyle = TextStyle(fontSize: 10, fontWeight: FontWeight.w600);

    return Container(
      height: 24,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text('Time', style: labelStyle),
          ),
          SizedBox(
            width: 50,
            child: Text('Dir', style: labelStyle),
          ),
          SizedBox(
            width: 60,
            child: Text('Port', style: labelStyle),
          ),
          SizedBox(
            width: 110,
            child: Text('Arb ID', style: labelStyle),
          ),
          SizedBox(
            width: 180,
            child: Text('Payload (hex)', style: labelStyle),
          ),
          const Expanded(
            child: Text('Description', style: labelStyle),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(
    CommsLogEntry entry,
    FluentThemeData theme,
    int index,
  ) {
    final color = _entryColor(entry, theme);
    final bg = index.isOdd
        ? theme.resources.subtleFillColorSecondary
        : Colors.transparent;

    const rowStyle = TextStyle(fontSize: 11, fontFamily: 'Consolas');

    return Container(
      height: 24,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              entry.timeString,
              style: rowStyle.copyWith(
                color: theme.resources.textFillColorSecondary,
              ),
              overflow: TextOverflow.clip,
            ),
          ),
          SizedBox(
            width: 50,
            child: Text(
              _dirLabel(entry.direction),
              style: rowStyle.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              entry.port,
              style: rowStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: 110,
            child: Text(
              entry.arbIdHex,
              style: rowStyle,
              overflow: TextOverflow.clip,
            ),
          ),
          SizedBox(
            width: 180,
            child: Text(
              entry.payloadHex,
              style: rowStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Expanded(
            child: Text(
              entry.description,
              style: rowStyle.copyWith(color: color),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Color _entryColor(CommsLogEntry entry, FluentThemeData theme) {
    switch (entry.direction) {
      case CommDirection.tx:
        return _txColor(theme);
      case CommDirection.rx:
        return _rxColor(theme);
      case CommDirection.error:
      case CommDirection.heartbeat:
        return Colors.red;
      case CommDirection.info:
        return theme.resources.textFillColorSecondary;
    }
  }

  Color _txColor(FluentThemeData theme) => theme.accentColor;

  Color _rxColor(FluentThemeData theme) =>
      theme.brightness == Brightness.dark
          ? const Color(0xFF4EC94E)
          : const Color(0xFF1A7A1A);

  String _dirLabel(CommDirection dir) {
    switch (dir) {
      case CommDirection.tx:
        return 'TX';
      case CommDirection.rx:
        return 'RX';
      case CommDirection.error:
        return 'ERR';
      case CommDirection.info:
        return 'INFO';
      case CommDirection.heartbeat:
        return 'HB';
    }
  }
}
