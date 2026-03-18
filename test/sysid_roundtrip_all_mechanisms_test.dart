/// Comprehensive roundtrip test: run the full quasistatic / dynamic sysid
/// pipeline on every simulated subsystem (flywheel, arm, elevator) with
/// 3 different feedforward physics configurations each, and verify the
/// analyzer recovers ground-truth kS, kV, kA, kG.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/mechanisms/mechanism.dart';
import 'package:rev_system_identification/simulation/arm_physics.dart';
import 'package:rev_system_identification/simulation/elevator_physics.dart';
import 'package:rev_system_identification/simulation/flywheel_physics.dart';
import 'package:rev_system_identification/simulation/simulated_physics.dart';
import 'package:rev_system_identification/sysid/feedforward_analyzer.dart';

// ═══════════════════════════════════════════════════════════════════════
// Test configuration record for a single roundtrip scenario.
// ═══════════════════════════════════════════════════════════════════════

class _PhysicsConfig {
  final String label;
  final SimulatedPhysics physics;
  final MechanismType mechanismType;

  /// Ground-truth feedforward constants (in user units).
  final double expectedKs;
  final double expectedKv;
  final double expectedKa;
  final double expectedKg;

  /// Tolerances for assertion (absolute).
  final double ksTol;
  final double kvTol;
  final double kaTol;
  final double kgTol;

  /// The conversion factor from rotations → position user units.
  /// e.g. 360 for arm (degrees), inchesPerRotation for elevator, 1 for flywheel.
  final double positionConversionFactor;

  /// The conversion factor from RPM → velocity user units.
  /// e.g. (degreesPerRotation / 60) for arm → deg/s, (inchesPerRotation / 60)
  /// for elevator → in/s, 1 for flywheel → RPM.
  final double velocityConversionFactor;

  /// Test parameters for quasistatic / dynamic tests.
  final double rampRate;
  final double maxVoltage;
  final double stepVoltage;
  final double stepDuration;

  /// Optional starting position (rotations) before each test run.
  /// Used to set arm/elevator to a reasonable starting angle/height.
  final double? startPositionRotations;

  /// Minimum R² for regression quality.
  final double minRSquared;

  _PhysicsConfig({
    required this.label,
    required this.physics,
    required this.mechanismType,
    required this.expectedKs,
    required this.expectedKv,
    required this.expectedKa,
    this.expectedKg = 0.0,
    this.ksTol = 0.04,
    this.kvTol = 0.003,
    this.kaTol = 0.002,
    this.kgTol = 0.15,
    this.positionConversionFactor = 1.0,
    this.velocityConversionFactor = 1.0,
    this.rampRate = 0.25,
    this.maxVoltage = 12.0,
    this.stepVoltage = 7.0,
    this.stepDuration = 3.0,
    this.startPositionRotations,
    this.minRSquared = 0.90,
  });
}

// ═══════════════════════════════════════════════════════════════════════
// Simulation helpers
// ═══════════════════════════════════════════════════════════════════════

TestRun _simulateQuasistatic({
  required _PhysicsConfig config,
  required bool forward,
  double dtSeconds = 0.010,
}) {
  final physics = config.physics;
  physics.reset();
  if (config.startPositionRotations != null) {
    physics.setPositionRotations(config.startPositionRotations!);
  }

  final sign = forward ? 1.0 : -1.0;
  final data = <DataPoint>[];
  final maxDuration = config.maxVoltage / config.rampRate;
  final vcf = config.velocityConversionFactor;
  final pcf = config.positionConversionFactor;

  for (var t = 0.0; t <= maxDuration; t += dtSeconds) {
    final voltage = sign * config.rampRate * t;
    if (voltage.abs() >= config.maxVoltage) break;

    physics.step(voltage, dtSeconds);

    data.add(DataPoint(
      timestamp: t,
      voltage: voltage,
      velocity: physics.noisyVelocityRpm * vcf,
      position: physics.noisyPositionRotations * pcf,
      current: physics.outputCurrentAmps,
    ));
  }

  return TestRun(
    id: 'qs_${forward ? "fwd" : "rev"}',
    startTime: DateTime.now(),
    mechanismType: config.mechanismType,
    testType:
        forward ? TestType.quasistaticForward : TestType.quasistaticReverse,
    data: data,
    durationSeconds: maxDuration,
    testParams: SysIdTestParams(
      quasistaticRampRate: config.rampRate,
      dynamicStepVoltage: config.stepVoltage,
      dynamicStepDuration: config.stepDuration,
      maxTestVoltage: config.maxVoltage,
    ),
  );
}

