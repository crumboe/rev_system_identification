/// Validation test runner: runs closed-loop step response tests using the
/// computed PID + FeedForward gains to verify that the identified model
/// produces good real (or simulated) control performance.
///
/// Supports three modes:
///   - **Velocity step**: commands a target RPM and records the response.
///   - **Position step**: commands a target position and records the response.
///   - **MAXMotion position**: uses the SPARK MAXMotion profiled position
///     controller with configurable cruise velocity, acceleration, and jerk.
library;

import 'dart:async';

import '../data/test_data.dart';
import '../devices/device_manager.dart';
import '../mechanisms/mechanism.dart';

// ---------------------------------------------------------------------------
// Validation test types
// ---------------------------------------------------------------------------

/// The kind of closed-loop validation test to run.
enum ValidationMode {
  velocity,
  position,
  disturbancePosition,
  maxMotionPosition,
}

/// Parameters for a validation test.
class ValidationParams {
  /// Target velocity in user velocity units.
  ///
  /// Flywheel: RPM (e.g. 1000).  Arm: deg/s (e.g. 90).  Elevator: m/s or
  /// in/s depending on config (e.g. 0.15 m/s).
  final double velocitySetpoint;

  /// Target position in user position units.
  ///
  /// Arm: degrees (e.g. 45).  Elevator: meters or inches (e.g. 0.3 m).
  /// Not used for flywheel.
  final double positionSetpoint;

  /// How long to hold the setpoint (seconds).
  final double holdDuration;

  /// How long to record after releasing the setpoint (seconds).
  final double settleDuration;

  /// MAXMotion profile configuration (null = use standard PID control).
  final MAXMotionConfig? maxMotionConfig;

  const ValidationParams({
    this.velocitySetpoint = 1000.0,
    this.positionSetpoint = 0.5,
    this.holdDuration = 3.0,
    this.settleDuration = 1.0,
    this.maxMotionConfig,
  });

  /// Sensible defaults for each mechanism type.
  factory ValidationParams.forMechanism(
    MechanismType type, {
    bool imperial = false,
  }) {
    return switch (type) {
      MechanismType.flywheel => const ValidationParams(
        velocitySetpoint: 500.0, // RPM
        positionSetpoint: 5.0, // rotations
        holdDuration: 3.0,
        settleDuration: 2.0,
      ),
      MechanismType.arm => const ValidationParams(
        velocitySetpoint: 90.0, // deg/s
        positionSetpoint: 45.0, // degrees
        holdDuration: 3.0,
        settleDuration: 1.0,
      ),
      MechanismType.elevator => ValidationParams(
        velocitySetpoint: imperial ? 6.0 : 0.15, // in/s or m/s
        positionSetpoint: imperial ? 12.0 : 0.3, // inches or meters
        holdDuration: 3.0,
        settleDuration: 1.0,
      ),
      MechanismType.simple => const ValidationParams(
        velocitySetpoint: 500.0, // RPM
        positionSetpoint: 5.0, // rotations
        holdDuration: 3.0,
        settleDuration: 1.0,
      ),
    };
  }

  ValidationParams copyWith({
    double? velocitySetpoint,
    double? positionSetpoint,
    double? holdDuration,
    double? settleDuration,
    MAXMotionConfig? maxMotionConfig,
  }) {
    return ValidationParams(
      velocitySetpoint: velocitySetpoint ?? this.velocitySetpoint,
      positionSetpoint: positionSetpoint ?? this.positionSetpoint,
      holdDuration: holdDuration ?? this.holdDuration,
      settleDuration: settleDuration ?? this.settleDuration,
      maxMotionConfig: maxMotionConfig ?? this.maxMotionConfig,
    );
  }
}

// ---------------------------------------------------------------------------
// MAXMotion configuration
// ---------------------------------------------------------------------------

/// Configuration for a MAXMotion trapezoidal/S-curve position profile.
///
/// All velocity and acceleration values are in **user units** — they will be
/// converted to native RPM / RPM-per-second before being written to the
/// controller.
class MAXMotionConfig {
  /// Maximum velocity during the cruise phase (user velocity units).
  final double cruiseVelocity;

  /// Maximum acceleration (user velocity units / second).
  final double maxAcceleration;

