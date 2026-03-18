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
  final armScale = _armScaleFromConfig(config);
  final flywheelScale = _flywheelScaleFromConfig(config);
  final elevatorScale = _elevatorScaleFromConfig(config);
  final adjustedForSeverity = type == MechanismType.arm && armScale != null
      ? FeedforwardGains(
          kS: gains.kS,
          kV: gains.kV,
          kA: gains.kA * armScale.inertiaScale,
          kG: gains.kG * armScale.gravityScale,
        )
      : gains;
  final backlashSeverity = _lowInertiaBacklashSeverity(adjustedForSeverity);

  return switch (type) {
    MechanismType.arm => () {
        // Arm physics integrates in deg/s. noisyVelocityRpm = degPerS / 6.
        final scale = (vcf > 0) ? vcf / 6.0 : 1.0;
        final kSScale = armScale?.kSScale ?? 1.0;
        final kAScale = armScale?.inertiaScale ?? 1.0;
        final kGScale = armScale?.gravityScale ?? 1.0;
        final armBacklashSeverity = backlashSeverity * 0.35;
        return ArmPhysics(
          kS: gains.kS * kSScale,
          kV: gains.kV * scale,
          kA: (gains.kA > 0 ? gains.kA : 0.002) * scale * kAScale,
          kG: gains.kG * kGScale,
          inertiaMultiplier: 1.0,
          degreesPerRotation: pcf > 0 ? pcf : 360.0,
          backlashDeg: 2.0 * armBacklashSeverity,
          noiseLevel: noiseLevel,
        );
      }(),
    MechanismType.elevator => () {
        // Elevator physics integrates in in/s.
        final scale = (pcf > 0 && vcf > 0) ? vcf * 60.0 / pcf : 1.0;
        final kAScale = elevatorScale?.inertiaScale ?? 1.0;
        final kGScale = elevatorScale?.gravityScale ?? 1.0;
        return ElevatorPhysics(
          kS: gains.kS,
          kV: gains.kV * scale,
          kA: (gains.kA > 0 ? gains.kA : 0.015) * scale * kAScale,
          kG: gains.kG * kGScale,
          inchesPerRotation: pcf > 0 ? pcf : 1.504,
          backlashInches: 0.35 * backlashSeverity,
          noiseLevel: noiseLevel,
        );
      }(),
    MechanismType.flywheel || MechanismType.simple => () {
        // Flywheel physics integrates in native RPM.
        final scale = vcf > 0 ? vcf : 1.0;
        final fwInertiaScale = flywheelScale?.inertiaScale ?? 1.0;
        return FlywheelPhysics(
          kS: gains.kS,
          kV: gains.kV * scale,
          kA: (gains.kA > 0 ? gains.kA : 0.003) * scale * fwInertiaScale,
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

({double inertiaScale, double gravityScale, double kSScale})?
    _armScaleFromConfig(MechanismConfig config) {
  final massLbs = config.simulatedArmMassLbs;
  final lengthIn = config.simulatedArmLengthIn;
  if (massLbs != null && lengthIn != null && massLbs > 0 && lengthIn > 0) {
    // Reference profile: 10 lb, 20 in arm => scales of 1.0.
    final massRatio = massLbs / 10.0;
    final lengthRatio = lengthIn / 20.0;

    // I scales with m * L^2 for a simple arm model.
    final inertiaScale =
        (massRatio * lengthRatio * lengthRatio).clamp(0.2, 12.0);

    // Gravity torque scales with m * L.
    final gravityScale = (massRatio * lengthRatio).clamp(0.2, 12.0);

    // Coulomb friction typically changes less than inertia/gravity.
    final kSScale = (0.85 + 0.15 * gravityScale).clamp(0.6, 2.0);

    return (
      inertiaScale: inertiaScale,
      gravityScale: gravityScale,
      kSScale: kSScale,
    );
  }
  return null;
}

double _lowInertiaBacklashSeverity(FeedforwardGains gains) {
  if (gains.kV <= 1e-9 || gains.kA <= 0) return 0.0;
  final tau = gains.kA / gains.kV;
  final severity = (0.3 - tau) / 0.3;
  return severity.clamp(0.0, 1.0);
}

/// Scale flywheel inertia (kA) based on user-specified mass and radius.
///
/// Reference flywheel: 1.0 kg, 0.05 m radius.
/// I = 0.5 * m * r^2, so inertiaScale = (m/m_ref) * (r/r_ref)^2.
/// If only one parameter is provided, the other uses its reference default.
({double inertiaScale})? _flywheelScaleFromConfig(MechanismConfig config) {
  final massKg = config.simulatedFlywheelMassKg;
  final radiusM = config.simulatedFlywheelRadiusM;
  if (massKg == null && radiusM == null) return null;
  final m = (massKg != null && massKg > 0) ? massKg : 1.0;
  final r = (radiusM != null && radiusM > 0) ? radiusM : 0.05;
  final massRatio = m / 1.0;
  final radiusRatio = r / 0.05;
  final inertiaScale =
      (massRatio * radiusRatio * radiusRatio).clamp(0.1, 50.0);
  return (inertiaScale: inertiaScale);
}

/// Scale elevator inertia (kA) and gravity (kG) based on carriage mass.
///
/// Reference carriage: 5.0 kg.
/// kA scales linearly with mass; kG scales linearly with mass.
({double inertiaScale, double gravityScale})?
    _elevatorScaleFromConfig(MechanismConfig config) {
  final massKg = config.simulatedElevatorCarriageMassKg;
  if (massKg != null && massKg > 0) {
    final massRatio = massKg / 5.0;
    final inertiaScale = massRatio.clamp(0.1, 20.0);
    final gravityScale = massRatio.clamp(0.1, 20.0);
    return (inertiaScale: inertiaScale, gravityScale: gravityScale);
  }
  return null;
}

/// Convert a simulated load mass (kg) to a loadTorqueVolts value for
/// arm or elevator physics.
///
/// The load voltage is proportional to (loadMassKg / referenceMassKg) × kG,
/// where kG is the physics gravity constant and referenceMassKg is the
/// configured mechanism mass (or the default reference mass).
///
/// For arms, the reference mass comes from [config.simulatedArmMassLbs]
/// converted to kg, defaulting to the 10 lb (4.536 kg) reference.
/// For elevators, [config.simulatedElevatorCarriageMassKg] or 5.0 kg.
///
/// Returns 0.0 for non-gravity mechanisms (flywheel/simple) or zero load.
double computeLoadTorqueVolts({
  required double loadMassKg,
  required MechanismConfig config,
  required SimulatedPhysics physics,
}) {
  if (loadMassKg <= 0) return 0.0;

  switch (config.type) {
    case MechanismType.arm:
      final refMassKg = (config.simulatedArmMassLbs ?? 10.0) / 2.2046;
      final kG = (physics is ArmPhysics) ? physics.kG : 0.80;
      return (loadMassKg / refMassKg) * kG;

    case MechanismType.elevator:
      final refMassKg = config.simulatedElevatorCarriageMassKg ?? 5.0;
      final kG = (physics is ElevatorPhysics) ? physics.kG : 0.55;
      return (loadMassKg / refMassKg) * kG;

    case MechanismType.flywheel:
    case MechanismType.simple:
      return 0.0;
  }
}
