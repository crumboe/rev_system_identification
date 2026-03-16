/// Diagnostic test: run the full sysid data collection + analysis pipeline
/// on FlywheelPhysics and check whether kS, kV, kA are recovered.
///
/// This isolates the problem to physics + analyzer without any UI or device
/// layer involvement.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/mechanisms/mechanism.dart';
import 'package:rev_system_identification/simulation/flywheel_physics.dart';
import 'package:rev_system_identification/sysid/feedforward_analyzer.dart';

/// Simulate the test runner's quasistatic ramp, recording the same
/// (voltage, velocity) pairs the real pipeline would see.
TestRun _simulateQuasistatic({
  required FlywheelPhysics physics,
  required bool forward,
  double rampRate = 0.25,
  double maxVoltage = 12.0,
  double dtSeconds = 0.010,
}) {
  physics.reset();
  final sign = forward ? 1.0 : -1.0;
  final data = <DataPoint>[];
  final maxDuration = maxVoltage / rampRate;

  for (var t = 0.0; t <= maxDuration; t += dtSeconds) {
    final voltage = sign * rampRate * t;
    if (voltage.abs() >= maxVoltage) break;

    physics.step(voltage, dtSeconds);

    final velocity = physics.noisyVelocityRpm;
    final position = physics.noisyPositionRotations;

    data.add(DataPoint(
      timestamp: t,
      voltage: voltage,
      velocity: velocity,
      position: position,
      current: physics.outputCurrentAmps,
    ));
  }

  return TestRun(
    id: 'qs_${forward ? "fwd" : "rev"}',
    startTime: DateTime.now(),
    mechanismType: MechanismType.flywheel,
    testType:
        forward ? TestType.quasistaticForward : TestType.quasistaticReverse,
    data: data,
    durationSeconds: maxDuration,
    testParams: SysIdTestParams.forMechanism(MechanismType.flywheel),
  );
}

/// Simulate the test runner's dynamic step test.
TestRun _simulateDynamic({
  required FlywheelPhysics physics,
  required bool forward,
  double stepVoltage = 7.0,
  double durationSeconds = 3.0,
  double dtSeconds = 0.010,
}) {
  physics.reset();
  final sign = forward ? 1.0 : -1.0;
  final voltage = sign * stepVoltage;
  final data = <DataPoint>[];

  for (var t = 0.0; t <= durationSeconds; t += dtSeconds) {
    physics.step(voltage, dtSeconds);

    final velocity = physics.noisyVelocityRpm;
    final position = physics.noisyPositionRotations;

    data.add(DataPoint(
      timestamp: t,
      voltage: voltage,
      velocity: velocity,
      position: position,
      current: physics.outputCurrentAmps,
    ));
  }

  return TestRun(
    id: 'dyn_${forward ? "fwd" : "rev"}',
    startTime: DateTime.now(),
    mechanismType: MechanismType.flywheel,
    testType: forward ? TestType.dynamicForward : TestType.dynamicReverse,
    data: data,
    durationSeconds: durationSeconds,
    testParams: SysIdTestParams.forMechanism(MechanismType.flywheel),
  );
}

void main() {
  group('Flywheel sysid roundtrip (no noise)', () {
    test('recovers ground-truth kS, kV, kA', () {
      final physics = FlywheelPhysics(noiseLevel: 0.0, randomSeed: 42);

      final qsFwd = _simulateQuasistatic(physics: physics, forward: true);
      final qsRev = _simulateQuasistatic(physics: physics, forward: false);
      final dynFwd = _simulateDynamic(physics: physics, forward: true);
      final dynRev = _simulateDynamic(physics: physics, forward: false);

      // Print sample counts for debugging
      // ignore: avoid_print
      print('QS fwd: ${qsFwd.data.length}, QS rev: ${qsRev.data.length}');
      // ignore: avoid_print
      print('Dyn fwd: ${dynFwd.data.length}, Dyn rev: ${dynRev.data.length}');

      final gains = FeedforwardAnalyzer.analyze(
        quasistaticRuns: [qsFwd, qsRev],
        dynamicRuns: [dynFwd, dynRev],
        mechanismType: MechanismType.flywheel,
      );

      // ignore: avoid_print
      print('Recovered: kS=${gains.kS}, kV=${gains.kV}, kA=${gains.kA}, '
          'R²=${gains.rSquared}');

      // Ground truth: kS=0.14, kV=0.0185, kA=0.003
      expect(gains.kS, closeTo(0.14, 0.02));
      expect(gains.kV, closeTo(0.0185, 0.002));
      expect(gains.kA, closeTo(0.003, 0.001));
      expect(gains.rSquared, greaterThan(0.95));
    });
  });

  group('Flywheel sysid roundtrip (with noise)', () {
    test('recovers ground-truth kS, kV, kA', () {
      final physics = FlywheelPhysics(noiseLevel: 0.015, randomSeed: 42);

      final qsFwd = _simulateQuasistatic(physics: physics, forward: true);
      final qsRev = _simulateQuasistatic(physics: physics, forward: false);
      final dynFwd = _simulateDynamic(physics: physics, forward: true);
      final dynRev = _simulateDynamic(physics: physics, forward: false);

      final gains = FeedforwardAnalyzer.analyze(
        quasistaticRuns: [qsFwd, qsRev],
        dynamicRuns: [dynFwd, dynRev],
        mechanismType: MechanismType.flywheel,
      );

      // ignore: avoid_print
      print('Recovered (noisy): kS=${gains.kS}, kV=${gains.kV}, '
          'kA=${gains.kA}, R²=${gains.rSquared}');

      // Wider tolerances for noisy case
      expect(gains.kS, closeTo(0.14, 0.05));
      expect(gains.kV, closeTo(0.0185, 0.003));
      expect(gains.kA, closeTo(0.003, 0.002));
      expect(gains.rSquared, greaterThan(0.90));
    });
  });
}