  /// Maximum jerk for S-curve profiling (user velocity units / s²).
  /// Set to 0 for trapezoidal profiling.
  final double maxJerk;

  /// Allowed closed-loop error at the target (user position units).
  /// The controller considers the profile complete when error is within this.
  final double allowedError;

  /// Position mode: 0 = trapezoidal, 1 = S-curve.
  final int positionMode;

  const MAXMotionConfig({
    required this.cruiseVelocity,
    required this.maxAcceleration,
    this.maxJerk = 0.0,
    this.allowedError = 0.0,
    this.positionMode = 0,
  });

  MAXMotionConfig copyWith({
    double? cruiseVelocity,
    double? maxAcceleration,
    double? maxJerk,
    double? allowedError,
    int? positionMode,
  }) {
    return MAXMotionConfig(
      cruiseVelocity: cruiseVelocity ?? this.cruiseVelocity,
      maxAcceleration: maxAcceleration ?? this.maxAcceleration,
      maxJerk: maxJerk ?? this.maxJerk,
      allowedError: allowedError ?? this.allowedError,
      positionMode: positionMode ?? this.positionMode,
    );
  }
}

// ---------------------------------------------------------------------------
// Progress / result types
// ---------------------------------------------------------------------------

/// Progress callback payload during a validation test.
class ValidationProgress {
  final double elapsedSeconds;
  final double setpoint;
  final double measured;
  final double velocity;
  final double position;
  final double voltage;
  final double current;
  final int sampleCount;
  final String? message;

  const ValidationProgress({
    required this.elapsedSeconds,
    required this.setpoint,
    required this.measured,
    required this.velocity,
    required this.position,
    required this.voltage,
    required this.current,
    required this.sampleCount,
    this.message,
  });
}

/// Result of a validation test.
class ValidationResult {
  /// The recorded data points during the test.
  final List<DataPoint> data;

  /// Setpoint at each sample (for overlay plotting).
  final List<double> setpoints;

  /// Duration of the test.
  final double durationSeconds;

  /// Whether the test completed normally.
  final bool completed;

  /// Error message if something went wrong.
  final String? error;

  /// The mode that was tested.
  final ValidationMode mode;

  const ValidationResult({
    required this.data,
    required this.setpoints,
    required this.durationSeconds,
    required this.completed,
    required this.mode,
    this.error,
  });

  /// Rise time: time to first reach 90% of the commanded step from 10%,
  /// handling both upward and downward moves.
  double? get riseTime {
    if (data.isEmpty || setpoints.isEmpty) return null;
    final target = setpoints.first != 0 ? setpoints.first : setpoints.last;

    final initialMeasured = mode == ValidationMode.velocity
        ? data.first.velocity
        : data.first.position;
    final stepAmplitude = target - initialMeasured;
    if (stepAmplitude.abs() < 1e-9) return null;

    final threshold10 = initialMeasured + 0.1 * stepAmplitude;
    final threshold90 = initialMeasured + 0.9 * stepAmplitude;
    final rising = stepAmplitude > 0;

    double? t10;
    double? t90;

    for (var i = 0; i < data.length; i++) {
      final measured = mode == ValidationMode.velocity
          ? data[i].velocity
          : data[i].position;
      if (t10 == null &&
          (rising ? measured >= threshold10 : measured <= threshold10)) {
        t10 = data[i].timestamp;
      }
      if (t10 != null &&
          t90 == null &&
          (rising ? measured >= threshold90 : measured <= threshold90)) {
        t90 = data[i].timestamp;
        break;
      }
    }

    if (t10 != null && t90 != null) return t90 - t10;
    return null;
  }

  /// Steady-state error: average error over the last 20% of the hold period.
  double? get steadyStateError {
    if (data.isEmpty || setpoints.isEmpty) return null;
    // Find samples in the last 20% of the data
    final startIdx = (data.length * 0.8).toInt();
    if (startIdx >= data.length) return null;

    double sumError = 0;
    int count = 0;
    for (var i = startIdx; i < data.length; i++) {
      final measured = mode == ValidationMode.velocity
          ? data[i].velocity
          : data[i].position;
      sumError += (setpoints[i] - measured).abs();
      count++;
    }
    return count > 0 ? sumError / count : null;
  }

