/// Mechanism type definitions for system identification.
///
/// Each mechanism type defines its physical characteristics, which affects
/// how feedforward constants are computed and what safety constraints apply.
library;

/// Which feedback sensor the closed-loop controller reads from.
enum FeedbackSensor {
  /// Built-in primary encoder (Hall-effect / quadrature on the motor shaft).
  primaryEncoder,

  /// Absolute encoder (e.g. REV Through Bore Encoder in absolute mode).
  absoluteEncoder,
}

/// Human-readable labels for [FeedbackSensor].
extension FeedbackSensorX on FeedbackSensor {
  String get displayName => switch (this) {
        FeedbackSensor.primaryEncoder => 'Primary Encoder',
        FeedbackSensor.absoluteEncoder => 'Absolute Encoder',
      };

  /// Integer value written to SPARK parameter 9.
  int get parameterValue => switch (this) {
        FeedbackSensor.primaryEncoder => 0,
        FeedbackSensor.absoluteEncoder => 2,
      };

  /// Java REVLib enum name.
  String get javaName => switch (this) {
        FeedbackSensor.primaryEncoder => 'kPrimaryEncoder',
        FeedbackSensor.absoluteEncoder => 'kAbsoluteEncoder',
      };

  /// Python REVLib enum name.
  String get pythonName => switch (this) {
        FeedbackSensor.primaryEncoder => 'kPrimaryEncoder',
        FeedbackSensor.absoluteEncoder => 'kAbsoluteEncoder',
      };

  /// C++ REVLib enum name.
  String get cppName => switch (this) {
        FeedbackSensor.primaryEncoder => 'kPrimaryEncoder',
        FeedbackSensor.absoluteEncoder => 'kAbsoluteEncoder',
      };
}

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

  /// General mechanism with no gravity (turret, horizontal slide, etc.).
  /// Supports both velocity and position control.
  simple,
}

/// Extension methods on [MechanismType] for display and behavior.
extension MechanismTypeX on MechanismType {
  /// Human-readable name.
  String get displayName => switch (this) {
        MechanismType.arm => 'Arm',
        MechanismType.elevator => 'Elevator',
        MechanismType.flywheel => 'Flywheel',
        MechanismType.simple => 'Simple',
      };

  /// Whether this mechanism has a gravity component (kG).
  bool get hasGravity => this != MechanismType.flywheel && this != MechanismType.simple;

  /// Whether soft limits are required for safety.
  bool get requiresSoftLimits => this == MechanismType.arm || this == MechanismType.elevator;

  /// The form of gravity compensation.
  String get gravityDescription => switch (this) {
        MechanismType.arm => 'kG · cos(θ)',
        MechanismType.elevator => 'kG (constant)',
        MechanismType.flywheel => 'None',
        MechanismType.simple => 'None',
      };

  /// Default position unit label (metric).
  String get positionUnit => switch (this) {
        MechanismType.arm => 'degrees',
        MechanismType.elevator => 'meters',
        MechanismType.flywheel => 'rotations',
        MechanismType.simple => 'rotations',
      };

  /// Default velocity unit label (metric).
  String get velocityUnit => switch (this) {
        MechanismType.arm => 'deg/s',
        MechanismType.elevator => 'm/s',
        MechanismType.flywheel => 'RPM',
        MechanismType.simple => 'RPM',
      };

  /// Imperial position unit label.
  String get positionUnitImperial => switch (this) {
        MechanismType.arm => 'degrees',
        MechanismType.elevator => 'inches',
        MechanismType.flywheel => 'rotations',
        MechanismType.simple => 'rotations',
      };

  /// Imperial velocity unit label.
  String get velocityUnitImperial => switch (this) {
        MechanismType.arm => 'deg/s',
        MechanismType.elevator => 'in/s',
        MechanismType.flywheel => 'RPM',
        MechanismType.simple => 'RPM',
      };
}

/// Configuration for a specific mechanism under test.
class MechanismConfig {
  /// User-defined name for the system being tested (e.g. "Shooter Flywheel").
  final String systemName;

  /// The type of mechanism.
  final MechanismType type;

  /// Position conversion factor (encoder rotations → user units).
  ///
  /// For arms: rotations → degrees (e.g., 360 / gear_ratio).
  /// For elevators: rotations → meters or inches (e.g., spool_circumference / gear_ratio).
  /// For flywheels/simple: typically 1.0 (stay in rotations).
  final double positionConversionFactor;

  /// Velocity conversion factor (encoder RPM → user units/sec).
  final double velocityConversionFactor;

  /// Forward (positive direction) soft limit in user units.
  /// Only used for arms and elevators.
  final double? forwardSoftLimit;

  /// Reverse (negative direction) soft limit in user units.
  /// Only used for arms and elevators.
  final double? reverseSoftLimit;

  /// Use imperial units (inches) instead of metric (meters) for linear
  /// mechanisms.  Only affects elevator — arm stays in degrees, flywheel in
  /// rotations/RPM.
  final bool useImperialUnits;

