/// Device parameter configuration screen mirroring the REV Hardware Client 2.
///
/// Reads all writable parameters from the connected SPARK MAX/Flex,
/// presents them in categorised tabs, writes each parameter immediately
/// on UI change, and provides a "Save to Flash" button for persistence.
library;

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../can/parameter_api.dart';
import '../../can/spark_protocol.dart';
import '../../devices/device_manager.dart';
import '../../mechanisms/mechanism.dart';
import '../../state/app_state.dart';
import '../widgets/logo_header.dart';

// ---------------------------------------------------------------------------
// Parameter descriptor model
// ---------------------------------------------------------------------------

enum ParamType { decimal, integer, boolean, dropdown }

class ParamDef {
  final int id;
  final String name;
  final ParamType type;
  final Map<int, String>? options;
  final double? min;
  final double? max;
  final String? unit;
  final String? tooltip;

  const ParamDef({
    required this.id,
    required this.name,
    required this.type,
    this.options,
    this.min,
    this.max,
    this.unit,
    this.tooltip,
  });
}

class ParamCategory {
  final String name;
  final List<ParamDef> params;

  const ParamCategory({required this.name, required this.params});
}

// ---------------------------------------------------------------------------
// All parameter categories (mirrors REV Hardware Client 2 tabs)
// ---------------------------------------------------------------------------