  /// Overshoot: excursion past the target in the step direction, as a
  /// percentage of step amplitude.
  double? get overshootPercent {
    if (data.isEmpty || setpoints.isEmpty) return null;
    final target = setpoints.first != 0 ? setpoints.first : setpoints.last;

    final initialMeasured = mode == ValidationMode.velocity
        ? data.first.velocity
        : data.first.position;
    final stepAmplitude = target - initialMeasured;
    if (stepAmplitude.abs() < 1e-9) return 0.0;

    double peak = initialMeasured;
    double valley = initialMeasured;
    for (final dp in data) {
      final measured = mode == ValidationMode.velocity
          ? dp.velocity
          : dp.position;
      if (measured > peak) peak = measured;
      if (measured < valley) valley = measured;
    }

    final overshootAmount = stepAmplitude > 0
        ? (peak - target).clamp(0.0, double.infinity)
        : (target - valley).clamp(0.0, double.infinity);

    return (overshootAmount / stepAmplitude.abs()) * 100.0;
  }
}

// ---------------------------------------------------------------------------
// Validation test runner
// ---------------------------------------------------------------------------

/// Runs closed-loop validation tests using the gains already written to
/// the controller (or stored in the simulated parameter API).
class ValidationRunner {
  final SparkDevice device;
  final MechanismConfig mechanismConfig;

  /// If true, validation will use the controller's currently stored
  /// PID/FF gains and skip rewriting them before each test.
  final bool useStoredControllerGains;

  /// Feedforward gains (in user units) to write before each test.
  /// If null, gains are not re-written (they must already be on the controller).
  final FeedforwardGains? feedforwardGains;

  /// Velocity PID gains (in user units) to write before a velocity test.
  final PidResult? velocityPidGains;

  /// Position PID gains (in user units) to write before a position test.
  final PidResult? positionPidGains;

  bool _abortRequested = false;
  bool _isRunning = false;

  bool get isRunning => _isRunning;
  double? _filteredCurrentAmps;
  double? _lastRawCurrentAmps;

  ValidationRunner({
    required this.device,
    required this.mechanismConfig,
    this.feedforwardGains,
    this.velocityPidGains,
    this.positionPidGains,
    this.useStoredControllerGains = false,
  });

  void abort() {
    _abortRequested = true;
  }

  void emergencyStop() {
    _abortRequested = true;
    try {
      device.control.stop();
      device.heartbeat.disable();
    } catch (_) {}
  }

  double _filterCurrentForDisplay(double rawAmps) {
    if (device.isSimulated) return rawAmps;

    var sample = rawAmps;
    if (sample <= 0.01 && (_lastRawCurrentAmps ?? 0.0) > 0.5) {
      sample = _lastRawCurrentAmps!;
    }
    _lastRawCurrentAmps = sample;

    const alpha = 0.20;
    final prev = _filteredCurrentAmps;
    final filtered = prev == null
        ? sample
        : (alpha * sample + (1 - alpha) * prev);
    _filteredCurrentAmps = filtered;
    return filtered;
  }

  // -------------------------------------------------------------------------
  // Controller preparation
  // -------------------------------------------------------------------------

