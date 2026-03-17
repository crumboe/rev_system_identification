/// Application state management using Riverpod.
///
/// Provides all shared state for the application: device connections,
/// mechanism configuration, test runs, and computed results.
library;

import 'package:fluent_ui/fluent_ui.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../can/comms_log.dart';
import '../devices/device_manager.dart';
import '../mechanisms/mechanism.dart';
import '../data/test_data.dart';
import '../sysid/test_runner.dart' show TestProgress;
import '../sysid/validation_runner.dart'
    show ValidationParams, ValidationResult, ValidationProgress;

// ---------------------------------------------------------------------------
// Communication log
// ---------------------------------------------------------------------------

/// Global communication log (singleton shared across all connections).
final commsLogProvider = Provider<CommsLog>((ref) => CommsLog.instance);

// ---------------------------------------------------------------------------
// Device management
// ---------------------------------------------------------------------------

/// Global [DeviceManager] instance.
final deviceManagerProvider = Provider<DeviceManager>((ref) {
  final dm = DeviceManager();
  ref.onDispose(() => dm.dispose());
  return dm;
});

/// Stream of connected device list changes.
final devicesProvider = StreamProvider<List<SparkDevice>>((ref) {
  final dm = ref.watch(deviceManagerProvider);
  return dm.devicesChanged;
});

// ---------------------------------------------------------------------------
// Mechanism configuration
// ---------------------------------------------------------------------------

/// Current mechanism configuration (user-editable).
final mechanismConfigProvider =
    StateNotifierProvider<MechanismConfigNotifier, MechanismConfig>((ref) {
  return MechanismConfigNotifier();
});

class MechanismConfigNotifier extends StateNotifier<MechanismConfig> {
  MechanismConfigNotifier()
      : super(const MechanismConfig(type: MechanismType.flywheel));

  void setType(MechanismType type) {
    state = state.copyWith(type: type);
  }

  void setSystemName(String name) {
    state = state.copyWith(systemName: name);
  }

  void setPositionConversionFactor(double factor) {
    state = state.copyWith(positionConversionFactor: factor);
  }

  void setVelocityConversionFactor(double factor) {
    state = state.copyWith(velocityConversionFactor: factor);
  }

  void setForwardSoftLimit(double limit) {
    state = state.copyWith(forwardSoftLimit: limit);
  }

  void setReverseSoftLimit(double limit) {
    state = state.copyWith(reverseSoftLimit: limit);
  }

  void setMotorInverted(bool inverted) {
    state = state.copyWith(motorInverted: inverted);
  }

  void setUseImperialUnits(bool imperial) {
    state = state.copyWith(useImperialUnits: imperial);
  }

  void setIsBrushless(bool brushless) {
    state = state.copyWith(isBrushless: brushless);
  }

  void setCurrentLimit(double amps) {
    state = state.copyWith(currentLimitAmps: amps);
  }

  void setFeedbackSensor(FeedbackSensor sensor) {
    state = state.copyWith(feedbackSensor: sensor);
  }

  void setSimulatedArmMassLbs(double? massLbs) {
    state = state.copyWith(simulatedArmMassLbs: () => massLbs);
  }

  void setSimulatedArmLengthIn(double? lengthIn) {
    state = state.copyWith(simulatedArmLengthIn: () => lengthIn);
  }

  void setSimulatedArmSpec({double? massLbs, double? lengthIn}) {
    state = state.copyWith(
      simulatedArmMassLbs: () => massLbs,
      simulatedArmLengthIn: () => lengthIn,
    );
  }

  void setConfig(MechanismConfig config) {
    state = config;
  }
}

// ---------------------------------------------------------------------------
// Test parameters
// ---------------------------------------------------------------------------

/// Current test parameters.
final testParamsProvider =
    StateNotifierProvider<TestParamsNotifier, SysIdTestParams>((ref) {
  return TestParamsNotifier();
});

class TestParamsNotifier extends StateNotifier<SysIdTestParams> {
  TestParamsNotifier() : super(const SysIdTestParams());

