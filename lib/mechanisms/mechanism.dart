/// Mechanism type definitions for system identification.
///
/// Each mechanism type defines its physical characteristics, which affects
/// how feedforward constants are computed and what safety constraints apply.
library;

/// The type of mechanism being characterized.
enum MechanismType {
  /// Rotating arm (pivots around a fixed point).
  /// Has gravity compensation: kG·cos(θ).
  arm,

  /// Linear elevator (moves up/down).
  /// Has constant gravity compensation: kG.
  elevator,

  /// Spinning flywheel (no gravity component).
  flywheel,
}

/// Extension methods on [MechanismType] for display and behavior.
extension MechanismTypeX on MechanismType {
  /// Human-readable name.
  String get displayName => switch (this) {
        MechanismType.arm => 'Arm',
        MechanismType.elevator => 'Elevator',
        MechanismType.flywheel => 'Flywheel',
      };

  /// Whether this mechanism has a gravity component (kG).
  bool get hasGravity => this != MechanismType.flywheel;

  /// Whether soft limits are required for safety.
  bool get requiresSoftLimits => this != MechanismType.flywheel;

  /// The form of gravity compensation.
  String get gravityDescription => switch (this) {
        MechanismType.arm => 'kG · cos(θ)',
        MechanismType.elevator => 'kG (constant)',
        MechanismType.flywheel => 'None',
      };

  /// Default position unit label.
  String get positionUnit => switch (this) {
        MechanismType.arm => 'degrees',
        MechanismType.elevator => 'inches',
        MechanismType.flywheel => 'rotations',
      };

  /// Default velocity unit label.
  String get velocityUnit => switch (this) {
        MechanismType.arm => 'deg/s',
        MechanismType.elevator => 'in/s',
        MechanismType.flywheel => 'RPM',
      };
}

/// Configuration for a specific mechanism under test.
class MechanismConfig {
  /// The type of mechanism.
  final MechanismType type;

  /// Gear ratio (output/input). > 1 means reduction.
  final double gearRatio;

  /// Position conversion factor (encoder rotations → user units).
  ///
  /// For arms: rotations → degrees (e.g., 360.0 / gearRatio).
  /// For elevators: rotations → inches (e.g., sprocketCircumference / gearRatio).
  /// For flywheels: typically 1.0 (stay in rotations or RPM).
  final double positionConversionFactor;

  /// Velocity conversion factor (encoder RPM → user units/sec).
  final double velocityConversionFactor;

  /// Forward (positive direction) soft limit in user units.
  /// Only used for arms and elevators.
  final double? forwardSoftLimit;

  /// Reverse (negative direction) soft limit in user units.
  /// Only used for arms and elevators.
  final double? reverseSoftLimit;

  /// Whether the motor output should be inverted.
  final bool motorInverted;

  /// Motor type: brushed or brushless.
  final bool isBrushless;

  /// Smart current limit in amps.
  final double currentLimitAmps;

  const MechanismConfig({
    required this.type,
    this.gearRatio = 1.0,
    this.positionConversionFactor = 1.0,
    this.velocityConversionFactor = 1.0,
    this.forwardSoftLimit,
    this.reverseSoftLimit,
    this.motorInverted = false,
    this.isBrushless = true,
    this.currentLimitAmps = 40.0,
  });

  /// Whether soft limits are fully configured.
  bool get hasSoftLimits =>
      forwardSoftLimit != null && reverseSoftLimit != null;

  /// Validates the configuration for the mechanism type.
  /// Returns a list of error messages (empty if valid).
  List<String> validate() {
    final errors = <String>[];

    if (type.requiresSoftLimits && !hasSoftLimits) {
      errors.add(
        '${type.displayName} requires soft limits for safe operation.',
      );
    }

    if (forwardSoftLimit != null &&
        reverseSoftLimit != null &&
        forwardSoftLimit! <= reverseSoftLimit!) {
      errors.add('Forward limit must be greater than reverse limit.');
    }

    if (gearRatio <= 0) {
      errors.add('Gear ratio must be positive.');
    }

    if (currentLimitAmps <= 0 || currentLimitAmps > 80) {
      errors.add('Current limit must be between 0 and 80 amps.');
    }

    return errors;
  }

  /// Create a copy with modified fields.
  MechanismConfig copyWith({
    MechanismType? type,
    double? gearRatio,
    double? positionConversionFactor,
    double? velocityConversionFactor,
    double? forwardSoftLimit,
    double? reverseSoftLimit,
    bool? motorInverted,
    bool? isBrushless,
    double? currentLimitAmps,
  }) {
    return MechanismConfig(
      type: type ?? this.type,
      gearRatio: gearRatio ?? this.gearRatio,
      positionConversionFactor:
          positionConversionFactor ?? this.positionConversionFactor,
      velocityConversionFactor:
          velocityConversionFactor ?? this.velocityConversionFactor,
      forwardSoftLimit: forwardSoftLimit ?? this.forwardSoftLimit,
      reverseSoftLimit: reverseSoftLimit ?? this.reverseSoftLimit,
      motorInverted: motorInverted ?? this.motorInverted,
      isBrushless: isBrushless ?? this.isBrushless,
      currentLimitAmps: currentLimitAmps ?? this.currentLimitAmps,
    );
  }
}

/// Default test parameters for system identification.
class SysIdTestParams {
  /// Voltage ramp rate for quasistatic tests (V/s).
  final double quasistaticRampRate;

  /// Step voltage for dynamic tests (V).
  final double dynamicStepVoltage;

  /// Duration of dynamic step tests (seconds).
  final double dynamicStepDuration;

  /// Maximum test voltage (safety limit).
  final double maxTestVoltage;

  /// Minimum velocity threshold to consider "moving" (user units/s).
  final double velocityThreshold;

  const SysIdTestParams({
    this.quasistaticRampRate = 0.25,
    this.dynamicStepVoltage = 7.0,
    this.dynamicStepDuration = 2.0,
    this.maxTestVoltage = 12.0,
    this.velocityThreshold = 0.01,
  });

  /// Default params tuned for each mechanism type.
  factory SysIdTestParams.forMechanism(MechanismType type) {
    return switch (type) {
      MechanismType.arm => const SysIdTestParams(
          quasistaticRampRate: 0.25,
          dynamicStepVoltage: 4.0,
          dynamicStepDuration: 1.5,
          maxTestVoltage: 8.0,
        ),
      MechanismType.elevator => const SysIdTestParams(
          quasistaticRampRate: 0.25,
          dynamicStepVoltage: 4.0,
          dynamicStepDuration: 1.5,
          maxTestVoltage: 8.0,
        ),
      MechanismType.flywheel => const SysIdTestParams(
          quasistaticRampRate: 0.25,
          dynamicStepVoltage: 7.0,
          dynamicStepDuration: 3.0,
          maxTestVoltage: 12.0,
        ),
    };
  }

  SysIdTestParams copyWith({
    double? quasistaticRampRate,
    double? dynamicStepVoltage,
    double? dynamicStepDuration,
    double? maxTestVoltage,
    double? velocityThreshold,
  }) {
    return SysIdTestParams(
      quasistaticRampRate: quasistaticRampRate ?? this.quasistaticRampRate,
      dynamicStepVoltage: dynamicStepVoltage ?? this.dynamicStepVoltage,
      dynamicStepDuration: dynamicStepDuration ?? this.dynamicStepDuration,
      maxTestVoltage: maxTestVoltage ?? this.maxTestVoltage,
      velocityThreshold: velocityThreshold ?? this.velocityThreshold,
    );
  }
}