TestRun _simulateDynamic({
  required _PhysicsConfig config,
  required bool forward,
  double dtSeconds = 0.010,
}) {
  final physics = config.physics;
  physics.reset();
  if (config.startPositionRotations != null) {
    physics.setPositionRotations(config.startPositionRotations!);
  }

  final sign = forward ? 1.0 : -1.0;
  final voltage = sign * config.stepVoltage;
  final data = <DataPoint>[];
  final vcf = config.velocityConversionFactor;
  final pcf = config.positionConversionFactor;

  for (var t = 0.0; t <= config.stepDuration; t += dtSeconds) {
    physics.step(voltage, dtSeconds);

    data.add(DataPoint(
      timestamp: t,
      voltage: voltage,
      velocity: physics.noisyVelocityRpm * vcf,
      position: physics.noisyPositionRotations * pcf,
      current: physics.outputCurrentAmps,
    ));
  }

  return TestRun(
    id: 'dyn_${forward ? "fwd" : "rev"}',
    startTime: DateTime.now(),
    mechanismType: config.mechanismType,
    testType: forward ? TestType.dynamicForward : TestType.dynamicReverse,
    data: data,
    durationSeconds: config.stepDuration,
    testParams: SysIdTestParams(
      quasistaticRampRate: config.rampRate,
      dynamicStepVoltage: config.stepVoltage,
      dynamicStepDuration: config.stepDuration,
      maxTestVoltage: config.maxVoltage,
    ),
  );
}

/// Run the full 4-test sysid sequence and return recovered gains.
FeedforwardGains _runFullSysid(_PhysicsConfig config) {
  final qsFwd = _simulateQuasistatic(config: config, forward: true);
  final qsRev = _simulateQuasistatic(config: config, forward: false);
  final dynFwd = _simulateDynamic(config: config, forward: true);
  final dynRev = _simulateDynamic(config: config, forward: false);

  return FeedforwardAnalyzer.analyze(
    quasistaticRuns: [qsFwd, qsRev],
    dynamicRuns: [dynFwd, dynRev],
    mechanismType: config.mechanismType,
  );
}

void _assertGains(_PhysicsConfig config, FeedforwardGains gains) {
  // ignore: avoid_print
  print('  ${config.label}: '
      'kS=${gains.kS.toStringAsFixed(4)} '
      '(exp ${config.expectedKs}), '
      'kV=${gains.kV.toStringAsFixed(5)} '
      '(exp ${config.expectedKv}), '
      'kA=${gains.kA.toStringAsFixed(5)} '
      '(exp ${config.expectedKa}), '
      'kG=${gains.kG.toStringAsFixed(4)} '
      '(exp ${config.expectedKg}), '
      'R²=${gains.rSquared.toStringAsFixed(4)}');

  expect(gains.kS, closeTo(config.expectedKs, config.ksTol),
      reason: '${config.label}: kS');
  expect(gains.kV, closeTo(config.expectedKv, config.kvTol),
      reason: '${config.label}: kV');
  expect(gains.kA, closeTo(config.expectedKa, config.kaTol),
      reason: '${config.label}: kA');
  if (config.mechanismType.hasGravity) {
    expect(gains.kG, closeTo(config.expectedKg, config.kgTol),
        reason: '${config.label}: kG');
  }
  expect(gains.rSquared, greaterThan(config.minRSquared),
      reason: '${config.label}: R²');
}

// ═══════════════════════════════════════════════════════════════════════
// Flywheel configurations
// ═══════════════════════════════════════════════════════════════════════