  void setParams(SysIdTestParams params) {
    state = params;
  }

  void setQuasistaticRampRate(double rate) {
    state = state.copyWith(quasistaticRampRate: rate);
  }

  void setDynamicStepVoltage(double voltage) {
    state = state.copyWith(dynamicStepVoltage: voltage);
  }

  void setDynamicStepDuration(double seconds) {
    state = state.copyWith(dynamicStepDuration: seconds);
  }

  void setMaxTestVoltage(double voltage) {
    state = state.copyWith(maxTestVoltage: voltage);
  }

  void setCurrentTripAmps(double? amps) {
    state = state.copyWith(currentTripAmps: () => amps);
  }

  void loadDefaults(MechanismType type) {
    state = SysIdTestParams.forMechanism(type);
  }
}

// ---------------------------------------------------------------------------
// Test runs and results
// ---------------------------------------------------------------------------

/// Collected test run data for the current session.
final testRunsProvider =
    StateNotifierProvider<TestRunsNotifier, List<TestRun>>((ref) {
  return TestRunsNotifier();
});

class TestRunsNotifier extends StateNotifier<List<TestRun>> {
  TestRunsNotifier() : super([]);

  void addRun(TestRun run) {
    state = [...state, run];
  }

  void removeRun(String id) {
    state = state.where((r) => r.id != id).toList();
  }

  void loadRuns(List<TestRun> runs) {
    state = runs;
  }

  void clear() {
    state = [];
  }
}

/// Computed feedforward gains (null until analysis is run).
final feedforwardGainsProvider =
    StateProvider<FeedforwardGains?>((ref) => null);

/// Computed velocity PID gains (null until analysis is run).
final pidResultProvider = StateProvider<PidResult?>((ref) => null);

/// Computed position PID gains (null until analysis is run).
final posPidResultProvider = StateProvider<PidResult?>((ref) => null);

/// Complete sysid results (null until analysis is run).
final sysIdResultsProvider = StateProvider<SysIdResults?>((ref) => null);

// ---------------------------------------------------------------------------
// UI state
// ---------------------------------------------------------------------------

/// Currently selected navigation page index.
final selectedPageProvider = StateProvider<int>((ref) => 1);

/// Whether a test is currently running.
final testRunningProvider = StateProvider<bool>((ref) => false);

/// Latest test progress update.
final testProgressProvider =
    StateProvider<TestProgress?>((ref) => null);

/// Whether the user has seen the chart walkthrough (per chart key).
final walkthroughSeenProvider =
    StateProvider.family<bool, String>((ref, chartKey) => false);

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

/// Current theme mode (dark, light, or system).
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.dark);

// ---------------------------------------------------------------------------
// Validation test state
// ---------------------------------------------------------------------------

/// Current validation test parameters.
final validationParamsProvider =
    StateProvider<ValidationParams>((ref) => const ValidationParams());

/// Whether a validation test is currently running.
final validationRunningProvider = StateProvider<bool>((ref) => false);

/// Latest validation progress update.
final validationProgressProvider =
    StateProvider<ValidationProgress?>((ref) => null);

/// Latest validation result (null until a test completes).
final validationResultProvider =
    StateProvider<ValidationResult?>((ref) => null);

// ---------------------------------------------------------------------------
// PID tuning parameters (advanced)
// ---------------------------------------------------------------------------

/// Configurable PID auto-tuning parameters.
///
/// These control the aggressiveness of the auto-tuned PID gains.
/// Defaults match the original hardcoded values.
class PidTuningParams {
  /// Desired closed-loop time constant for velocity control (ms).
  ///
  /// Smaller values → faster response but less stability margin.
  /// Range: 20–500 ms. Default: 100 ms.
  final double velocityTimeConstantMs;

  /// Desired closed-loop bandwidth for position control (Hz).
  ///
  /// Higher values → faster response but more sensitive to noise.
  /// Range: 1–20 Hz. Default: 5 Hz.
  final double positionBandwidthHz;

