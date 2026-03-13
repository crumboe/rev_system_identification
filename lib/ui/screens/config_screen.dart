/// Configuration screen: mechanism type, units, soft limits,
/// motor settings, and test parameters.
library;

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../can/spark_protocol.dart';
import '../../data/test_data.dart';
import '../../devices/device_manager.dart';
import '../../mechanisms/mechanism.dart';
import '../../state/app_state.dart';
import '../widgets/arm_visual.dart';
import '../widgets/concept_panel.dart';
import '../widgets/elevator_visual.dart';
import '../widgets/expression_field.dart';
import '../widgets/jog_panel.dart';

class ConfigScreen extends ConsumerStatefulWidget {
  const ConfigScreen({super.key});

  @override
  ConsumerState<ConfigScreen> createState() => _ConfigScreenState();
}

class _ConfigScreenState extends ConsumerState<ConfigScreen> {
  double _currentPosition = 0.0;
  Timer? _positionTimer;
  bool _didLoadFromDevice = false;
  late TextEditingController _armSpecCtrl;

  @override
  void initState() {
    super.initState();
    _armSpecCtrl = TextEditingController();
    _positionTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _pollPosition(),
    );
    _maybeLoadConfigFromDevice();
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _armSpecCtrl.dispose();
    super.dispose();
  }

  ({double massLbs, double lengthIn})? _parseArmSpec(String input) {
    final text = input.toLowerCase();
    final numberRegex = RegExp(r'[-+]?\d*\.?\d+');

    final lbRegex = RegExp(r'([-+]?\d*\.?\d+)\s*(lb|lbs|pound|pounds)');
    final inRegex = RegExp(r'([-+]?\d*\.?\d+)\s*(in|inch|inches)');

    double? massLbs;
    double? lengthIn;

    final lbMatch = lbRegex.firstMatch(text);
    if (lbMatch != null) {
      massLbs = double.tryParse(lbMatch.group(1)!);
    }

    final inMatch = inRegex.firstMatch(text);
    if (inMatch != null) {
      lengthIn = double.tryParse(inMatch.group(1)!);
    }

    if (massLbs == null || lengthIn == null) {
      final nums = numberRegex
          .allMatches(text)
          .map((m) => double.tryParse(m.group(0)!))
          .whereType<double>()
          .toList();
      if (nums.length >= 2) {
        massLbs ??= nums[0];
        lengthIn ??= nums[1];
      }
    }

    if (massLbs == null || lengthIn == null) return null;
    if (massLbs <= 0 || lengthIn <= 0) return null;
    return (massLbs: massLbs, lengthIn: lengthIn);
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

  Future<void> _refreshProjectSimulationIfNeeded() async {
    final dm = ref.read(deviceManagerProvider);
    final device = dm.leader;
    // Refresh any simulated device (project-backed OR generic) so arm-spec
    // changes take effect regardless of how the simulation was connected.
    if (device == null || !device.isSimulated) {
      return;
    }

    final config = ref.read(mechanismConfigProvider);
    // Use identified gains when available; fall back to built-in physics
    // defaults so arm-spec scaling works even before any sysid run.
    final gains =
        ref.read(feedforwardGainsProvider) ?? _referenceGainsForConfig(config);

    dm.disconnect(device);
    await dm.connectSimulatedFromProject(gains: gains, config: config);
  }

  /// Reference feedforward gains representing the built-in simulation
  /// defaults, converted to "identified-unit" space (the same units that
  /// FeedforwardAnalyzer produces from test data).
  ///
  /// Used when no project gains have been identified yet so that arm-spec
  /// scaling produces a physically-meaningful simulation.
  FeedforwardGains _referenceGainsForConfig(MechanismConfig config) {
    final vcf = config.velocityConversionFactor;
    final pcf = config.positionConversionFactor;
    return switch (config.type) {
      // ArmPhysics defaults: kS≈0.20, kV≈0.018 V·s/deg, kA≈0.002 V·s²/deg,
      // kG≈0.80. Reported velocity = ω_deg * VCF/6, so kA_id = kA * 6/VCF.
      MechanismType.arm => () {
          final inv = vcf > 0 ? 6.0 / vcf : 1.0;
          return FeedforwardGains(
            kS: 0.20,
            kV: 0.018 * inv,
            kA: 0.002 * inv,
            kG: 0.80,
          );
        }(),
      // ElevatorPhysics defaults: kS≈0.18, kV≈0.12 V·s/in, kA≈0.015, kG≈0.55.
      // Scale = VCF*60/PCF; identified kA_id = kA_physics / scale.
      MechanismType.elevator => () {
          final scale =
              (vcf > 0 && pcf > 0) ? vcf * 60.0 / pcf : 1.0;
          final inv = scale > 0 ? 1.0 / scale : 1.0;
          return FeedforwardGains(
            kS: 0.18,
            kV: 0.12 * inv,
            kA: 0.015 * inv,
            kG: 0.55,
          );
        }(),
      // FlywheelPhysics defaults: kS≈0.14, kV≈0.0185 V/RPM, kA≈0.003 V/(RPM/s).
      // Scale = VCF; identified kA_id = kA_physics / VCF.
      MechanismType.flywheel || MechanismType.simple => () {
          final inv = vcf > 0 ? 1.0 / vcf : 1.0;
          return FeedforwardGains(
            kS: 0.14,
            kV: 0.0185 * inv,
            kA: 0.003 * inv,
            kG: 0.0,
          );
        }(),
    };
  }

  Future<void> _applyArmSpecText(MechanismConfigNotifier configNotifier) async {
    final parsed = _parseArmSpec(_armSpecCtrl.text.trim());
    if (parsed == null) {
      if (!mounted) return;
      await displayInfoBar(context, builder: (ctx, close) {
        return InfoBar(
          title: const Text('Could not parse arm spec'),
          content: const Text(
            'Try a format like "10 lbs, 20 inches".',
          ),
          severity: InfoBarSeverity.warning,
          action: IconButton(
            icon: const Icon(FluentIcons.clear),
            onPressed: close,
          ),
        );
      });
      return;
    }

    configNotifier.setSimulatedArmSpec(
      massLbs: parsed.massLbs,
      lengthIn: parsed.lengthIn,
    );

    await _refreshProjectSimulationIfNeeded();

    // Clear test runs collected under the old physics so feedforward analysis
    // only uses data from the current arm spec.
    ref.read(testRunsProvider.notifier).clear();

    final cfg = ref.read(mechanismConfigProvider);
    final scales = _armDynamicScales(cfg);

    if (!mounted) return;
    await displayInfoBar(context, builder: (ctx, close) {
      return InfoBar(
        title: const Text('Arm simulation spec applied'),
        content: Text(
          'Mass ${parsed.massLbs.toStringAsFixed(1)} lb, length '
          '${parsed.lengthIn.toStringAsFixed(1)} in. '
          '${scales != null ? '(kA×${scales.kAScale.toStringAsFixed(2)}, '
          'kG×${scales.kGScale.toStringAsFixed(2)}, '
          'kS×${scales.kSScale.toStringAsFixed(2)}) ' : ''}'
          'Previous test data cleared — re-run tests to identify new gains.',
        ),
        severity: InfoBarSeverity.success,
        action: IconButton(
          icon: const Icon(FluentIcons.clear),
          onPressed: close,
        ),
      );
    });
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
        sensorVal >= 1.5
            ? FeedbackSensor.absoluteEncoder
            : FeedbackSensor.primaryEncoder,
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
        if (config.type == MechanismType.arm) ...[
          const SizedBox(height: 8),
          _ConfigRow(
            label: 'Sim Arm Spec (NL)',
            child: SizedBox(
              width: 460,
              child: Row(
                children: [
                  Expanded(
                    child: TextBox(
                      controller: _armSpecCtrl,
                      placeholder: 'e.g. 10 lbs, 20 inches',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    onPressed: () => _applyArmSpecText(configNotifier),
                    child: const Text('Apply'),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    onPressed: () {
                      configNotifier.setSimulatedArmSpec(
                        massLbs: null,
                        lengthIn: null,
                      );
                    },
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
          ),
          _ConfigRow(
            label: 'Computed Dynamics',
            child: Builder(
              builder: (_) {
                final scales = _armDynamicScales(config);
                return Text(
                  scales == null
                      ? 'kA x1.00, kG x1.00, kS x1.00'
                      : 'kA x${scales.kAScale.toStringAsFixed(2)}, '
                          'kG x${scales.kGScale.toStringAsFixed(2)}, '
                          'kS x${scales.kSScale.toStringAsFixed(2)}',
                );
              },
            ),
          ),
          _ConfigRow(
            label: 'Current Sim Spec',
            child: Text(
              (config.simulatedArmMassLbs != null &&
                      config.simulatedArmLengthIn != null)
                  ? '${config.simulatedArmMassLbs!.toStringAsFixed(1)} lb, '
                      '${config.simulatedArmLengthIn!.toStringAsFixed(1)} in'
                  : 'Using identified-gain heuristic',
            ),
          ),
        ],

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

          // Mechanism visual + jog panel for arms/elevators
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
                const SizedBox(width: 12),
                // Jog + zero encoder
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      JogPanel(
                        device: device,
                        config: config,
                        onSetForwardLimit: (pos) =>
                            configNotifier.setForwardSoftLimit(pos),
                        onSetReverseLimit: (pos) =>
                            configNotifier.setReverseSoftLimit(pos),
                        onPositionChanged: (pos) =>
                            setState(() => _currentPosition = pos),
                      ),
                      if (config.feedbackSensor ==
                          FeedbackSensor.absoluteEncoder) ...[
                        const SizedBox(height: 12),
                        _ZeroEncoderCard(
                          currentPosition: _currentPosition,
                          positionUnit: config.positionUnit,
                          onZero: _zeroAbsoluteEncoder,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
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

class _ZeroEncoderCard extends StatelessWidget {
  final double currentPosition;
  final String positionUnit;
  final VoidCallback onZero;

  const _ZeroEncoderCard({
    required this.currentPosition,
    required this.positionUnit,
    required this.onZero,
  });

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(FluentIcons.location, size: 14),
              const SizedBox(width: 6),
              const Text(
                'Zero Absolute Encoder',
                style: TextStyle(
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
            'Jog the mechanism to its desired zero position, then press '
            'the button below to set the absolute encoder offset so this '
            'position reads as 0.',
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