List<_PhysicsConfig> _flywheelConfigs() {
  return [
    // Config 1: Default flywheel (NEO-class)
    _PhysicsConfig(
      label: 'Flywheel #1 (default)',
      physics: FlywheelPhysics(
        kS: 0.14,
        kV: 0.0185,
        kA: 0.003,
        noiseLevel: 0.015,
        randomSeed: 42,
      ),
      mechanismType: MechanismType.flywheel,
      expectedKs: 0.14,
      expectedKv: 0.0185,
      expectedKa: 0.003,
    ),
    // Config 2: Heavy flywheel — higher inertia (kA), lower friction
    _PhysicsConfig(
      label: 'Flywheel #2 (heavy)',
      physics: FlywheelPhysics(
        kS: 0.08,
        kV: 0.022,
        kA: 0.008,
        noiseLevel: 0.015,
        randomSeed: 123,
      ),
      mechanismType: MechanismType.flywheel,
      expectedKs: 0.08,
      expectedKv: 0.022,
      expectedKa: 0.008,
    ),
    // Config 3: Light, high-friction flywheel — small inertia
    _PhysicsConfig(
      label: 'Flywheel #3 (light/high friction)',
      physics: FlywheelPhysics(
        kS: 0.30,
        kV: 0.012,
        kA: 0.001,
        noiseLevel: 0.015,
        randomSeed: 777,
      ),
      mechanismType: MechanismType.flywheel,
      expectedKs: 0.30,
      expectedKv: 0.012,
      expectedKa: 0.001,
      ksTol: 0.06,
      kaTol: 0.001,
    ),
  ];
}

// ═══════════════════════════════════════════════════════════════════════
// Arm configurations
// ═══════════════════════════════════════════════════════════════════════

List<_PhysicsConfig> _armConfigs() {
  const degPerRot = 360.0;
  const vcf = degPerRot / 60.0; // RPM → deg/s

  return [
    // Config 1: Default arm
    _PhysicsConfig(
      label: 'Arm #1 (default)',
      physics: ArmPhysics(
        kS: 0.20,
        kV: 0.018,
        kA: 0.002,
        kG: 0.80,
        noiseLevel: 0.015,
        degreesPerRotation: degPerRot,
        minAngleDeg: -360.0,
        maxAngleDeg: 360.0,
        randomSeed: 42,
      ),
      mechanismType: MechanismType.arm,
      expectedKs: 0.20,
      expectedKv: 0.018,
      expectedKa: 0.002,
      expectedKg: 0.80,
      positionConversionFactor: degPerRot,
      velocityConversionFactor: vcf,
      rampRate: 0.25,
      maxVoltage: 8.0,
      stepVoltage: 4.0,
      stepDuration: 2.0,
      startPositionRotations: 0.0,
      ksTol: 0.08,
      kaTol: 0.002,
    ),
    // Config 2: Heavy arm — more inertia, stronger gravity
    _PhysicsConfig(
      label: 'Arm #2 (heavy)',
      physics: ArmPhysics(
        kS: 0.15,
        kV: 0.025,
        kA: 0.005,
        kG: 1.50,
        noiseLevel: 0.015,
        degreesPerRotation: degPerRot,
        minAngleDeg: -360.0,
        maxAngleDeg: 360.0,
        randomSeed: 123,
      ),
      mechanismType: MechanismType.arm,
      expectedKs: 0.15,
      expectedKv: 0.025,
      expectedKa: 0.005,
      expectedKg: 1.50,
      positionConversionFactor: degPerRot,
      velocityConversionFactor: vcf,
      rampRate: 0.25,
      maxVoltage: 8.0,
      stepVoltage: 5.0,
      stepDuration: 2.0,
      startPositionRotations: 0.0,
      ksTol: 0.08,
      kaTol: 0.003,
      kgTol: 0.30,
    ),
    // Config 3: Light arm — low friction, low inertia, moderate gravity
    _PhysicsConfig(
      label: 'Arm #3 (light)',
      physics: ArmPhysics(
        kS: 0.10,
        kV: 0.012,
        kA: 0.001,
        kG: 0.40,
        noiseLevel: 0.015,
        degreesPerRotation: degPerRot,
        minAngleDeg: -360.0,
        maxAngleDeg: 360.0,
        randomSeed: 777,
      ),
      mechanismType: MechanismType.arm,
      expectedKs: 0.10,
      expectedKv: 0.012,
      expectedKa: 0.001,
      expectedKg: 0.40,
      positionConversionFactor: degPerRot,
      velocityConversionFactor: vcf,
      rampRate: 0.25,
      maxVoltage: 8.0,
      stepVoltage: 4.0,
      stepDuration: 2.0,
      startPositionRotations: 0.0,
      ksTol: 0.08,
      kaTol: 0.002,
      kgTol: 0.15,
    ),
  ];
}

