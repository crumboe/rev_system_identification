/// Configuration screen: mechanism type, units, soft limits,
/// motor settings, and test parameters.
library;

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../can/spark_protocol.dart';

import '../tutorials/tutorial_keys.dart';
import '../../devices/device_manager.dart';
import '../../mechanisms/mechanism.dart';
import '../../state/app_state.dart';
import '../widgets/arm_visual.dart';
import '../widgets/concept_panel.dart';
import '../widgets/elevator_visual.dart';
import '../widgets/expression_field.dart';
import '../widgets/jog_panel.dart';
import '../widgets/logo_header.dart';

class ConfigScreen extends ConsumerStatefulWidget {
  const ConfigScreen({super.key});

  @override
  ConsumerState<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends ConsumerState<ConfigScreen> {
  double _currentPosition = 0.0;
  Timer? _positionTimer;
  bool _didLoadFromDevice = false;

  @override
  void initState() {
    super.initState();
    _positionTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _pollPosition(),
    );
    _maybeLoadConfigFromDevice();
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    super.dispose();
  }

  /// Attempt to load config from device once after the screen is shown.
  void _maybeLoadConfigFromDevice() {
    if (_didLoadFromDevice) return;
    final device = ref.read(deviceManagerProvider).leader;
    if (device != null && device.isConnected && !device.isSimulated) {
      _didLoadFromDevice = true;
      _loadConfigFromDevice(device);
    }
  }

  /// Read motor/sensor configuration from the connected SPARK and
  /// populate the mechanism config state so the UI matches the device.
  Future<void> _loadConfigFromDevice(SparkDevice device) async {
    final notifier = ref.read(mechanismConfigProvider.notifier);
    const readDelay = Duration(milliseconds: 50);
    try {
      final motorType = await device.parameters.getParameter(kParamMotorType);
      await Future<void>.delayed(readDelay);
      final inverted = await device.parameters.getParameter(kParamMotorInverted);
      await Future<void>.delayed(readDelay);
      final currentLimit = await device.parameters.getParameter(kParamSmartCurrentLimit);
      await Future<void>.delayed(readDelay);
      final sensorVal = await device.parameters.getParameter(kParamClosedLoopControlSensor);
      await Future<void>.delayed(readDelay);
      final pcf = await device.parameters.getPositionConversionFactor();
      await Future<void>.delayed(readDelay);
      final vcf = await device.parameters.getVelocityConversionFactor();

      notifier.setIsBrushless(motorType >= 0.5);
      notifier.setMotorInverted(inverted >= 0.5);
      if (currentLimit > 0) notifier.setCurrentLimit(currentLimit);
      notifier.setFeedbackSensor(
        switch (sensorVal.round()) {
          0 => FeedbackSensor.analogSensor,
          2 => FeedbackSensor.absoluteEncoder,
          _ => FeedbackSensor.primaryEncoder,
        },
      );
      if (pcf != 0) notifier.setPositionConversionFactor(pcf);
      if (vcf != 0) notifier.setVelocityConversionFactor(vcf);
    } catch (_) {
      // Device communication failed — leave defaults in place.
    }
  }

  void _pollPosition() {
    final device = ref.read(deviceManagerProvider).leader;
    if (device == null || !device.isConnected) return;

    // Load device config once when a real device connects.
    _maybeLoadConfigFromDevice();

    final config = ref.read(mechanismConfigProvider);

    double rawPos;
    if (config.feedbackSensor == FeedbackSensor.absoluteEncoder) {
      rawPos = device.connection.lastStatus5?.absoluteEncoderPosition ??
          (device.connection.lastStatus2?.positionRotations ?? 0.0);
    } else if (config.feedbackSensor == FeedbackSensor.analogSensor) {
      rawPos = device.connection.lastStatus3?.analogPosition ??
          (device.connection.lastStatus2?.positionRotations ?? 0.0);
    } else {
      rawPos = device.connection.lastStatus2?.positionRotations ?? 0.0;
    }
    // Status frames already report in user units (onboard CFs).
    final pos = rawPos;
    if ((pos - _currentPosition).abs() > 0.01) {
      setState(() => _currentPosition = pos);
    }
  }

