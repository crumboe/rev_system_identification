/// Reusable jog panel widget for manually moving a mechanism.
///
/// Provides hold-to-jog forward/reverse buttons, an adjustable voltage
/// slider, and a live position readout.  The motor runs only while a
/// button is held; releasing or leaving the panel stops the motor.
library;

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';

import '../../devices/device_manager.dart';
import '../../mechanisms/mechanism.dart';
import '../../sysid/jog_controller.dart';

/// A compact jog-control panel for manual motor movement.
///
/// [device] must be a connected [SparkDevice] (real or simulated).
/// [config] provides the conversion factors for position display.
/// [onPositionChanged] is called whenever the polled position changes (in
/// user units) so the parent can update a visual indicator.
/// [onSetForwardLimit] / [onSetReverseLimit] — optional callbacks to let the
/// user teach a soft limit from the current jog position.
class JogPanel extends StatefulWidget {
  final SparkDevice device;
  final MechanismConfig config;
  final ValueChanged<double>? onPositionChanged;
  final ValueChanged<double>? onSetForwardLimit;
  final ValueChanged<double>? onSetReverseLimit;
  final bool enabled;

  const JogPanel({
    super.key,
    required this.device,
    required this.config,
    this.onPositionChanged,
    this.onSetForwardLimit,
    this.onSetReverseLimit,
    this.enabled = true,
  });

  @override
  State<JogPanel> createState() => _JogPanelState();
}

class _JogPanelState extends State<JogPanel> {
  JogController? _jog;
  Timer? _pollTimer;
  double _position = 0.0;
  double _jogVoltage = 1.0;

  @override
  void initState() {
    super.initState();
    _jog = JogController(device: widget.device);
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _pollPosition(),
    );
  }

  @override
  void didUpdateWidget(covariant JogPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device != widget.device) {
      _jog?.dispose();
      _jog = JogController(device: widget.device);
    }
  }

  @override
  void dispose() {
    _jog?.dispose();
    _pollTimer?.cancel();
    super.dispose();
  }

  void _pollPosition() {
    if (!widget.device.isConnected) return;
    final status2 = widget.device.connection.lastStatus2;
    if (status2 == null) return;
    final pos =
        status2.positionRotations * widget.config.positionConversionFactor;
    if ((pos - _position).abs() > 0.01) {
      setState(() => _position = pos);
      widget.onPositionChanged?.call(pos);
    }
  }

  void _onJogDown(double sign) {
    if (!widget.enabled) return;
    _jog?.startJog(sign * _jogVoltage);
    setState(() {});
  }

  void _onJogUp() {
    _jog?.stopJog();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final isJogging = _jog?.isJogging ?? false;
    final unit = widget.config.positionUnit;
    final canJog = widget.enabled;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                FluentIcons.game,
                size: 14,
                color: isJogging ? Colors.warningPrimaryColor : null,
              ),
              const SizedBox(width: 6),
              const Text(
                'Manual Jog',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '${_position.toStringAsFixed(1)} $unit',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Consolas',
                  color: theme.accentColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Jog voltage slider.
          Row(
            children: [
              const SizedBox(width: 4),
              const Text('Jog V:', style: TextStyle(fontSize: 11)),
              const SizedBox(width: 6),
              Expanded(
                child: Slider(
                  value: _jogVoltage,
                  min: 0.5,
                  max: 3.0,
                  divisions: 10,
                  onChanged: canJog
                      ? (v) => setState(() => _jogVoltage = v)
                      : null,
                  label: '${_jogVoltage.toStringAsFixed(1)} V',
                ),
              ),
              SizedBox(
                width: 36,
                child: Text(
                  '${_jogVoltage.toStringAsFixed(1)}V',
                  style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Forward / Reverse jog buttons (hold-to-jog).
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTapDown: canJog ? (_) => _onJogDown(-1.0) : null,
                  onTapUp: canJog ? (_) => _onJogUp() : null,
                  onTapCancel: canJog ? () => _onJogUp() : null,
                  child: Button(
                    onPressed: canJog ? () {} : null,
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(FluentIcons.back, size: 12),
                        SizedBox(width: 4),
                        Text('Jog Reverse'),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTapDown: canJog ? (_) => _onJogDown(1.0) : null,
                  onTapUp: canJog ? (_) => _onJogUp() : null,
                  onTapCancel: canJog ? () => _onJogUp() : null,
                  child: Button(
                    onPressed: canJog ? () {} : null,
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('Jog Forward'),
                        SizedBox(width: 4),
                        Icon(FluentIcons.forward, size: 12),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),

          // "Set to Current" limit buttons.
          if (widget.onSetForwardLimit != null ||
              widget.onSetReverseLimit != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (widget.onSetReverseLimit != null)
                  Expanded(
                    child: Button(
                      onPressed: canJog
                          ? () =>
                              widget.onSetReverseLimit?.call(_position)
                          : null,
                      child: const Text(
                        'Set Reverse Limit Here',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                if (widget.onSetForwardLimit != null &&
                    widget.onSetReverseLimit != null)
                  const SizedBox(width: 8),
                if (widget.onSetForwardLimit != null)
                  Expanded(
                    child: Button(
                      onPressed: canJog
                          ? () =>
                              widget.onSetForwardLimit?.call(_position)
                          : null,
                      child: const Text(
                        'Set Forward Limit Here',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
              ],
            ),
          ],

          if (isJogging)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: InfoBar(
                title: const Text('Jogging'),
                content: Text(
                  '${(_jog!.currentVoltage > 0 ? "Forward" : "Reverse")} '
                  'at ${_jog!.currentVoltage.abs().toStringAsFixed(1)} V — '
                  'release to stop',
                ),
                severity: InfoBarSeverity.warning,
              ),
            ),
        ],
      ),
    );
  }
}