const _categories = <ParamCategory>[
  ParamCategory(name: 'Basic', params: [
    ParamDef(
      id: kParamMotorType,
      name: 'Motor Type',
      type: ParamType.dropdown,
      options: {0: 'BRUSHED', 1: 'BRUSHLESS'},
    ),
    ParamDef(
      id: kParamIdleMode,
      name: 'Idle Mode',
      type: ParamType.dropdown,
      options: {0: 'COAST', 1: 'BRAKE'},
    ),
    ParamDef(
      id: kParamInputDeadband,
      name: 'Input Deadband',
      type: ParamType.decimal,
      min: 0,
      max: 0.5,
    ),
    ParamDef(
      id: kParamMotorInverted,
      name: 'Inverted',
      type: ParamType.boolean,
    ),
    ParamDef(
      id: kParamOpenLoopRampRate,
      name: 'Open Loop Ramp Rate',
      type: ParamType.decimal,
      min: 0,
      max: 100,
      unit: 'setpoint/s',
    ),
  ]),
  ParamCategory(name: 'Motor Advanced', params: [
    ParamDef(
      id: kParamCurrentChop,
      name: 'Current Chop',
      type: ParamType.decimal,
      min: 0,
      max: 200,
      unit: 'A',
      tooltip: 'H-bridge current chop limit. 0 = disabled.',
    ),
    ParamDef(
      id: kParamCurrentChopCycles,
      name: 'Current Chop Cycles',
      type: ParamType.integer,
      min: 0,
      max: 255,
      tooltip: 'PWM cycles off after chop (x50 µs)',
    ),
    ParamDef(
      id: kParamCompensatedNominalVoltage,
      name: 'Voltage Compensation',
      type: ParamType.decimal,
      min: 0,
      max: 16,
      unit: 'V',
      tooltip: 'Compensated nominal voltage. 0 = disabled.',
    ),
    ParamDef(
      id: kParamClosedLoopRampRate,
      name: 'Closed Loop Ramp Rate',
      type: ParamType.decimal,
      min: 0,
      max: 100,
      unit: 's',
    ),
  ]),
  ParamCategory(name: 'Brushless', params: [
    ParamDef(
      id: kParamPolePairs,
      name: 'Pole Pairs',
      type: ParamType.integer,
      min: 1,
      max: 100,
      tooltip: 'NEO=7, NEO 550=7, Vortex=11',
    ),
  ]),
  ParamCategory(name: 'Current Limits', params: [
    ParamDef(
      id: kParamSmartCurrentLimit,
      name: 'Smart Current Stall Limit',
      type: ParamType.integer,
      min: 0,
      max: 80,
      unit: 'A',
    ),
    ParamDef(
      id: kParamSmartCurrentFreeLimit,
      name: 'Smart Current Free Limit',
      type: ParamType.integer,
      min: 0,
      max: 80,
      unit: 'A',
    ),
    ParamDef(
      id: kParamSmartCurrentConfig,
      name: 'Smart Current Config',
      type: ParamType.integer,
      min: 0,
      max: 65535,
      tooltip: 'RPM threshold for stall→free crossover',
    ),
  ]),
  ParamCategory(name: 'Closed Loop Control', params: [
    ParamDef(
      id: kParamPositionConvFactor,
      name: 'Position Conversion Factor',
      type: ParamType.decimal,
      min: 0,
      tooltip: 'Rotations → output units',
    ),
    ParamDef(
      id: kParamVelocityConvFactor,
      name: 'Velocity Conversion Factor',
      type: ParamType.decimal,
      min: 0,
      tooltip: 'RPM → output units',
    ),
  ]),
  ParamCategory(name: 'Closed Loop Slot 0', params: [
    ParamDef(id: kParamSlot0P, name: 'P', type: ParamType.decimal),
    ParamDef(id: kParamSlot0I, name: 'I', type: ParamType.decimal),
    ParamDef(id: kParamSlot0D, name: 'D', type: ParamType.decimal),
    ParamDef(id: kParamSlot0F, name: 'F (kV)', type: ParamType.decimal),
    ParamDef(id: kParamSlot0IZone, name: 'I Zone', type: ParamType.decimal),
    ParamDef(id: kParamSlot0DFilter, name: 'D Filter', type: ParamType.decimal),
    ParamDef(
      id: kParamSlot0MinOutput,
      name: 'Min Output',
      type: ParamType.decimal,
      min: -1,
      max: 1,
    ),
    ParamDef(
      id: kParamSlot0MaxOutput,
      name: 'Max Output',
      type: ParamType.decimal,
      min: -1,
      max: 1,
    ),
    ParamDef(id: kParamSlot0FfKs, name: 'FF kS', type: ParamType.decimal),
    ParamDef(id: kParamSlot0FfKa, name: 'FF kA', type: ParamType.decimal),
    ParamDef(id: kParamSlot0FfKg, name: 'FF kG', type: ParamType.decimal),
    ParamDef(id: kParamSlot0FfKcos, name: 'FF kCos', type: ParamType.decimal),
    ParamDef(
      id: kParamSlot0FfKcosRatio,
      name: 'FF kCos Ratio',
      type: ParamType.decimal,
    ),
    ParamDef(id: kParamIMaxAccum0, name: 'I Max Accum', type: ParamType.decimal),
    ParamDef(id: kParamAllowedClosedLoopError0, name: 'Allowed CL Error', type: ParamType.decimal),
    // MAXMotion Slot 0
    ParamDef(
      id: kParamMAXMotionCruiseVelocity0,
      name: 'MAXMotion Cruise Velocity',
      type: ParamType.decimal,
      unit: 'RPM',
    ),
    ParamDef(
      id: kParamMAXMotionMaxAccel0,
      name: 'MAXMotion Max Acceleration',
      type: ParamType.decimal,
      unit: 'RPM/s',
    ),
    ParamDef(
      id: kParamMAXMotionMaxJerk0,
      name: 'MAXMotion Max Jerk',
      type: ParamType.decimal,
      unit: 'RPM/s²',
      tooltip: '0 = trapezoidal profile',
    ),
    ParamDef(
      id: kParamMAXMotionAllowedError0,
      name: 'MAXMotion Allowed Error',
      type: ParamType.decimal,
      unit: 'rot',
    ),
    ParamDef(
      id: kParamMAXMotionPositionMode0,
      name: 'MAXMotion Position Mode',
      type: ParamType.dropdown,
      options: {0: 'Trapezoidal', 1: 'S-Curve'},
    ),
  ]),
  ParamCategory(name: 'Closed Loop Slot 1', params: [
    ParamDef(id: kParamSlot1P, name: 'P', type: ParamType.decimal),
    ParamDef(id: kParamSlot1I, name: 'I', type: ParamType.decimal),
    ParamDef(id: kParamSlot1D, name: 'D', type: ParamType.decimal),
    ParamDef(id: kParamSlot1F, name: 'F (kV)', type: ParamType.decimal),
    ParamDef(id: kParamSlot1IZone, name: 'I Zone', type: ParamType.decimal),
    ParamDef(id: kParamSlot1DFilter, name: 'D Filter', type: ParamType.decimal),
    ParamDef(
      id: kParamSlot1MinOutput,
      name: 'Min Output',
      type: ParamType.decimal,
      min: -1,
      max: 1,
    ),
    ParamDef(
      id: kParamSlot1MaxOutput,
      name: 'Max Output',
      type: ParamType.decimal,
      min: -1,
      max: 1,
    ),
    ParamDef(id: kParamSlot1FfKs, name: 'FF kS', type: ParamType.decimal),
    ParamDef(id: kParamSlot1FfKa, name: 'FF kA', type: ParamType.decimal),
    ParamDef(id: kParamSlot1FfKg, name: 'FF kG', type: ParamType.decimal),
    ParamDef(id: kParamSlot1FfKcos, name: 'FF kCos', type: ParamType.decimal),
    ParamDef(
      id: kParamSlot1FfKcosRatio,
      name: 'FF kCos Ratio',
      type: ParamType.decimal,
    ),
    ParamDef(id: kParamIMaxAccum1, name: 'I Max Accum', type: ParamType.decimal),
    ParamDef(id: kParamAllowedClosedLoopError1, name: 'Allowed CL Error', type: ParamType.decimal),
    // MAXMotion Slot 1
    ParamDef(
      id: kParamMAXMotionCruiseVelocity1,
      name: 'MAXMotion Cruise Velocity',
      type: ParamType.decimal,
      unit: 'RPM',
    ),
    ParamDef(
      id: kParamMAXMotionMaxAccel1,
      name: 'MAXMotion Max Acceleration',
      type: ParamType.decimal,
      unit: 'RPM/s',
    ),
    ParamDef(
      id: kParamMAXMotionMaxJerk1,
      name: 'MAXMotion Max Jerk',
      type: ParamType.decimal,
      unit: 'RPM/s²',
      tooltip: '0 = trapezoidal profile',
    ),
    ParamDef(
      id: kParamMAXMotionAllowedError1,
      name: 'MAXMotion Allowed Error',
      type: ParamType.decimal,
      unit: 'rot',
    ),
    ParamDef(
      id: kParamMAXMotionPositionMode1,
      name: 'MAXMotion Position Mode',
      type: ParamType.dropdown,
      options: {0: 'Trapezoidal', 1: 'S-Curve'},
    ),
  ]),
  ParamCategory(name: 'Closed Loop Slot 2', params: [
    ParamDef(id: kParamSlot2P, name: 'P', type: ParamType.decimal),
    ParamDef(id: kParamSlot2I, name: 'I', type: ParamType.decimal),
    ParamDef(id: kParamSlot2D, name: 'D', type: ParamType.decimal),
    ParamDef(id: kParamSlot2F, name: 'F (kV)', type: ParamType.decimal),
    ParamDef(id: kParamSlot2IZone, name: 'I Zone', type: ParamType.decimal),
    ParamDef(id: kParamSlot2DFilter, name: 'D Filter', type: ParamType.decimal),
    ParamDef(
      id: kParamSlot2MinOutput,
      name: 'Min Output',
      type: ParamType.decimal,
      min: -1,
      max: 1,
    ),
    ParamDef(
      id: kParamSlot2MaxOutput,
      name: 'Max Output',
      type: ParamType.decimal,
      min: -1,
      max: 1,
    ),
    ParamDef(id: kParamSlot2FfKs, name: 'FF kS', type: ParamType.decimal),
    ParamDef(id: kParamSlot2FfKa, name: 'FF kA', type: ParamType.decimal),
    ParamDef(id: kParamSlot2FfKg, name: 'FF kG', type: ParamType.decimal),
    ParamDef(id: kParamSlot2FfKcos, name: 'FF kCos', type: ParamType.decimal),
    ParamDef(
      id: kParamSlot2FfKcosRatio,
      name: 'FF kCos Ratio',
      type: ParamType.decimal,
    ),
    ParamDef(id: kParamIMaxAccum2, name: 'I Max Accum', type: ParamType.decimal),
    ParamDef(id: kParamAllowedClosedLoopError2, name: 'Allowed CL Error', type: ParamType.decimal),
    // MAXMotion Slot 2
    ParamDef(
      id: kParamMAXMotionCruiseVelocity2,
      name: 'MAXMotion Cruise Velocity',
      type: ParamType.decimal,
      unit: 'RPM',
    ),
    ParamDef(
      id: kParamMAXMotionMaxAccel2,
      name: 'MAXMotion Max Acceleration',
      type: ParamType.decimal,
      unit: 'RPM/s',
    ),
    ParamDef(
      id: kParamMAXMotionMaxJerk2,
      name: 'MAXMotion Max Jerk',
      type: ParamType.decimal,
      unit: 'RPM/s²',
      tooltip: '0 = trapezoidal profile',
    ),
    ParamDef(
      id: kParamMAXMotionAllowedError2,
      name: 'MAXMotion Allowed Error',
      type: ParamType.decimal,
      unit: 'rot',
    ),
    ParamDef(
      id: kParamMAXMotionPositionMode2,
      name: 'MAXMotion Position Mode',
      type: ParamType.dropdown,
      options: {0: 'Trapezoidal', 1: 'S-Curve'},
    ),
  ]),
  ParamCategory(name: 'Closed Loop Slot 3', params: [
    ParamDef(id: kParamSlot3P, name: 'P', type: ParamType.decimal),
    ParamDef(id: kParamSlot3I, name: 'I', type: ParamType.decimal),
    ParamDef(id: kParamSlot3D, name: 'D', type: ParamType.decimal),
    ParamDef(id: kParamSlot3F, name: 'F (kV)', type: ParamType.decimal),
    ParamDef(id: kParamSlot3IZone, name: 'I Zone', type: ParamType.decimal),
    ParamDef(id: kParamSlot3DFilter, name: 'D Filter', type: ParamType.decimal),
    ParamDef(
      id: kParamSlot3MinOutput,
      name: 'Min Output',
      type: ParamType.decimal,
      min: -1,
      max: 1,
    ),
    ParamDef(
      id: kParamSlot3MaxOutput,
      name: 'Max Output',
      type: ParamType.decimal,
      min: -1,
      max: 1,
    ),
    ParamDef(id: kParamSlot3FfKs, name: 'FF kS', type: ParamType.decimal),
    ParamDef(id: kParamSlot3FfKa, name: 'FF kA', type: ParamType.decimal),
    ParamDef(id: kParamSlot3FfKg, name: 'FF kG', type: ParamType.decimal),
    ParamDef(id: kParamSlot3FfKcos, name: 'FF kCos', type: ParamType.decimal),
    ParamDef(
      id: kParamSlot3FfKcosRatio,
      name: 'FF kCos Ratio',
      type: ParamType.decimal,
    ),
    ParamDef(id: kParamIMaxAccum3, name: 'I Max Accum', type: ParamType.decimal),
    ParamDef(id: kParamAllowedClosedLoopError3, name: 'Allowed CL Error', type: ParamType.decimal),
    // MAXMotion Slot 3
    ParamDef(
      id: kParamMAXMotionCruiseVelocity3,
      name: 'MAXMotion Cruise Velocity',
      type: ParamType.decimal,
      unit: 'RPM',
    ),
    ParamDef(
      id: kParamMAXMotionMaxAccel3,
      name: 'MAXMotion Max Acceleration',
      type: ParamType.decimal,
      unit: 'RPM/s',
    ),
    ParamDef(
      id: kParamMAXMotionMaxJerk3,
      name: 'MAXMotion Max Jerk',
      type: ParamType.decimal,
      unit: 'RPM/s²',
      tooltip: '0 = trapezoidal profile',
    ),
    ParamDef(
      id: kParamMAXMotionAllowedError3,
      name: 'MAXMotion Allowed Error',
      type: ParamType.decimal,
      unit: 'rot',
    ),
    ParamDef(
      id: kParamMAXMotionPositionMode3,
      name: 'MAXMotion Position Mode',
      type: ParamType.dropdown,
      options: {0: 'Trapezoidal', 1: 'S-Curve'},
    ),
  ]),
  ParamCategory(name: 'Limits', params: [
    ParamDef(
      id: kParamLimitSwitchFwdPolarity,
      name: 'Fwd Limit Switch Polarity',
      type: ParamType.dropdown,
      options: {0: 'Normally Open', 1: 'Normally Closed'},
    ),
    ParamDef(
      id: kParamHardLimitFwdEn,
      name: 'Fwd Hard Limit Enable',
      type: ParamType.boolean,
    ),
    ParamDef(
      id: kParamLimitSwitchRevPolarity,
      name: 'Rev Limit Switch Polarity',
      type: ParamType.dropdown,
      options: {0: 'Normally Open', 1: 'Normally Closed'},
    ),
    ParamDef(
      id: kParamHardLimitRevEn,
      name: 'Rev Hard Limit Enable',
      type: ParamType.boolean,
    ),
    ParamDef(
      id: kParamForwardSoftLimit,
      name: 'Forward Soft Limit',
      type: ParamType.decimal,
    ),
    ParamDef(
      id: kParamForwardSoftLimitEnabled,
      name: 'Forward Soft Limit Enable',
      type: ParamType.boolean,
    ),
    ParamDef(
      id: kParamReverseSoftLimit,
      name: 'Reverse Soft Limit',
      type: ParamType.decimal,
    ),
    ParamDef(
      id: kParamReverseSoftLimitEnabled,
      name: 'Reverse Soft Limit Enable',
      type: ParamType.boolean,
    ),
  ]),
  ParamCategory(name: 'Follower Mode', params: [
    ParamDef(
      id: 194,
      name: 'Follower Leader ID',
      type: ParamType.integer,
      min: 0,
      max: 62,
    ),
    ParamDef(
      id: 195,
      name: 'Follower Config',
      type: ParamType.dropdown,
      options: {0x1A: 'REV', 0x1B: 'Talon'},
    ),
  ]),
  ParamCategory(name: 'Primary Encoder', params: [
    ParamDef(
      id: kParamEncoderCountsPerRev,
      name: 'Counts Per Rev',
      type: ParamType.integer,
      min: 1,
      max: 65535,
      tooltip: 'Default 4096 (= 4 × CPR)',
    ),
    ParamDef(
      id: kParamEncoderAverageDepth,
      name: 'Average Depth',
      type: ParamType.integer,
      min: 1,
      max: 64,
    ),
    ParamDef(
      id: kParamEncoderSampleDelta,
      name: 'Sample Delta',
      type: ParamType.integer,
      min: 1,
      max: 255,
      tooltip: 'Delta time in x500 µs steps',
    ),
    ParamDef(
      id: kParamPositionConvFactor,
      name: 'Position Conversion Factor',
      type: ParamType.decimal,
    ),
    ParamDef(
      id: kParamVelocityConvFactor,
      name: 'Velocity Conversion Factor',
      type: ParamType.decimal,
    ),
  ]),
  ParamCategory(name: 'Alternate Encoder', params: [
    ParamDef(
      id: kParamDataPortConfig,
      name: 'Data Port Config',
      type: ParamType.dropdown,
      options: {0: 'Limit Switches', 1: 'Alternate Encoder'},
    ),
    ParamDef(
      id: kParamAltEncoderCountsPerRev,
      name: 'Counts Per Rev',
      type: ParamType.integer,
      min: 1,
      max: 65535,
    ),
    ParamDef(
      id: kParamAltEncoderAverageDepth,
      name: 'Average Depth',
      type: ParamType.integer,
      min: 1,
      max: 64,
    ),
    ParamDef(
      id: kParamAltEncoderSampleDelta,
      name: 'Sample Delta',
      type: ParamType.integer,
      min: 1,
      max: 255,
    ),
    ParamDef(
      id: kParamAltEncoderInverted,
      name: 'Inverted',
      type: ParamType.boolean,
    ),
    ParamDef(
      id: kParamAltEncoderPositionFactor,
      name: 'Position Factor',
      type: ParamType.decimal,
    ),
    ParamDef(
      id: kParamAltEncoderVelocityFactor,
      name: 'Velocity Factor',
      type: ParamType.decimal,
    ),
  ]),
  ParamCategory(name: 'Analog Sensor', params: [
    ParamDef(
      id: kParamAnalogPositionConversion,
      name: 'Position Conversion',
      type: ParamType.decimal,
      unit: 'rev/V',
    ),
    ParamDef(
      id: kParamAnalogVelocityConversion,
      name: 'Velocity Conversion',
      type: ParamType.decimal,
      unit: 'vel/V/s',
    ),
    ParamDef(
      id: kParamAnalogAverageDepth,
      name: 'Average Depth',
      type: ParamType.integer,
      min: 1,
      max: 64,
    ),
    ParamDef(
      id: kParamAnalogSensorMode,
      name: 'Sensor Mode',
      type: ParamType.dropdown,
      options: {0: 'Absolute', 1: 'Relative'},
    ),
    ParamDef(
      id: kParamAnalogInverted,
      name: 'Inverted',
      type: ParamType.boolean,
    ),
    ParamDef(
      id: kParamAnalogSampleDelta,
      name: 'Sample Delta',
      type: ParamType.integer,
      min: 1,
      max: 255,
    ),
  ]),
];

