/// Configuration screen: mechanism type, gear ratio, units, soft limits,
/// motor settings, and test parameters.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../mechanisms/mechanism.dart';
import '../../state/app_state.dart';

class ConfigScreen extends ConsumerWidget {
  const ConfigScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(mechanismConfigProvider);
    final configNotifier = ref.read(mechanismConfigProvider.notifier);
    final testParamsNotifier = ref.read(testParamsProvider.notifier);
    final testParams = ref.watch(testParamsProvider);

    return ScaffoldPage.scrollable(
      header: const PageHeader(title: Text('Configuration')),
      children: [
        // Mechanism type
        const Text(
          'Mechanism Type',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        RadioGroup<MechanismType>(
          groupValue: config.type,
          onChanged: (value) {
            if (value != null) {
              configNotifier.setType(value);
              testParamsNotifier.loadDefaults(value);
            }
          },
          child: Row(
            children: MechanismType.values.map((type) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: RadioButton<MechanismType>(
                  value: type,
                  content: Text(type.displayName),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 8),
        InfoBar(
          title: Text(config.type.displayName),
          content: Text(
            'Gravity: ${config.type.gravityDescription}\n'
            'Soft limits: ${config.type.requiresSoftLimits ? "Required" : "Optional"}\n'
            'Units: ${config.type.positionUnit} / ${config.type.velocityUnit}',
          ),
          severity: InfoBarSeverity.info,
          isLong: true,
        ),

        const SizedBox(height: 24),

        // Motor settings
        const Text(
          'Motor Settings',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        _ConfigRow(
          label: 'Motor Type',
          child: RadioGroup<bool>(
            groupValue: config.isBrushless,
            onChanged: (v) {
              if (v != null) configNotifier.setIsBrushless(v);
            },
            child: Row(
              children: [
                RadioButton<bool>(
                  value: true,
                  content: const Text('Brushless'),
                ),
                const SizedBox(width: 16),
                RadioButton<bool>(
                  value: false,
                  content: const Text('Brushed'),
                ),
              ],
            ),
          ),
        ),
        _ConfigRow(
          label: 'Motor Inverted',
          child: ToggleSwitch(
            checked: config.motorInverted,
            onChanged: (v) => configNotifier.setMotorInverted(v),
          ),
        ),
        _ConfigRow(
          label: 'Gear Ratio (output:input)',
          child: SizedBox(
            width: 120,
            child: NumberBox<double>(
              value: config.gearRatio,
              min: 0.001,
              max: 1000,
              onChanged: (v) => configNotifier.setGearRatio(v ?? 1.0),
            ),
          ),
        ),
        _ConfigRow(
          label: 'Current Limit (A)',
          child: SizedBox(
            width: 120,
            child: NumberBox<double>(
              value: config.currentLimitAmps,
              min: 1,
              max: 80,
              onChanged: (v) => configNotifier.setCurrentLimit(v ?? 40.0),
            ),
          ),
        ),

        const SizedBox(height: 24),

        // Conversion factors
        const Text(
          'Conversion Factors',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const InfoBar(
          title: Text('Conversion factors'),
          content: Text(
            'These convert raw encoder rotations/RPM to your preferred units. '
            'For example, for an arm: 360 / gear_ratio converts rotations to degrees.',
          ),
          severity: InfoBarSeverity.info,
          isLong: true,
        ),
        const SizedBox(height: 8),
        _ConfigRow(
          label: 'Position (rot → ${config.type.positionUnit})',
          child: SizedBox(
            width: 150,
            child: NumberBox<double>(
              value: config.positionConversionFactor,
              onChanged: (v) =>
                  configNotifier.setPositionConversionFactor(v ?? 1.0),
            ),
          ),
        ),
        _ConfigRow(
          label: 'Velocity (RPM → ${config.type.velocityUnit})',
          child: SizedBox(
            width: 150,
            child: NumberBox<double>(
              value: config.velocityConversionFactor,
              onChanged: (v) =>
                  configNotifier.setVelocityConversionFactor(v ?? 1.0),
            ),
          ),
        ),

        // Soft limits (only for arms and elevators)
        if (config.type.requiresSoftLimits) ...[
          const SizedBox(height: 24),
          const Text(
            'Soft Limits',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const InfoBar(
            title: Text('Required for safety'),
            content: Text(
              'Set the maximum and minimum travel positions in your chosen units. '
              'The motor will be stopped if it approaches these limits during testing.',
            ),
            severity: InfoBarSeverity.warning,
            isLong: true,
          ),
          const SizedBox(height: 8),
          _ConfigRow(
            label:
                'Forward Limit (${config.type.positionUnit})',
            child: SizedBox(
              width: 150,
              child: NumberBox<double>(
                value: config.forwardSoftLimit,
                onChanged: (v) {
                  if (v != null) configNotifier.setForwardSoftLimit(v);
                },
                placeholder: 'Max position',
              ),
            ),
          ),
          _ConfigRow(
            label:
                'Reverse Limit (${config.type.positionUnit})',
            child: SizedBox(
              width: 150,
              child: NumberBox<double>(
                value: config.reverseSoftLimit,
                onChanged: (v) {
                  if (v != null) configNotifier.setReverseSoftLimit(v);
                },
                placeholder: 'Min position',
              ),
            ),
          ),
        ],

        const SizedBox(height: 24),

        // Test parameters
        const Text(
          'Test Parameters',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        _ConfigRow(
          label: 'Quasistatic Ramp Rate (V/s)',
          child: SizedBox(
            width: 120,
            child: NumberBox<double>(
              value: testParams.quasistaticRampRate,
              min: 0.05,
              max: 2.0,
              onChanged: (v) =>
                  testParamsNotifier.setQuasistaticRampRate(v ?? 0.25),
            ),
          ),
        ),
        _ConfigRow(
          label: 'Dynamic Step Voltage (V)',
          child: SizedBox(
            width: 120,
            child: NumberBox<double>(
              value: testParams.dynamicStepVoltage,
              min: 1.0,
              max: 12.0,
              onChanged: (v) =>
                  testParamsNotifier.setDynamicStepVoltage(v ?? 7.0),
            ),
          ),
        ),
        _ConfigRow(
          label: 'Dynamic Step Duration (s)',
          child: SizedBox(
            width: 120,
            child: NumberBox<double>(
              value: testParams.dynamicStepDuration,
              min: 0.5,
              max: 10.0,
              onChanged: (v) =>
                  testParamsNotifier.setDynamicStepDuration(v ?? 2.0),
            ),
          ),
        ),
        _ConfigRow(
          label: 'Max Test Voltage (V)',
          child: SizedBox(
            width: 120,
            child: NumberBox<double>(
              value: testParams.maxTestVoltage,
              min: 2.0,
              max: 12.0,
              onChanged: (v) =>
                  testParamsNotifier.setMaxTestVoltage(v ?? 12.0),
            ),
          ),
        ),

        const SizedBox(height: 24),

        // Validation
        Builder(builder: (context) {
          final errors = config.validate();
          if (errors.isEmpty) {
            return const InfoBar(
              title: Text('Configuration valid'),
              content: Text('Ready to run tests.'),
              severity: InfoBarSeverity.success,
            );
          }
          return InfoBar(
            title: const Text('Configuration issues'),
            content: Text(errors.join('\n')),
            severity: InfoBarSeverity.error,
            isLong: true,
          );
        }),
      ],
    );
  }
}

class _ConfigRow extends StatelessWidget {
  final String label;
  final Widget child;

  const _ConfigRow({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 280,
            child: Text(label),
          ),
          child,
        ],
      ),
    );
  }
}