// ═══════════════════════════════════════════════════════════════════════
// Elevator configurations
// ═══════════════════════════════════════════════════════════════════════

List<_PhysicsConfig> _elevatorConfigs() {
  const inPerRot = 1.504;
  const vcf = inPerRot / 60.0; // RPM → in/s

  return [
    // Config 1: Default elevator
    _PhysicsConfig(
      label: 'Elevator #1 (default)',
      physics: ElevatorPhysics(
        kS: 0.18,
        kV: 0.12,
        kA: 0.015,
        kG: 0.55,
        noiseLevel: 0.015,
        inchesPerRotation: inPerRot,
        minPositionIn: -500.0,
        maxPositionIn: 500.0,
        randomSeed: 42,
      ),
      mechanismType: MechanismType.elevator,
      expectedKs: 0.18,
      expectedKv: 0.12,
      expectedKa: 0.015,
      expectedKg: 0.55,
      positionConversionFactor: inPerRot,
      velocityConversionFactor: vcf,
      rampRate: 0.25,
      maxVoltage: 8.0,
      stepVoltage: 4.0,
      stepDuration: 1.5,
      startPositionRotations: 20.0 / inPerRot, // start at 20 inches
      ksTol: 0.06,
      kaTol: 0.008,
      kgTol: 0.15,
    ),
    // Config 2: Tall elevator — heavy carriage, strong gravity
    _PhysicsConfig(
      label: 'Elevator #2 (heavy)',
      physics: ElevatorPhysics(
        kS: 0.25,
        kV: 0.18,
        kA: 0.025,
        kG: 1.10,
        noiseLevel: 0.015,
        inchesPerRotation: inPerRot,
        minPositionIn: -500.0,
        maxPositionIn: 500.0,
        randomSeed: 123,
      ),
      mechanismType: MechanismType.elevator,
      expectedKs: 0.25,
      expectedKv: 0.18,
      expectedKa: 0.025,
      expectedKg: 1.10,
      positionConversionFactor: inPerRot,
      velocityConversionFactor: vcf,
      rampRate: 0.25,
      maxVoltage: 8.0,
      stepVoltage: 4.0,
      stepDuration: 1.5,
      startPositionRotations: 20.0 / inPerRot,
      ksTol: 0.06,
      kaTol: 0.012,
      kgTol: 0.25,
    ),
    // Config 3: Light elevator — fast, low friction, weak gravity
    _PhysicsConfig(
      label: 'Elevator #3 (light)',
      physics: ElevatorPhysics(
        kS: 0.10,
        kV: 0.08,
        kA: 0.008,
        kG: 0.25,
        noiseLevel: 0.015,
        inchesPerRotation: inPerRot,
        minPositionIn: -500.0,
        maxPositionIn: 500.0,
        randomSeed: 777,
      ),
      mechanismType: MechanismType.elevator,
      expectedKs: 0.10,
      expectedKv: 0.08,
      expectedKa: 0.008,
      expectedKg: 0.25,
      positionConversionFactor: inPerRot,
      velocityConversionFactor: vcf,
      rampRate: 0.25,
      maxVoltage: 8.0,
      stepVoltage: 4.0,
      stepDuration: 1.5,
      startPositionRotations: 20.0 / inPerRot,
      ksTol: 0.06,
      kaTol: 0.006,
      kgTol: 0.15,
    ),
  ];
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

void main() {
  group('Flywheel sysid roundtrip', () {
    for (final config in _flywheelConfigs()) {
      test(config.label, () {
        final gains = _runFullSysid(config);
        _assertGains(config, gains);
      });
    }
  });

  group('Arm sysid roundtrip', () {
    for (final config in _armConfigs()) {
      test(config.label, () {
        final gains = _runFullSysid(config);
        _assertGains(config, gains);
      });
    }
  });

  group('Elevator sysid roundtrip', () {
    for (final config in _elevatorConfigs()) {
      test(config.label, () {
        final gains = _runFullSysid(config);
        _assertGains(config, gains);
      });
    }
  });

  group('Loaded arm sysid shifts kG not kS', () {
    test('loadTorqueVolts increases recovered kG', () {
      const degPerRot = 360.0;
      const vcf = degPerRot / 60.0;
      const trueKs = 0.20;
      const trueKv = 0.018;
      const trueKa = 0.002;
      const trueKg = 0.80;
      const loadVolts = 0.40; // simulated extra load

      // Run unloaded sysid.
      final unloadedPhysics = ArmPhysics(
        kS: trueKs, kV: trueKv, kA: trueKa, kG: trueKg,
        noiseLevel: 0.015, degreesPerRotation: degPerRot,
        minAngleDeg: -360, maxAngleDeg: 360, randomSeed: 42,
      );
      final unloadedConfig = _PhysicsConfig(
        label: 'Arm unloaded',
        physics: unloadedPhysics,
        mechanismType: MechanismType.arm,
        expectedKs: trueKs, expectedKv: trueKv,
        expectedKa: trueKa, expectedKg: trueKg,
        positionConversionFactor: degPerRot,
        velocityConversionFactor: vcf,
        rampRate: 0.25, maxVoltage: 8.0,
        stepVoltage: 4.0, stepDuration: 2.0,
        startPositionRotations: 0.0,
      );
      final gainsUnloaded = _runFullSysid(unloadedConfig);

      // Run loaded sysid — same physics but with loadTorqueVolts.
      final loadedPhysics = ArmPhysics(
        kS: trueKs, kV: trueKv, kA: trueKa, kG: trueKg,
        noiseLevel: 0.015, degreesPerRotation: degPerRot,
        minAngleDeg: -360, maxAngleDeg: 360, randomSeed: 42,
      );
      loadedPhysics.loadTorqueVolts = loadVolts;
      final loadedConfig = _PhysicsConfig(
        label: 'Arm loaded',
        physics: loadedPhysics,
        mechanismType: MechanismType.arm,
        expectedKs: trueKs, expectedKv: trueKv,
        expectedKa: trueKa, expectedKg: trueKg + loadVolts,
        positionConversionFactor: degPerRot,
        velocityConversionFactor: vcf,
        rampRate: 0.25, maxVoltage: 8.0,
        stepVoltage: 4.0, stepDuration: 2.0,
        startPositionRotations: 0.0,
        kgTol: 0.25,
      );
      final gainsLoaded = _runFullSysid(loadedConfig);

      // ignore: avoid_print
      print('  Unloaded: kS=${gainsUnloaded.kS.toStringAsFixed(4)}, '
          'kV=${gainsUnloaded.kV.toStringAsFixed(5)}, '
          'kA=${gainsUnloaded.kA.toStringAsFixed(5)}, '
          'kG=${gainsUnloaded.kG.toStringAsFixed(4)}');
      // ignore: avoid_print
      print('  Loaded:   kS=${gainsLoaded.kS.toStringAsFixed(4)}, '
          'kV=${gainsLoaded.kV.toStringAsFixed(5)}, '
          'kA=${gainsLoaded.kA.toStringAsFixed(5)}, '
          'kG=${gainsLoaded.kG.toStringAsFixed(4)}');

      // kG should increase by roughly loadVolts.
      expect(gainsLoaded.kG, greaterThan(gainsUnloaded.kG + 0.15),
          reason: 'kG should increase with load');

      // kS should NOT absorb the load (should stay similar).
      expect((gainsLoaded.kS - gainsUnloaded.kS).abs(), lessThan(0.15),
          reason: 'kS should not absorb the load');

      // kV and kA should be essentially unchanged.
      expect(gainsLoaded.kV, closeTo(gainsUnloaded.kV, 0.003),
          reason: 'kV should not change with load');
    });
  });
}