  /// Desired damping ratio (ζ) for position pole placement.
  ///
  /// Controls how the closed-loop system approaches its target:
  ///   ζ > 1.0: Overdamped – slow, no overshoot.
  ///   ζ = 1.0: Critically damped – fastest without overshoot.
  ///   ζ = 0.707: Butterworth – ~4 % overshoot, fast settling.
  ///   ζ < 0.707: Underdamped – oscillatory, faster rise time.
  /// Range: 0.3–2.0. Default: 1.0 (critically damped).
  final double dampingRatio;

  const PidTuningParams({
    this.velocityTimeConstantMs = 100.0,
    this.positionBandwidthHz = 5.0,
    this.dampingRatio = 1.0,
  });

  PidTuningParams copyWith({
    double? velocityTimeConstantMs,
    double? positionBandwidthHz,
    double? dampingRatio,
  }) {
    return PidTuningParams(
      velocityTimeConstantMs:
          velocityTimeConstantMs ?? this.velocityTimeConstantMs,
      positionBandwidthHz:
          positionBandwidthHz ?? this.positionBandwidthHz,
      dampingRatio: dampingRatio ?? this.dampingRatio,
    );
  }

  /// Velocity time constant clamped to valid range.
  static double clampVelocityTau(double ms) => ms.clamp(20.0, 500.0);

  /// Position bandwidth clamped to valid range.
  static double clampPositionBw(double hz) => hz.clamp(1.0, 20.0);

  /// Damping ratio clamped to valid range.
  static double clampDamping(double z) => z.clamp(0.3, 2.0);
}

/// Current PID tuning parameters.
final pidTuningParamsProvider =
    StateNotifierProvider<PidTuningParamsNotifier, PidTuningParams>((ref) {
  return PidTuningParamsNotifier();
});

class PidTuningParamsNotifier extends StateNotifier<PidTuningParams> {
  PidTuningParamsNotifier() : super(const PidTuningParams());

  /// Plant-optimal defaults (updated after feedforward analysis).
  double _optimalTauMs = 100.0;
  double _optimalBwHz = 5.0;

  /// Current plant-optimal velocity time constant (ms).
  double get optimalTauMs => _optimalTauMs;

  /// Current plant-optimal position bandwidth (Hz).
  double get optimalBwHz => _optimalBwHz;

  /// Whether the current values match the plant-optimal defaults.
  bool get isAtDefaults =>
      (state.velocityTimeConstantMs - _optimalTauMs).abs() < 0.01 &&
      (state.positionBandwidthHz - _optimalBwHz).abs() < 0.01 &&
      (state.dampingRatio - 1.0).abs() < 0.01;

  /// Set plant-optimal defaults from identified feedforward gains.
  ///
  /// If the current values are still at the previous defaults, they are
  /// automatically updated to the new optimal values.  If the user has
  /// manually adjusted the sliders, their choices are preserved.
  void setOptimalDefaults(double tauMs, double bwHz) {
    final wasAtDefaults = isAtDefaults;
    _optimalTauMs = PidTuningParams.clampVelocityTau(tauMs);
    _optimalBwHz = PidTuningParams.clampPositionBw(bwHz);
    if (wasAtDefaults) {
      state = PidTuningParams(
        velocityTimeConstantMs: _optimalTauMs,
        positionBandwidthHz: _optimalBwHz,
        dampingRatio: state.dampingRatio,
      );
    }
  }

  void setVelocityTimeConstant(double ms) {
    state = state.copyWith(
      velocityTimeConstantMs: PidTuningParams.clampVelocityTau(ms),
    );
  }

  void setPositionBandwidth(double hz) {
    state = state.copyWith(
      positionBandwidthHz: PidTuningParams.clampPositionBw(hz),
    );
  }

  void setDampingRatio(double z) {
    state = state.copyWith(
      dampingRatio: PidTuningParams.clampDamping(z),
    );
  }

  void reset() {
    state = PidTuningParams(
      velocityTimeConstantMs: _optimalTauMs,
      positionBandwidthHz: _optimalBwHz,
    );
  }
}
