/// Application state management using Riverpod.
///
/// Provides all shared state for the application: device connections,
/// mechanism configuration, test runs, and computed results.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../devices/device_manager.dart';
import '../mechanisms/mechanism.dart';
import '../data/test_data.dart';
import '../sysid/test_runner.dart' show TestProgress;
import '../sysid/validation_runner.dart'
    show ValidationParams, ValidationResult, ValidationProgress;

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

  void setGearRatio(double ratio) {
    state = state.copyWith(gearRatio: ratio);
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
final selectedPageProvider = StateProvider<int>((ref) => 0);

/// Whether a test is currently running.
final testRunningProvider = StateProvider<bool>((ref) => false);

/// Latest test progress update.
final testProgressProvider =
    StateProvider<TestProgress?>((ref) => null);

/// Whether the user has seen the chart walkthrough (per chart key).
final walkthroughSeenProvider =
    StateProvider.family<bool, String>((ref, chartKey) => false);

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