  Future<void> _zeroAbsoluteEncoder() async {
    final device = ref.read(deviceManagerProvider).leader;
    if (device == null || !device.isConnected) return;

    // Read the raw absolute encoder position and write it as the offset
    // so the current position becomes zero.
    final rawPos =
        device.connection.lastStatus5?.absoluteEncoderPosition ?? 0.0;
    await device.parameters.setParameter(kParamDutyCycleOffset, rawPos);
    await device.parameters.burnFlash(heartbeat: device.heartbeat);

    if (mounted) {
      setState(() => _currentPosition = 0.0);
      await displayInfoBar(context, builder: (ctx, close) {
        return InfoBar(
          title: const Text('Encoder Zeroed'),
          content: Text(
            'Absolute encoder offset set to ${rawPos.toStringAsFixed(4)}. '
            'Current position is now 0.',
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

  Future<void> _zeroEncoder() async {
    final device = ref.read(deviceManagerProvider).leader;
    if (device == null || !device.isConnected) return;
    final config = ref.read(mechanismConfigProvider);

    if (config.feedbackSensor == FeedbackSensor.absoluteEncoder) {
      await _zeroAbsoluteEncoder();
    } else {
      // Primary (relative) encoder: send a "set encoder position to 0"
      // control command so the firmware resets its accumulator.
      device.control.setEncoderPosition(0.0);

      if (mounted) {
        setState(() => _currentPosition = 0.0);
        await displayInfoBar(context, builder: (ctx, close) {
          return InfoBar(
            title: const Text('Encoder Zeroed'),
            content: const Text(
              'Primary encoder position reset to 0.',
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
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(mechanismConfigProvider);
    final configNotifier = ref.read(mechanismConfigProvider.notifier);
    final testParamsNotifier = ref.read(testParamsProvider.notifier);
    final testParams = ref.watch(testParamsProvider);
    final dm = ref.watch(deviceManagerProvider);
    final device = dm.leader;
    final isConnected = device != null && device.isConnected;

    return ScaffoldPage.scrollable(
      header: const LogoPageHeader(title: 'Configuration'),
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
                'soft limits or conversion factors are '
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
          key: TutorialKeys.mechanismTypeSelector,
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
              if (v != null) {
                configNotifier.setIsBrushless(v);
                device?.parameters.setParameter(
                    kParamMotorType, v ? 1.0 : 0.0);
              }
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
            onChanged: (v) {
              configNotifier.setMotorInverted(v);
              device?.parameters.setParameter(
                  kParamMotorInverted, v ? 1.0 : 0.0);
            },
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
              onChanged: (v) {
                final amps = v ?? 40.0;
                configNotifier.setCurrentLimit(amps);
                device?.parameters.setParameter(
                    kParamSmartCurrentLimit, amps);
              },
            ),
          ),
        ),
        _ConfigRow(
          key: TutorialKeys.encoderConfigSection,
          label: 'Feedback Sensor',
          child: ComboBox<FeedbackSensor>(
            value: config.feedbackSensor,
            items: FeedbackSensor.values.map((s) {
              return ComboBoxItem<FeedbackSensor>(
                value: s,
                child: Text(s.displayName),
              );
            }).toList(),
            onChanged: (v) {
              if (v != null) {
                configNotifier.setFeedbackSensor(v);
                device?.parameters.setParameter(
                    kParamClosedLoopControlSensor,
                    v.parameterValue.toDouble());
              }
            },
          ),
        ),

        const SizedBox(height: 24),

        // Conversion factors
        const Text(
          'Conversion Factors',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        InfoBar(
          title: const Text('How to calculate'),
          content: Text(
            _conversionFactorHelp(config),
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
            child: ExpressionField(
              key: TutorialKeys.conversionFactorField,
              value: config.positionConversionFactor,
              placeholder: _positionCfPlaceholder(config),
              onChanged: (v) {
                configNotifier.setPositionConversionFactor(v);
                device?.parameters.setPositionConversionFactor(v);
              },
            ),
          ),
        ),
        _ConfigRow(
          label: 'Velocity (RPM → ${config.velocityUnit})',
          child: SizedBox(
            width: 210,
            child: ExpressionField(
              value: config.velocityConversionFactor,
              placeholder: _velocityCfPlaceholder(config),
              onChanged: (v) {
                configNotifier.setVelocityConversionFactor(v);
                device?.parameters.setVelocityConversionFactor(v);
              },
            ),
          ),
        ),
        // Soft limits
        const SizedBox(height: 24),
        Text(
          key: TutorialKeys.softLimitsSection,
          'Soft Limits',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        InfoBar(
          title: Text(config.type.requiresSoftLimits
              ? 'Required for safety'
              : 'Optional'),
          content: Text(
            config.type.requiresSoftLimits
                ? 'Set the maximum and minimum travel positions in your chosen units. '
                  'The motor will be stopped if it approaches these limits during testing.'
                : 'Soft limits are optional for this mechanism type but recommended if '
                  'you have mechanical travel limits. The motor will be stopped if it '
                  'approaches these limits during testing.',
          ),
          severity: config.type.requiresSoftLimits
              ? InfoBarSeverity.warning
              : InfoBarSeverity.info,
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
                if (v != null) {
                    configNotifier.setForwardSoftLimit(v);
                    device?.parameters.setForwardSoftLimit(v);
                    device?.parameters.setForwardSoftLimitEnabled(true);
                  }
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
                if (v != null) {
                    configNotifier.setReverseSoftLimit(v);
                    device?.parameters.setReverseSoftLimit(v);
                    device?.parameters.setReverseSoftLimitEnabled(true);
                  }
              },
              placeholder: 'Min position',
            ),
          ),
        ),
        if (config.type.requiresSoftLimits) ...[
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
                    'Set Conversion Factors to match your '
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
        ],

        // Mechanism visual + jog panel + zero encoder
        if (isConnected) ...[
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Mechanism visual (arm or elevator)
              if (config.type == MechanismType.arm)
                SizedBox(
                  width: 280,
                  height: 320,
                  child: ArmVisual(
                    currentAngleDeg: _currentPosition,
                    forwardLimitDeg: config.forwardSoftLimit,
                    reverseLimitDeg: config.reverseSoftLimit,
                  ),
                ),
              if (config.type == MechanismType.elevator)
                SizedBox(
                  width: 280,
                  height: 320,
                  child: ElevatorVisual(
                    currentPosition: _currentPosition,
                    forwardLimit: config.forwardSoftLimit,
                    reverseLimit: config.reverseSoftLimit,
                    unitLabel:
                        config.useImperialUnits ? 'in' : 'm',
                  ),
                ),
              if (config.type == MechanismType.arm ||
                  config.type == MechanismType.elevator)
                const SizedBox(width: 12),
              // Jog + zero encoder
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    JogPanel(
                      key: TutorialKeys.jogControls,
                      device: device,
                      config: config,
                      onSetForwardLimit: (pos) {
                          configNotifier.setForwardSoftLimit(pos);
                            device?.parameters.setForwardSoftLimit(pos);
                            device?.parameters.setForwardSoftLimitEnabled(true);
                        },
                      onSetReverseLimit: (pos) {
                          configNotifier.setReverseSoftLimit(pos);
                            device?.parameters.setReverseSoftLimit(pos);
                            device?.parameters.setReverseSoftLimitEnabled(true);
                        },
                      onPositionChanged: (pos) =>
                          setState(() => _currentPosition = pos),
                    ),
                    const SizedBox(height: 12),
                    _ZeroEncoderCard(
                      currentPosition: _currentPosition,
                      positionUnit: config.positionUnit,
                      feedbackSensor: config.feedbackSensor,
                      onZero: _zeroEncoder,
                    ),
                  ],
                ),
              ),
            ],
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

String _conversionFactorHelp(MechanismConfig config) {
  final isFlywheel = config.type == MechanismType.flywheel ||
      config.type == MechanismType.simple;
  final isArm = config.type == MechanismType.arm;
  final isElevator = config.type == MechanismType.elevator;
  final posUnit = config.positionUnit;
  final velUnit = config.velocityUnit;

  if (isFlywheel) {
    return 'Flywheel/Simple mechanisms typically stay in native encoder units.\n\n'
        'Motor encoder (on motor shaft):\n'
        '  Position factor = 1  (rotations \u2192 rotations)\n'
        '  Velocity factor = 1  (RPM \u2192 RPM)\n\n'
        'External encoder (on output shaft):\n'
        '  Factors are still 1 since encoder reads output directly.\n\n'
        'If you use a gear ratio and want output units, set:\n'
        '  Position factor = 1 / gear_ratio\n'
        '  Velocity factor = 1 / gear_ratio';
  }

  if (isArm) {
    return 'Arm mechanisms convert to $posUnit and $velUnit.\n\n'
        'Motor encoder (on motor shaft):\n'
        '  Position factor = 360 / gear_ratio\n'
        '  Velocity factor = 6 / gear_ratio\n'
        '  Example \u2014 50:1 gearbox:\n'
        '    Position = 360 / 50 = 7.2  (rot \u2192 deg)\n'
        '    Velocity = 6 / 50 = 0.12  (RPM \u2192 deg/s)\n\n'
        'Absolute encoder (on output shaft):\n'
        '  Position factor = 360  (1 rotation = 360\u00b0)\n'
        '  Velocity factor = 6  (1 RPM = 6 deg/s)';
  }

  if (isElevator) {
    final unit = config.useImperialUnits ? 'inches' : 'meters';
    return 'Elevator mechanisms convert to $unit.\n\n'
        'Motor encoder (on motor shaft):\n'
        '  Position factor = spool_circumference / gear_ratio\n'
        '  Velocity factor = position_factor / 60\n'
        '  Example \u2014 2" spool, 25:1 gearbox:\n'
        '    Circumference = 2 \u00d7 \u03c0 \u2248 6.283 in\n'
        '    Position = 6.283 / 25 = 0.2513  (rot \u2192 in)\n'
        '    Velocity = 0.2513 / 60 = 0.00419  (RPM \u2192 in/s)\n\n'
        'Absolute encoder (on output shaft):\n'
        '  Position factor = spool_circumference\n'
        '  Velocity factor = spool_circumference / 60';
  }

  return 'Set the conversion factors for your mechanism.';
}

String _positionCfPlaceholder(MechanismConfig config) {
  return switch (config.type) {
    MechanismType.flywheel || MechanismType.simple => '1  (rotations)',
    MechanismType.arm => 'e.g. 360/50  (rot \u2192 deg)',
    MechanismType.elevator => 'e.g. 6.283/25  (rot \u2192 ${config.positionUnit})',
  };
}

String _velocityCfPlaceholder(MechanismConfig config) {
  return switch (config.type) {
    MechanismType.flywheel || MechanismType.simple => '1  (RPM)',
    MechanismType.arm => 'e.g. 6/50  (RPM \u2192 deg/s)',
    MechanismType.elevator => 'e.g. 6.283/25/60  (RPM \u2192 ${config.velocityUnit})',
  };
}

class _ConfigRow extends StatelessWidget {
  final String label;
  final Widget child;

  const _ConfigRow({super.key, required this.label, required this.child});

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

class _ZeroEncoderCard extends StatelessWidget {
  final double currentPosition;
  final String positionUnit;
  final FeedbackSensor feedbackSensor;
  final VoidCallback onZero;

  const _ZeroEncoderCard({
    required this.currentPosition,
    required this.positionUnit,
    required this.feedbackSensor,
    required this.onZero,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final isAbsolute = feedbackSensor == FeedbackSensor.absoluteEncoder;
    final title = isAbsolute ? 'Zero Absolute Encoder' : 'Zero Encoder';
    final description = isAbsolute
        ? 'Jog the mechanism to its desired zero position, then press '
          'the button below to set the absolute encoder offset so this '
          'position reads as 0.'
        : 'Jog the mechanism to its desired zero position, then press '
          'the button below to reset the encoder so this position '
          'reads as 0.';
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FluentIcons.location, size: 14),
              const SizedBox(width: 6),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Current position: '
            '${currentPosition.toStringAsFixed(2)} $positionUnit',
            style: TextStyle(
              fontFamily: 'Consolas',
              fontSize: 12,
              color: theme.accentColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: TextStyle(
              fontSize: 11,
              color: theme.typography.body?.color?.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: onZero,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.reset, size: 14),
                SizedBox(width: 6),
                Text('Set Current Position as Zero'),
              ],
            ),
          ),
        ],
      ),
    );
  }
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
