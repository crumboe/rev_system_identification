/// Deploy screen: burn gains to flash and export code snippets.
///
/// Reads from global providers (set by the Results screen after analysis)
/// and presents a summary of all tuned parameters with one-click deploy.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../can/parameter_api.dart';
import '../../data/code_snippet_exporter.dart';
import '../../data/test_data.dart';
import '../../mechanisms/mechanism.dart';
import '../../state/app_state.dart';
import '../widgets/code_export_dialog.dart';
import '../widgets/logo_header.dart';

class DeployScreen extends ConsumerStatefulWidget {
  const DeployScreen({super.key});

  @override
  ConsumerState<DeployScreen> createState() => _DeployScreenState();
}

enum _DeployPidMode { velocity, position, both }

class _DeployScreenState extends ConsumerState<DeployScreen> {
  bool _deploying = false;
  _DeployPidMode _pidMode = _DeployPidMode.both;

  @override
  Widget build(BuildContext context) {
    final ff = ref.watch(feedforwardGainsProvider);
    final velPid = ref.watch(pidResultProvider);
    final posPid = ref.watch(posPidResultProvider);
    final config = ref.watch(mechanismConfigProvider);
    final device = ref.watch(deviceManagerProvider).leader;
    final hasGains = ff != null && (velPid != null || posPid != null);

    // Ensure selected mode is valid for available gains.
    if (velPid == null && _pidMode != _DeployPidMode.position) {
      _pidMode = _DeployPidMode.position;
    } else if (posPid == null && _pidMode != _DeployPidMode.velocity) {
      _pidMode = _DeployPidMode.velocity;
    }

    return ScaffoldPage.scrollable(
      header: const LogoPageHeader(title: 'Deploy'),
      children: [
        if (!hasGains)
          const InfoBar(
            title: Text('No gains available'),
            content: Text(
              'Run system identification on the Results screen before deploying.',
            ),
            severity: InfoBarSeverity.warning,
          ),
        if (hasGains) ...[
          // -- Config summary -----------------------------------------------
          _SectionHeader(title: 'Configuration Summary'),
          const SizedBox(height: 8),
          _ConfigSummary(config: config, ff: ff, velPid: velPid, posPid: posPid),
          const SizedBox(height: 24),

          // -- PID mode selector -------------------------------------------
          _SectionHeader(title: 'PID Gains to Deploy'),
          const SizedBox(height: 8),
          RadioGroup<_DeployPidMode>(
            groupValue: _pidMode,
            onChanged: (value) {
              if (value != null) setState(() => _pidMode = value);
            },
            child: Row(
              children: [
                for (final mode in _DeployPidMode.values)
                  if ((mode == _DeployPidMode.velocity && velPid != null) ||
                      (mode == _DeployPidMode.position && posPid != null) ||
                      (mode == _DeployPidMode.both &&
                          velPid != null && posPid != null))
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: RadioButton<_DeployPidMode>(
                        value: mode,
                        content: Text(switch (mode) {
                          _DeployPidMode.velocity => 'Velocity only',
                          _DeployPidMode.position => 'Position only',
                          _DeployPidMode.both => 'Both',
                        }),
                      ),
                    ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // -- Actions ------------------------------------------------------
          _SectionHeader(title: 'Actions'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton(
                onPressed: device == null || _deploying
                    ? null
                    : () => _burnToFlash(
                          config,
                          ff,
                          _pidMode != _DeployPidMode.position ? velPid : null,
                          _pidMode != _DeployPidMode.velocity ? posPid : null,
                        ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_deploying)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: ProgressRing(strokeWidth: 2),
                      )
                    else
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: Icon(FluentIcons.save, size: 16),
                      ),
                    Text(_deploying
                        ? 'Deploying…'
                        : 'Burn ${switch (_pidMode) {
                            _DeployPidMode.velocity => 'Velocity',
                            _DeployPidMode.position => 'Position',
                            _DeployPidMode.both => 'All',
                          }} to Flash'),
                  ],
                ),
              ),
              Button(
                onPressed: () => _showCodeExport(config, ff, velPid, posPid),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.code, size: 16),
                    SizedBox(width: 8),
                    Text('Export Code Snippets'),
                  ],
                ),
              ),
            ],
          ),
          if (device == null) ...[
            const SizedBox(height: 8),
            const InfoBar(
              title: Text('No device connected'),
              content:
                  Text('Connect a SPARK MAX to burn gains to the controller.'),
              severity: InfoBarSeverity.info,
            ),
          ],
        ],
      ],
    );
  }

  // -- Burn gains + FF + CFs to controller and flash -------------------------

  Future<void> _burnToFlash(
    MechanismConfig config,
    FeedforwardGains ff,
    PidResult? velPid,
    PidResult? posPid,
  ) async {
    final device = ref.read(deviceManagerProvider).leader;
    if (device == null) return;

    setState(() => _deploying = true);
    final errors = <String>[];

    try {
      // Conversion factors
      await device.parameters
          .setPositionConversionFactor(config.positionConversionFactor);
      await device.parameters
          .setVelocityConversionFactor(config.velocityConversionFactor);

      // Velocity PID (slot 0)
      if (velPid != null) {
        try {
          await device.parameters.setPidSlot0(
            p: velPid.kP,
            i: velPid.kI,
            d: velPid.kD,
            f: 0.0,
            iZone: velPid.iZone,
          );
          await device.parameters
              .setAllowedClosedLoopError0(velPid.allowedClosedLoopError);
        } on ParameterWriteException catch (e) {
          errors.add(
              'Vel PID param ${e.paramId} (sent ${e.sentValue}, got ${e.readBackValue})');
        }
      }

      // Position PID (slot 0 — overwrites velocity if both present; the
      // real robot typically uses one at a time, but we write both sets.)
      if (posPid != null) {
        try {
          await device.parameters.setPidSlot0(
            p: posPid.kP,
            i: posPid.kI,
            d: posPid.kD,
            f: 0.0,
            iZone: posPid.iZone,
            dFilter: posPid.dFilter,
          );
          await device.parameters
              .setAllowedClosedLoopError0(posPid.allowedClosedLoopError);
        } on ParameterWriteException catch (e) {
          errors.add(
              'Pos PID param ${e.paramId} (sent ${e.sentValue}, got ${e.readBackValue})');
        }
      }

      // Feedforward
      double kG = 0.0;
      double kCos = 0.0;
      double kCosRatio = 0.0;

      if (config.type == MechanismType.elevator) {
        kG = ff.kG;
      } else if (config.type == MechanismType.arm) {
        kCos = ff.kG;
        kCosRatio = 1.0 / 360.0;
      }

      try {
        await device.parameters.setFeedForwardSlot0(
          kS: ff.kS,
          kV: ff.kV,
          kA: ff.kA,
          kG: kG,
          kCos: kCos,
          kCosRatio: kCosRatio,
        );
      } on ParameterWriteException catch (e) {
        errors.add(
            'FF param ${e.paramId} (sent ${e.sentValue}, got ${e.readBackValue})');
      }

      // Disable extra status frames before persisting
      await device.parameters.disableExtraStatusFrames();

      await device.parameters.burnFlash(heartbeat: device.heartbeat);

      if (mounted) {
        if (errors.isNotEmpty) {
          await displayInfoBar(context, builder: (ctx, close) {
            return InfoBar(
              title: const Text('Deploy Warning'),
              content: Text(
                  'Some parameters failed to write:\n${errors.join('\n')}'),
              severity: InfoBarSeverity.error,
              action: IconButton(
                icon: const Icon(FluentIcons.clear),
                onPressed: close,
              ),
            );
          });
        } else {
          await displayInfoBar(context, builder: (ctx, close) {
            return InfoBar(
              title: const Text('Deploy Successful'),
              content: const Text(
                'All gains, feedforward, and conversion factors written to controller and saved to flash.',
              ),
              severity: InfoBarSeverity.success,
              action: IconButton(
                icon: const Icon(FluentIcons.clear),
                onPressed: close,
              ),
            );
          });
        }
      }
    } catch (e) {
      if (mounted) {
        await displayInfoBar(context, builder: (ctx, close) {
          return InfoBar(
            title: const Text('Deploy Failed'),
            content: Text('$e'),
            severity: InfoBarSeverity.error,
            action: IconButton(
              icon: const Icon(FluentIcons.clear),
              onPressed: close,
            ),
          );
        });
      }
    } finally {
      if (mounted) setState(() => _deploying = false);
    }
  }

  // -- Code export -----------------------------------------------------------

  void _showCodeExport(
    MechanismConfig config,
    FeedforwardGains ff,
    PidResult? velPid,
    PidResult? posPid,
  ) {
    final snippets = CodeSnippetExporter.generate(
      config: config,
      ff: ff,
      velocityPid: velPid,
      positionPid: posPid,
    );
    showDialog(
      context: context,
      builder: (_) => CodeExportDialog(snippets: snippets),
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: FluentTheme.of(context)
          .typography
          .subtitle
          ?.copyWith(fontSize: 16),
    );
  }
}

