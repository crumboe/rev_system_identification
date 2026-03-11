/// Configuration screen: mechanism type, gear ratio, units, soft limits,
/// motor settings, and test parameters.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../mechanisms/mechanism.dart';
import '../../state/app_state.dart';
import '../widgets/concept_panel.dart';
import '../widgets/jog_panel.dart';

class ConfigScreen extends ConsumerWidget {
  const ConfigScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(mechanismConfigProvider);
    final configNotifier = ref.read(mechanismConfigProvider.notifier);
    final testParamsNotifier = ref.read(testParamsProvider.notifier);
    final testParams = ref.watch(testParamsProvider);
    final dm = ref.watch(deviceManagerProvider);
    final device = dm.leader;
    final isConnected = device != null && device.isConnected;

    return ScaffoldPage.scrollable(
      header: const PageHeader(title: Text('Configuration')),
      children: [
        // Hardware damage warning for gravity-loaded mechanisms
        if (config.type.requiresSoftLimits &&
            device != null &&
            !device.isSimulated)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: InfoBar(
              title: const Text('\u26A0 Hardware Damage Risk'),
              content: const Text(
                'Arms and elevators can cause damage to your robot if '
                'soft limits, gear ratios, or conversion factors are '
                'incorrect. Always physically support the mechanism '
                'before powering the motor. Use the Jog controls '
                'below to verify motion direction and limits before '
                'running any test.',
              ),
              severity: InfoBarSeverity.error,
              isLong: true,
            ),
          ),

        // System name
        const Text(
          'System Name',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const InfoBar(
          title: Text('Identify your system'),
          content: Text(
            'Give this setup a name (e.g. "2026 Shooter Flywheel" or '
            '"Elevator Prototype v2"). This name appears in the PDF report '
            'header and filename.',
          ),
          severity: InfoBarSeverity.info,
          isLong: true,
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: 400,
          child: _SystemNameField(
            initial: config.systemName,
            onChanged: (v) => configNotifier.setSystemName(v),
          ),
        ),

        const SizedBox(height: 24),

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
            'Units: ${config.positionUnit} / ${config.velocityUnit}',
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
            width: 180,
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
            width: 180,
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
            'The correct values depend on your encoder placement:\n\n'
            'Motor built-in (relative) encoder:\n'
            '  Position factor = (mechanism travel per motor rev) / gear_ratio\n'
            '  Velocity factor = position_factor / 60\n'
            '  Example arm with 100:1 total reduction:\n'
            '    Position = 360 / 100 = 3.6 deg/rot\n'
            '    Velocity = 3.6 / 60 = 0.06 deg/s per RPM\n\n'
            'Remote absolute encoder (e.g. through-bore on output shaft):\n'
            '  Position factor = full-scale travel (360 for arm, spool circumference for elevator)\n'
            '  Velocity factor = position_factor / 60\n'
            '  Gear ratio should be set to 1 since the encoder already reads output.',
          ),
          severity: InfoBarSeverity.info,
          isLong: true,
        ),
        const SizedBox(height: 8),
        if (config.type == MechanismType.elevator)
          _ConfigRow(
            label: 'Use Imperial Units (inches)',
            child: ToggleSwitch(
              checked: config.useImperialUnits,
              onChanged: (v) => configNotifier.setUseImperialUnits(v),
              content: Text(config.useImperialUnits ? 'Inches' : 'Meters'),
            ),
          ),
        _ConfigRow(
          label: 'Position (rot → ${config.positionUnit})',
          child: SizedBox(
            width: 210,
            child: NumberBox<double>(
              value: config.positionConversionFactor,
              onChanged: (v) =>
                  configNotifier.setPositionConversionFactor(v ?? 1.0),
            ),
          ),
        ),
        _ConfigRow(
          label: 'Velocity (RPM → ${config.velocityUnit})',
          child: SizedBox(
            width: 210,
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
                'Forward Limit (${config.positionUnit})',
            child: SizedBox(
              width: 210,
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
                'Reverse Limit (${config.positionUnit})',
            child: SizedBox(
              width: 210,
              child: NumberBox<double>(
                value: config.reverseSoftLimit,
                onChanged: (v) {
                  if (v != null) configNotifier.setReverseSoftLimit(v);
                },
                placeholder: 'Min position',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Expander(
            header: const Text('Safe Operation Guide'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _guideStep(1,
                    'Physically support the mechanism so it cannot '
                    'fall when power is removed.'),
                _guideStep(2,
                    'Connect the device and open this Configuration page.'),
                _guideStep(3,
                    'Set Gear Ratio and Conversion Factors to match your '
                    'mechanical design.'),
                _guideStep(4,
                    'Use Jog Forward at LOW voltage (≤1 V) to verify '
                    'the motor moves in the expected direction. '
                    'If it moves the wrong way, enable Motor Inverted.'),
                _guideStep(5,
                    'Jog to each end of travel and press '
                    '"Set Limit Here". Set limits 5–10% inside the '
                    'true mechanical stops to provide a safety margin.'),
                _guideStep(6,
                    'Enable Current Trip Protection (30 A default) '
                    'to auto-stop if the motor stalls against a hard stop.'),
                _guideStep(7,
                    'Start with a low Max Test Voltage (4–6 V) for your '
                    'first test run. Only increase after confirming safe '
                    'operation.'),
              ],
            ),
          ),

          // Jog panel for mechanisms with soft limits
          if (isConnected) ...[
            const SizedBox(height: 12),
            JogPanel(
              device: device,
              config: config,
              onSetForwardLimit: (pos) =>
                  configNotifier.setForwardSoftLimit(pos),
              onSetReverseLimit: (pos) =>
                  configNotifier.setReverseSoftLimit(pos),
            ),
          ],
        ],

        // Jog panel for flywheels (no soft limits section, show standalone)
        if (!config.type.requiresSoftLimits && isConnected) ...[
          const SizedBox(height: 16),
          const Text(
            'Manual Jog',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          JogPanel(
            device: device,
            config: config,
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
            width: 180,
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
            width: 180,
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
            width: 180,
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
            width: 180,
            child: NumberBox<double>(
              value: testParams.maxTestVoltage,
              min: 2.0,
              max: 12.0,
              onChanged: (v) =>
                  testParamsNotifier.setMaxTestVoltage(v ?? 12.0),
            ),
          ),
        ),
        const SizedBox(height: 8),
        _ConfigRow(
          label: 'Current Trip Protection',
          child: Row(
            children: [
              ToggleSwitch(
                checked: testParams.currentTripAmps != null,
                onChanged: (on) {
                  testParamsNotifier.setCurrentTripAmps(on ? 30.0 : null);
                },
              ),
              if (testParams.currentTripAmps != null) ...[
                const SizedBox(width: 12),
                SizedBox(
                  width: 160,
                  child: NumberBox<double>(
                    value: testParams.currentTripAmps,
                    min: 5.0,
                    max: 80.0,
                    onChanged: (v) =>
                        testParamsNotifier.setCurrentTripAmps(v ?? 30.0),
                  ),
                ),
                const SizedBox(width: 6),
                const Text('A'),
              ],
            ],
          ),
        ),
        if (testParams.currentTripAmps != null)
          const Padding(
            padding: EdgeInsets.only(left: 280, top: 2),
            child: Text(
              'Auto-stops the test if motor current exceeds this '
              'threshold for ~50ms. Detects hard-stop collisions and stalls.',
              style: TextStyle(fontSize: 11),
            ),
          ),
        if (testParams.currentTripAmps == null &&
            config.type != MechanismType.flywheel)
          Padding(
            padding: const EdgeInsets.only(left: 280, top: 2),
            child: Text(
              'Consider enabling for mechanisms with mechanical travel limits.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.warningPrimaryColor,
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

        const SizedBox(height: 16),
        const ConceptPanel(),
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

Widget _guideStep(int number, String text) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 24,
          child: Text(
            '$number.',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
      ],
    ),
  );
}

class _SystemNameField extends StatefulWidget {
  final String initial;
  final ValueChanged<String> onChanged;

  const _SystemNameField({required this.initial, required this.onChanged});

  @override
  State<_SystemNameField> createState() => _SystemNameFieldState();
}

class _SystemNameFieldState extends State<_SystemNameField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextBox(
      placeholder: 'e.g. 2026 Shooter Flywheel',
      controller: _controller,
      onChanged: widget.onChanged,
    );
  }
}