  /// Write the appropriate PID + FeedForward gains to Slot 0 for a velocity
  /// test.  The controller's onboard conversion factors are set so that the
  /// SPARK firmware handles unit conversion internally.  Gains are written
  /// in user units (matching the identified plant model).
  Future<void> _prepareForVelocityTest() async {
    final ff = feedforwardGains;
    final pid = velocityPidGains;
    if (ff == null || pid == null) return;

    // Write conversion factors so the controller handles unit conversion.
    await device.parameters.setPositionConversionFactor(
      mechanismConfig.positionConversionFactor,
    );
    await device.parameters.setVelocityConversionFactor(
      mechanismConfig.velocityConversionFactor,
    );

    // Brief pause between conversion-factor writes and PID writes.
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // PID gains are in user units — no pre-scaling needed.
    await device.parameters.setPidSlot0(
      p: pid.kP,
      i: pid.kI,
      d: pid.kD,
      f: 0.0,
      iZone: pid.iZone,
    );
    await device.parameters.setAllowedClosedLoopError0(
      pid.allowedClosedLoopError,
    );

    // Brief pause between PID and FF writes.
    await Future<void>.delayed(const Duration(milliseconds: 10));

    double kG = 0.0;
    double kCos = 0.0;
    double kCosRatio = 0.0;
    if (mechanismConfig.type == MechanismType.elevator) {
      kG = ff.kG;
    } else if (mechanismConfig.type == MechanismType.arm) {
      kCos = ff.kG;
      // Position is in degrees (user units); kCosRatio converts to full
      // rotations for the cos() computation: cos(pos * kCosRatio * 2π).
      kCosRatio = 1.0 / 360.0;
    }

    // FeedForward gains are in user units — no pre-scaling needed.
    await device.parameters.setFeedForwardSlot0(
      kS: ff.kS,
      kV: ff.kV,
      kA: ff.kA,
      kG: kG,
      kCos: kCos,
      kCosRatio: kCosRatio,
    );
  }

  /// Write the appropriate PID + FeedForward gains to Slot 0 for a position
  /// test.  The controller's onboard conversion factors are set so that the
  /// SPARK firmware handles unit conversion internally.  Gains are written
  /// in user units (matching the identified plant model).
  Future<void> _prepareForPositionTest() async {
    final ff = feedforwardGains;
    final pid = positionPidGains;
    if (ff == null || pid == null) return;

    // Write conversion factors so the controller handles unit conversion.
    await device.parameters.setPositionConversionFactor(
      mechanismConfig.positionConversionFactor,
    );
    await device.parameters.setVelocityConversionFactor(
      mechanismConfig.velocityConversionFactor,
    );

    // Brief pause between conversion-factor writes and PID writes.
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // PID gains are in user units — no pre-scaling needed.
    await device.parameters.setPidSlot0(
      p: pid.kP,
      i: pid.kI,
      d: pid.kD,
      f: 0.0,
      iZone: pid.iZone,
      dFilter: pid.dFilter,
    );
    await device.parameters.setAllowedClosedLoopError0(
      pid.allowedClosedLoopError,
    );

    // Brief pause between PID and FF writes.
    await Future<void>.delayed(const Duration(milliseconds: 10));

    double kG = 0.0;
    double kCos = 0.0;
    double kCosRatio = 0.0;
    if (mechanismConfig.type == MechanismType.elevator) {
      kG = ff.kG;
    } else if (mechanismConfig.type == MechanismType.arm) {
      kCos = ff.kG;
      kCosRatio = 1.0 / 360.0;
    }

    // FeedForward gains are in user units — no pre-scaling needed.
    await device.parameters.setFeedForwardSlot0(
      kS: ff.kS,
      kV: ff.kV,
      kA: ff.kA,
      kG: kG,
      kCos: kCos,
      kCosRatio: kCosRatio,
    );
  }

  /// Write PID + FeedForward gains **and** MAXMotion profile parameters to
  /// Slot 0 for a MAXMotion position test.
  ///
  /// The position PID gains are written identically to a normal position
  /// test.  In addition the MAXMotion cruise velocity, max acceleration,
  /// max jerk, allowed error and position mode are written.
  ///
  /// With onboard conversion factors, values are written in user units
  /// and the controller handles conversion internally.
  Future<void> _prepareForMAXMotionTest(MAXMotionConfig config) async {
    // First write PID + FF gains exactly as for a normal position test.
    await _prepareForPositionTest();

    // Brief pause before MAXMotion parameter writes.
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // User-unit values go directly to the controller (onboard CFs active).
    await device.parameters.configureMAXMotionSlot0(
      cruiseVelocity: config.cruiseVelocity,
      maxAcceleration: config.maxAcceleration,
      maxJerk: config.maxJerk,
      allowedError: config.allowedError,
      positionMode: config.positionMode,
    );
  }