class _ConfigSummary extends StatelessWidget {
  final MechanismConfig config;
  final FeedforwardGains ff;
  final PidResult? velPid;
  final PidResult? posPid;

  const _ConfigSummary({
    required this.config,
    required this.ff,
    this.velPid,
    this.posPid,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final cardColor = theme.micaBackgroundColor.withValues(alpha: 0.5);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Feedforward
        _GainCard(
          title: 'Feedforward Gains',
          color: cardColor,
          rows: [
            _GainRow('kS', ff.kS),
            _GainRow('kV', ff.kV),
            _GainRow('kA', ff.kA),
            if (ff.kG != 0) _GainRow('kG', ff.kG),
          ],
        ),
        const SizedBox(height: 12),
        // Velocity PID
        if (velPid != null)
          _GainCard(
            title: 'Velocity PID',
            color: cardColor,
            rows: [
              _GainRow('kP', velPid!.kP),
              _GainRow('kI', velPid!.kI),
              _GainRow('kD', velPid!.kD),
              if (velPid!.iZone != 0) _GainRow('iZone', velPid!.iZone),
              _GainRow('CL Error', velPid!.allowedClosedLoopError),
            ],
          ),
        if (velPid != null) const SizedBox(height: 12),
        // Position PID
        if (posPid != null)
          _GainCard(
            title: 'Position PID',
            color: cardColor,
            rows: [
              _GainRow('kP', posPid!.kP),
              _GainRow('kI', posPid!.kI),
              _GainRow('kD', posPid!.kD),
              if (posPid!.dFilter != 0) _GainRow('dFilter', posPid!.dFilter),
              if (posPid!.iZone != 0) _GainRow('iZone', posPid!.iZone),
              _GainRow('CL Error', posPid!.allowedClosedLoopError),
            ],
          ),
        if (posPid != null) const SizedBox(height: 12),
        // Conversion factors
        _GainCard(
          title: 'Conversion Factors',
          color: cardColor,
          rows: [
            _GainRow('Position CF', config.positionConversionFactor),
            _GainRow('Velocity CF', config.velocityConversionFactor),
          ],
        ),
      ],
    );
  }
}

class _GainCard extends StatelessWidget {
  final String title;
  final Color color;
  final List<_GainRow> rows;

  const _GainCard({
    required this.title,
    required this.color,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      padding: const EdgeInsets.all(12),
      backgroundColor: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 24,
            runSpacing: 4,
            children: rows.map((r) => _gainCell(r.label, r.value)).toList(),
          ),
        ],
      ),
    );
  }

  Widget _gainCell(String label, double value) {
    return SizedBox(
      width: 120,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ', style: const TextStyle(fontSize: 12)),
          Text(
            value.toStringAsFixed(6),
            style: const TextStyle(
              fontSize: 12,
              fontFamily: 'Consolas',
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _GainRow {
  final String label;
  final double value;
  const _GainRow(this.label, this.value);
}
