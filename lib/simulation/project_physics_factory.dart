/// Shared factory for building project-backed simulation physics.
///
/// This is used by both the standalone Simulate PID path and the
/// DeviceManager project simulation path so they remain physically identical.
library;

import '../data/test_data.dart';
import '../mechanisms/mechanism.dart';
import 'arm_physics.dart';
import 'elevator_physics.dart';
import 'flywheel_physics.dart';
import 'simulated_physics.dart';

/// Build mechanism physics from identified gains and mechanism config.
///
/// [noiseLevel] can be tuned by caller but defaults to app-standard 0.005.
SimulatedPhysics createProjectBackedPhysics({
  required FeedforwardGains gains,
  required MechanismConfig config,
  double noiseLevel = 0.005,
}) {
  final type = config.type;
  final vcf = config.velocityConversionFactor;
  final pcf = config.positionConversionFactor;
  final backlashSeverity = _lowInertiaBacklashSeverity(gains);

  return switch (type) {
    MechanismType.arm => () {
        // Arm physics integrates in deg/s. noisyVelocityRpm = degPerS / 6.
        final scale = (vcf > 0) ? vcf / 6.0 : 1.0;
        return ArmPhysics(
          kS: gains.kS,
          kV: gains.kV * scale,
          kA: (gains.kA > 0 ? gains.kA : 0.002) * scale,
          kG: gains.kG,
          backlashDeg: 2.0 * backlashSeverity,
          noiseLevel: noiseLevel,
        );
      }(),
    MechanismType.elevator => () {
        // Elevator physics integrates in in/s.
        final scale = (pcf > 0 && vcf > 0) ? vcf * 60.0 / pcf : 1.0;
        return ElevatorPhysics(
          kS: gains.kS,
          kV: gains.kV * scale,
          kA: (gains.kA > 0 ? gains.kA : 0.015) * scale,
          kG: gains.kG,
          inchesPerRotation: pcf > 0 ? pcf : 1.504,
          backlashInches: 0.35 * backlashSeverity,
          noiseLevel: noiseLevel,
        );
      }(),
    MechanismType.flywheel || MechanismType.simple => () {
        // Flywheel physics integrates in native RPM.
        final scale = vcf > 0 ? vcf : 1.0;
        return FlywheelPhysics(
          kS: gains.kS,
          kV: gains.kV * scale,
          kA: (gains.kA > 0 ? gains.kA : 0.003) * scale,
          backlashRotations: 0.3 * backlashSeverity,
          stictionExtraVolts: 0.45 * backlashSeverity,
          controlDelaySteps: (1 + 2 * backlashSeverity).round(),
          encoderPositionQuantumRot: 0.004 * backlashSeverity,
          encoderVelocityQuantumRpm: 8.0 * backlashSeverity,
          noiseLevel: noiseLevel,
        );
      }(),
  };
}

double _lowInertiaBacklashSeverity(FeedforwardGains gains) {
  if (gains.kV <= 1e-9 || gains.kA <= 0) return 0.0;
  final tau = gains.kA / gains.kV;
  final severity = (0.3 - tau) / 0.3;
  return severity.clamp(0.0, 1.0);
}