  /// Whether the motor output should be inverted.
  final bool motorInverted;

  /// Motor type: brushed or brushless.
  final bool isBrushless;

  /// Smart current limit in amps.
  final double currentLimitAmps;

  /// Which feedback sensor the closed-loop controller uses.
  final FeedbackSensor feedbackSensor;

  /// Position unit for the current config (respects [useImperialUnits]).
  String get positionUnit => useImperialUnits
      ? type.positionUnitImperial
      : type.positionUnit;

  /// Velocity unit for the current config (respects [useImperialUnits]).
  String get velocityUnit => useImperialUnits
      ? type.velocityUnitImperial
      : type.velocityUnit;

  const MechanismConfig({
    required this.type,
    this.systemName = '',
    this.positionConversionFactor = 1.0,
    this.velocityConversionFactor = 1.0,
    this.forwardSoftLimit,
    this.reverseSoftLimit,
    this.useImperialUnits = false,
    this.motorInverted = false,
    this.isBrushless = true,
    this.currentLimitAmps = 40.0,
    this.feedbackSensor = FeedbackSensor.primaryEncoder,
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

    if (currentLimitAmps <= 0 || currentLimitAmps > 80) {
      errors.add('Current limit must be between 0 and 80 amps.');
    }

    return errors;
  }

  /// Create a copy with modified fields.
  MechanismConfig copyWith({
    MechanismType? type,
    String? systemName,
    double? positionConversionFactor,
    double? velocityConversionFactor,
    double? forwardSoftLimit,
    double? reverseSoftLimit,
    bool? useImperialUnits,
    bool? motorInverted,
    bool? isBrushless,
    double? currentLimitAmps,
    FeedbackSensor? feedbackSensor,
  }) {
    return MechanismConfig(
      type: type ?? this.type,
      systemName: systemName ?? this.systemName,
      positionConversionFactor:
          positionConversionFactor ?? this.positionConversionFactor,
      velocityConversionFactor:
          velocityConversionFactor ?? this.velocityConversionFactor,
      forwardSoftLimit: forwardSoftLimit ?? this.forwardSoftLimit,
      reverseSoftLimit: reverseSoftLimit ?? this.reverseSoftLimit,
      useImperialUnits: useImperialUnits ?? this.useImperialUnits,
      motorInverted: motorInverted ?? this.motorInverted,
      isBrushless: isBrushless ?? this.isBrushless,
      currentLimitAmps: currentLimitAmps ?? this.currentLimitAmps,
      feedbackSensor: feedbackSensor ?? this.feedbackSensor,
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

  /// Optional current threshold (A) to auto-stop a test.
  ///
  /// If non-null and motor current exceeds this value for ~50ms (5
  /// consecutive samples), the test is stopped with
  /// [TestStopReason.currentLimitTripped].  Useful for detecting hard-stop
  /// collisions and stall conditions.
  ///
  /// `null` means disabled.
  final double? currentTripAmps;

  const SysIdTestParams({
    this.quasistaticRampRate = 0.25,
    this.dynamicStepVoltage = 7.0,
    this.dynamicStepDuration = 2.0,
    this.maxTestVoltage = 12.0,
    this.velocityThreshold = 0.01,
    this.currentTripAmps,
  });

  /// Default params tuned for each mechanism type.
  factory SysIdTestParams.forMechanism(MechanismType type) {
    return switch (type) {
      MechanismType.arm => const SysIdTestParams(
          quasistaticRampRate: 0.25,
          dynamicStepVoltage: 4.0,
          dynamicStepDuration: 1.5,
          maxTestVoltage: 8.0,
          currentTripAmps: 30.0,
        ),
      MechanismType.elevator => const SysIdTestParams(
          quasistaticRampRate: 0.25,
          dynamicStepVoltage: 4.0,
          dynamicStepDuration: 1.5,
          maxTestVoltage: 8.0,
          currentTripAmps: 30.0,
        ),
      MechanismType.flywheel => const SysIdTestParams(
          quasistaticRampRate: 0.25,
          dynamicStepVoltage: 7.0,
          dynamicStepDuration: 3.0,
          maxTestVoltage: 12.0,
        ),
      MechanismType.simple => const SysIdTestParams(
          quasistaticRampRate: 0.25,
          dynamicStepVoltage: 6.0,
          dynamicStepDuration: 2.0,
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
    double? Function()? currentTripAmps,
  }) {
    return SysIdTestParams(
      quasistaticRampRate: quasistaticRampRate ?? this.quasistaticRampRate,
      dynamicStepVoltage: dynamicStepVoltage ?? this.dynamicStepVoltage,
      dynamicStepDuration: dynamicStepDuration ?? this.dynamicStepDuration,
      maxTestVoltage: maxTestVoltage ?? this.maxTestVoltage,
      velocityThreshold: velocityThreshold ?? this.velocityThreshold,
      currentTripAmps:
          currentTripAmps != null ? currentTripAmps() : this.currentTripAmps,
    );
  }
}