  /// Write only MAXMotion profile parameters to slot 0 while preserving the
  /// controller's existing PID/FF gains.
  Future<void> _prepareMAXMotionProfileOnly(MAXMotionConfig config) async {
    // Ensure conversion factors are on the controller.
    await device.parameters.setPositionConversionFactor(
      mechanismConfig.positionConversionFactor,
    );
    await device.parameters.setVelocityConversionFactor(
      mechanismConfig.velocityConversionFactor,
    );

    // Brief pause between conversion-factor and MAXMotion writes.
    await Future<void>.delayed(const Duration(milliseconds: 10));

    // User-unit values go directly to the controller (onboard CFs active).
    await device.parameters.configureMAXMotionSlot0(
      cruiseVelocity: config.cruiseVelocity,
      maxAcceleration: config.maxAcceleration,
      maxJerk: config.maxJerk,
      allowedError: config.allowedError,
      positionMode: config.positionMode,
    );
  }

  // -------------------------------------------------------------------------
  // Test methods
  // -------------------------------------------------------------------------

  /// Run a velocity step-response validation test.
  ///
  /// Writes a velocity setpoint to the controller and records the
  /// measured velocity over time.
  Future<ValidationResult> runVelocityTest({
    required ValidationParams params,
    void Function(ValidationProgress)? onProgress,
  }) async {
    return _runTest(
      mode: ValidationMode.velocity,
      params: params,
      onProgress: onProgress,
    );
  }

  /// Run a position step-response validation test.
  ///
  /// Writes a position setpoint to the controller and records the
  /// measured position over time.
  Future<ValidationResult> runPositionTest({
    required ValidationParams params,
    void Function(ValidationProgress)? onProgress,
  }) async {
    return _runTest(
      mode: ValidationMode.position,
      params: params,
      onProgress: onProgress,
    );
  }

  /// Run a MAXMotion profiled position test.
  ///
  /// Configures the SPARK's MAXMotion controller with cruise velocity,
  /// max acceleration, max jerk, and allowed error, then commands a
  /// profiled position setpoint and records the response.
  Future<ValidationResult> runMAXMotionPositionTest({
    required ValidationParams params,
    void Function(ValidationProgress)? onProgress,
  }) async {
    return _runTest(
      mode: ValidationMode.maxMotionPosition,
      params: params,
      onProgress: onProgress,
    );
  }

  /// Run an untimed disturbance position test.
  ///
  /// This behaves like a normal position hold test, but continues until
  /// manually aborted so external disturbances can be applied and observed.
  Future<ValidationResult> runDisturbancePositionTest({
    required ValidationParams params,
    void Function(ValidationProgress)? onProgress,
  }) async {
    return _runTest(
      mode: ValidationMode.disturbancePosition,
      params: params,
      onProgress: onProgress,
    );
  }