// ---------------------------------------------------------------------------
// Device Config Screen
// ---------------------------------------------------------------------------

class DeviceConfigScreen extends ConsumerStatefulWidget {
  const DeviceConfigScreen({super.key});

  @override
  ConsumerState<DeviceConfigScreen> createState() =>
      _DeviceConfigScreenState();
}

class _DeviceConfigScreenState extends ConsumerState<DeviceConfigScreen> {
  int _selectedCategory = 0;

  /// Cached parameter values: paramId → double.
  final Map<int, double> _values = {};

  /// Set of param IDs currently being read.
  final Set<int> _reading = {};

  /// Set of param IDs currently being written.
  final Set<int> _writing = {};

  /// Per-param error messages (cleared on next successful read/write).
  final Map<int, String> _errors = {};

  /// Whether we've loaded the current category's params.
  final Set<int> _loadedCategories = {};

  bool _burning = false;
  String? _burnStatus;

  SparkDevice? get _device {
    final dm = ref.read(deviceManagerProvider);
    return dm.leader;
  }

  @override
  void initState() {
    super.initState();
    // Schedule initial read after first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCategory(0));
  }

  Future<void> _loadCategory(int catIndex) async {
    final device = _device;
    if (device == null || !device.isConnected) return;
    if (_loadedCategories.contains(catIndex)) return;

    final cat = _categories[catIndex];
    // Deduplicate: some params appear in multiple tabs.
    final toRead = cat.params
        .where((p) => !_values.containsKey(p.id) && !_reading.contains(p.id))
        .toList();

    for (final p in toRead) {
      _reading.add(p.id);
    }
    if (mounted) setState(() {});

    for (final p in toRead) {
      try {
        final val = await device.parameters.getParameter(p.id);
        if (mounted) {
          setState(() {
            _values[p.id] = val;
            _reading.remove(p.id);
            _errors.remove(p.id);
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _reading.remove(p.id);
            _errors[p.id] = e.toString();
          });
        }
      }
    }

    _loadedCategories.add(catIndex);
  }

  /// When a device parameter that has a counterpart in MechanismConfig is
  /// written, push the value to the Riverpod config provider so both screens
  /// stay in sync.
  void _syncToMechanismConfig(int paramId, double value) {
    final notifier = ref.read(mechanismConfigProvider.notifier);
    switch (paramId) {
      case kParamMotorType:
        notifier.setIsBrushless(value == 1.0);
      case kParamMotorInverted:
        notifier.setMotorInverted(value != 0.0);
      case kParamSmartCurrentLimit:
        notifier.setCurrentLimit(value);
      case kParamClosedLoopControlSensor:
        notifier.setFeedbackSensor(
          value == FeedbackSensor.absoluteEncoder.parameterValue.toDouble()
              ? FeedbackSensor.absoluteEncoder
              : FeedbackSensor.primaryEncoder,
        );
    }
  }

  Future<void> _writeParam(ParamDef def, double value) async {
    final device = _device;
    if (device == null || !device.isConnected) return;

    setState(() {
      _writing.add(def.id);
      _values[def.id] = value;
      _errors.remove(def.id);
    });

    try {
      await device.parameters.setParameter(def.id, value);
      if (mounted) {
        setState(() => _writing.remove(def.id));
        _syncToMechanismConfig(def.id, value);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _writing.remove(def.id);
          _errors[def.id] = e.toString();
        });
      }
    }
  }

  Future<void> _burnFlash() async {
    final device = _device;
    if (device == null || !device.isConnected) return;

    setState(() {
      _burning = true;
      _burnStatus = null;
    });

    try {
      // Disable extra status frames before persisting to reduce CAN traffic
      // on the real robot — keep only Status 0 force-enabled.
      await device.parameters.disableExtraStatusFrames();

      await device.parameters.burnFlash(heartbeat: device.heartbeat);
      if (mounted) {
        setState(() {
          _burning = false;
          _burnStatus = 'Parameters saved to flash successfully.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _burning = false;
          _burnStatus = 'Burn flash failed: $e';
        });
      }
    }
  }

  Future<void> _refreshCategory() async {
    _loadedCategories.remove(_selectedCategory);
    // Clear cached values for this category so they reload.
    for (final p in _categories[_selectedCategory].params) {
      _values.remove(p.id);
    }
    await _loadCategory(_selectedCategory);
  }

  @override
  Widget build(BuildContext context) {
    // Watch for device changes.
    ref.watch(devicesProvider);
    final device = _device;
    final isConnected = device != null && device.isConnected;

    return ScaffoldPage(
      header: LogoPageHeader(
        title: 'Device Parameters',
        commandBar: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isConnected) ...[
              FilledButton(
                onPressed: _burning ? null : _burnFlash,
                child: _burning
                    ? const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: ProgressRing(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text('Saving...'),
                        ],
                      )
                    : const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(FluentIcons.save, size: 16),
                          SizedBox(width: 8),
                          Text('Save to Flash'),
                        ],
                      ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(FluentIcons.refresh, size: 16),
                onPressed: _refreshCategory,
              ),
            ],
          ],
        ),
      ),
      content: !isConnected
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.plug_disconnected, size: 48),
                  SizedBox(height: 12),
                  Text(
                    'No device connected',
                    style: TextStyle(fontSize: 16),
                  ),
                  SizedBox(height: 4),
                  Text('Connect a SPARK MAX/Flex on the Device Setup page.'),
                ],
              ),
            )
          : Column(
              children: [
                if (_burnStatus != null)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: InfoBar(
                      title: Text(
                          _burnStatus!.contains('failed') ? 'Error' : 'Done'),
                      content: Text(_burnStatus!),
                      severity: _burnStatus!.contains('failed')
                          ? InfoBarSeverity.error
                          : InfoBarSeverity.success,
                      onClose: () => setState(() => _burnStatus = null),
                    ),
                  ),
                Expanded(
                  child: Row(
                    children: [
                      // Left sidebar
                      SizedBox(
                        width: 220,
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: _categories.length,
                          itemBuilder: (context, i) {
                            final selected = i == _selectedCategory;
                            return ListTile.selectable(
                              title: Text(
                                _categories[i].name,
                                style: TextStyle(
                                  fontWeight: selected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                ),
                              ),
                              selected: selected,
                              onPressed: () {
                                setState(() => _selectedCategory = i);
                                _loadCategory(i);
                              },
                            );
                          },
                        ),
                      ),
                      const Divider(
                          direction: Axis.vertical,
                          style: DividerThemeData(
                              horizontalMargin: EdgeInsets.zero)),
                      // Right content
                      Expanded(
                        child: _buildParamPane(
                          _categories[_selectedCategory],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildParamPane(ParamCategory category) {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: category.params.length,
      itemBuilder: (context, i) {
        final p = category.params[i];
        return _ParamRow(
          def: p,
          value: _values[p.id],
          isLoading: _reading.contains(p.id),
          isWriting: _writing.contains(p.id),
          error: _errors[p.id],
          onChanged: (v) => _writeParam(p, v),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Individual parameter row widget
// ---------------------------------------------------------------------------

class _ParamRow extends StatelessWidget {
  final ParamDef def;
  final double? value;
  final bool isLoading;
  final bool isWriting;
  final String? error;
  final ValueChanged<double> onChanged;

  const _ParamRow({
    required this.def,
    required this.value,
    required this.isLoading,
    required this.isWriting,
    required this.onChanged,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 260,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(def.name),
                    ),
                    if (def.tooltip != null) ...[
                      const SizedBox(width: 4),
                      Tooltip(
                        message: def.tooltip!,
                        child: Icon(FluentIcons.info, size: 12,
                            color: Colors.grey[100]),
                      ),
                    ],
                    if (isWriting) ...[
                      const SizedBox(width: 6),
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: ProgressRing(strokeWidth: 2),
                      ),
                    ],
                  ],
                ),
              ),
              if (isLoading)
                const SizedBox(
                  width: 120,
                  child: Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: ProgressRing(strokeWidth: 2),
                    ),
                  ),
                )
              else if (value == null && error == null)
                const SizedBox(
                  width: 120,
                  child: Text('—', style: TextStyle(color: Colors.grey)),
                )
              else
                _buildEditor(context),
              if (def.unit != null) ...[
                const SizedBox(width: 8),
                Text(def.unit!, style: const TextStyle(fontSize: 12)),
              ],
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(left: 260, top: 2),
              child: Text(
                error!,
                style: TextStyle(fontSize: 11, color: Colors.red),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditor(BuildContext context) {
    final v = value ?? 0.0;

    switch (def.type) {
      case ParamType.boolean:
        return ToggleSwitch(
          checked: v != 0.0,
          onChanged: (b) => onChanged(b ? 1.0 : 0.0),
        );

      case ParamType.dropdown:
        final options = def.options!;
        final currentKey = v.toInt();
        return ComboBox<int>(
          value: options.containsKey(currentKey) ? currentKey : options.keys.first,
          items: options.entries
              .map((e) => ComboBoxItem<int>(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: (sel) {
            if (sel != null) onChanged(sel.toDouble());
          },
        );

      case ParamType.integer:
        return SizedBox(
          width: 180,
          child: NumberBox<int>(
            value: v.toInt(),
            min: def.min?.toInt(),
            max: def.max?.toInt(),
            onChanged: (n) {
              if (n != null) onChanged(n.toDouble());
            },
            mode: SpinButtonPlacementMode.compact,
          ),
        );

      case ParamType.decimal:
        return SizedBox(
          width: 180,
          child: _DecimalField(
            value: v,
            onSubmitted: onChanged,
          ),
        );
    }
  }
}

// ---------------------------------------------------------------------------
// Decimal input field (submits on Enter or focus-lost)
// ---------------------------------------------------------------------------

class _DecimalField extends StatefulWidget {
  final double value;
  final ValueChanged<double> onSubmitted;

  const _DecimalField({required this.value, required this.onSubmitted});

  @override
  State<_DecimalField> createState() => _DecimalFieldState();
}

class _DecimalFieldState extends State<_DecimalField> {
  late TextEditingController _ctrl;
  late FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: _format(widget.value));
    _focus = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(_DecimalField old) {
    super.didUpdateWidget(old);
    // Only update text if the value actually changed externally and the field
    // doesn't have focus (user might be typing).
    if (old.value != widget.value && !_focus.hasFocus) {
      _ctrl.text = _format(widget.value);
    }
  }

  String _format(double v) {
    // Remove trailing zeros but keep at least one decimal if it's a float.
    final s = v.toStringAsFixed(6);
    // Trim trailing zeros after decimal point.
    if (s.contains('.')) {
      var trimmed = s.replaceAll(RegExp(r'0+$'), '');
      if (trimmed.endsWith('.')) trimmed = '${trimmed}0';
      return trimmed;
    }
    return s;
  }

  void _submit() {
    final parsed = double.tryParse(_ctrl.text);
    if (parsed != null && parsed != widget.value) {
      widget.onSubmitted(parsed);
    }
  }

  void _onFocusChange() {
    if (!_focus.hasFocus) _submit();
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextBox(
      controller: _ctrl,
      onSubmitted: (_) => _submit(),
      focusNode: _focus,
    );
  }
}