  Future<ValidationResult> _runTest({
    required ValidationMode mode,
    required ValidationParams params,
    void Function(ValidationProgress)? onProgress,
  }) async {
    if (_isRunning) {
      return ValidationResult(
        data: [],
        setpoints: [],
        durationSeconds: 0,
        completed: false,
        mode: mode,
        error: 'A test is already running.',
      );
    }

    _isRunning = true;
    _abortRequested = false;

    final data = <DataPoint>[];
    final setpoints = <double>[];
    final stopwatch = Stopwatch();
    bool completed = false;
    String? error;
    _filteredCurrentAmps = null;
    _lastRawCurrentAmps = null;

    final totalDuration = params.holdDuration + params.settleDuration;
    // Disturbance and MAXMotion tests run until manually stopped.
    final untimed =
        mode == ValidationMode.maxMotionPosition ||
        mode == ValidationMode.disturbancePosition;

    try {
      // Enable all periodic status frames so we get full telemetry.
      await device.parameters.enableAllStatusFrames();

      // Prepare controller settings for this test.
      if (!useStoredControllerGains) {
        // Write the appropriate gains to the controller for this test type.
        // This ensures the correct PID slot is active and gains are in native
        // (RPM / rotations) units as required by the SPARK CAN protocol.
        if (mode == ValidationMode.velocity) {
          await _prepareForVelocityTest();
        } else if (mode == ValidationMode.maxMotionPosition &&
            params.maxMotionConfig != null) {
          await _prepareForMAXMotionTest(params.maxMotionConfig!);
        } else {
          await _prepareForPositionTest();
        }
      } else if (mode == ValidationMode.maxMotionPosition &&
          params.maxMotionConfig != null) {
        // In stored-gains mode, still apply MAXMotion profile knobs from UI.
        await _prepareMAXMotionProfileOnly(params.maxMotionConfig!);
      }

      // Set fast frame rates so voltage, current, position, and velocity
      // telemetry arrive at their highest rate during the test.
      device.control.configureForSysId();

      // Allow the frame-rate configuration to settle before further writes.
      await Future<void>.delayed(const Duration(milliseconds: 25));

      // Set the closed-loop feedback sensor on the controller.
      await device.parameters.setClosedLoopFeedbackSensor(
        mechanismConfig.feedbackSensor.parameterValue,
      );

      // Start heartbeat with motor enabled.
      device.heartbeat.start(enabled: true);

      // Wait for status frames to start arriving.
      await Future.delayed(const Duration(milliseconds: 200));

      stopwatch.start();

      while (!_abortRequested) {
        final elapsed = stopwatch.elapsedMilliseconds / 1000.0;

        if (!untimed && elapsed >= totalDuration) {
          completed = true;
          break;
        }

        // Determine the setpoint for this instant.
        final inHoldPhase = elapsed < params.holdDuration;
        double setpoint;

        if (mode == ValidationMode.velocity) {
          setpoint = inHoldPhase ? params.velocitySetpoint : 0.0;
          // With onboard conversion factors, the controller accepts
          // setpoints in user units directly.
          device.control.setVelocity(setpoint);
        } else if (mode == ValidationMode.maxMotionPosition) {
          // MAXMotion profiled position: always command the target position.
          // The profile generation (trapezoidal / S-curve) is handled
          // on-controller using the parameters written during preparation.
          setpoint = params.positionSetpoint;
          device.control.setSmartMotion(setpoint);
        } else {
          // Position hold: always command the target position (including during
          // the settle phase so the mechanism holds still while we observe).
          setpoint = params.positionSetpoint;
          // With onboard conversion factors, the controller accepts
          // setpoints in user units directly.
          device.control.setPosition(setpoint);
        }

        // Read measured state from status frames.
        final status1 = device.connection.lastStatus1;
        final status2 = device.connection.lastStatus2;

        if (status1 != null) {
          // Status frames already report in user units (onboard CFs).
          final velocity = status1.velocityRpm;

          // Read position from the configured feedback sensor's status frame.
          final double rawPosition;
          if (mechanismConfig.feedbackSensor ==
              FeedbackSensor.absoluteEncoder) {
            rawPosition =
                device.connection.lastStatus5?.absoluteEncoderPosition ??
                (status2?.positionRotations ?? 0.0);
          } else {
            rawPosition = status2?.positionRotations ?? 0.0;
          }
          final position = rawPosition;

          // Compute applied voltage: use the physics-based commandedVoltage
          // for simulated devices (status0.appliedOutput is not updated in sim),
          // or fall back to busVoltage × appliedOutput for real devices.
          final appliedOutput =
              device.connection.lastStatus0?.appliedOutput ?? 0.0;
          final recordedVoltage = status1.busVoltage * appliedOutput;

          final dp = DataPoint(
            timestamp: elapsed,
            voltage: recordedVoltage,
            velocity: velocity,
            position: position,
            current: _filterCurrentForDisplay(status1.outputCurrentAmps),
          );
          data.add(dp);
          setpoints.add(setpoint);

          onProgress?.call(
            ValidationProgress(
              elapsedSeconds: elapsed,
              setpoint: setpoint,
              measured: mode == ValidationMode.velocity ? velocity : position,
              velocity: velocity,
              position: position,
              voltage: dp.voltage,
              current: dp.current,
              sampleCount: data.length,
            ),
          );
        }

        await Future.delayed(const Duration(milliseconds: 10));
      }
    } catch (e) {
      error = e.toString();
    } finally {
      stopwatch.stop();

      try {
        device.control.stop();
        device.control.restoreDefaultFrameRates();
        device.heartbeat.disable();
      } catch (_) {}

      _isRunning = false;
    }

    return ValidationResult(
      data: data,
      setpoints: setpoints,
      durationSeconds: stopwatch.elapsedMilliseconds / 1000.0,
      completed: completed,
      mode: mode,
      error: error,
    );
  }
}
