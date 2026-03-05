/// Validation test runner: runs closed-loop step response tests using the
/// computed PID + FeedForward gains to verify that the identified model
/// produces good real (or simulated) control performance.
///
/// Supports two modes:
///   - **Velocity step**: commands a target RPM and records the response.
///   - **Position step**: commands a target position and records the response.
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

  const ValidationParams({
    this.velocitySetpoint = 1000.0,
    this.positionSetpoint = 0.5,
    this.holdDuration = 3.0,
    this.settleDuration = 1.0,
  });

  /// Sensible defaults for each mechanism type.
  factory ValidationParams.forMechanism(
    MechanismType type, {
    bool imperial = false,
  }) {
    return switch (type) {
      MechanismType.flywheel => const ValidationParams(
          velocitySetpoint: 1000.0, // RPM
          positionSetpoint: 0,      // not used
          holdDuration: 3.0,
          settleDuration: 2.0,
        ),
      MechanismType.arm => const ValidationParams(
          velocitySetpoint: 90.0,   // deg/s
          positionSetpoint: 45.0,   // degrees
          holdDuration: 3.0,
          settleDuration: 1.0,
        ),
      MechanismType.elevator => ValidationParams(
          velocitySetpoint: imperial ? 6.0 : 0.15, // in/s or m/s
          positionSetpoint: imperial ? 12.0 : 0.3, // inches or meters
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
  }) {
    return ValidationParams(
      velocitySetpoint: velocitySetpoint ?? this.velocitySetpoint,
      positionSetpoint: positionSetpoint ?? this.positionSetpoint,
      holdDuration: holdDuration ?? this.holdDuration,
      settleDuration: settleDuration ?? this.settleDuration,
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
  final double voltage;
  final double current;
  final int sampleCount;
  final String? message;

  const ValidationProgress({
    required this.elapsedSeconds,
    required this.setpoint,
    required this.measured,
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

  /// Rise time: time to first reach 90% of setpoint from 10%.
  double? get riseTime {
    if (data.isEmpty || setpoints.isEmpty) return null;
    final sp = setpoints.first != 0 ? setpoints.first : setpoints.last;
    if (sp == 0) return null;

    final threshold10 = 0.1 * sp;
    final threshold90 = 0.9 * sp;

    double? t10;
    double? t90;

    for (var i = 0; i < data.length; i++) {
      final measured =
          mode == ValidationMode.velocity ? data[i].velocity : data[i].position;
      if (t10 == null && measured >= threshold10) {
        t10 = data[i].timestamp;
      }
      if (t10 != null && t90 == null && measured >= threshold90) {
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
      final measured =
          mode == ValidationMode.velocity ? data[i].velocity : data[i].position;
      sumError += (setpoints[i] - measured).abs();
      count++;
    }
    return count > 0 ? sumError / count : null;
  }

  /// Overshoot: maximum measured value above the setpoint, as a percentage.
  double? get overshootPercent {
    if (data.isEmpty || setpoints.isEmpty) return null;
    final sp = setpoints.first != 0 ? setpoints.first : setpoints.last;
    if (sp == 0) return null;

    double maxMeasured = 0;
    for (final dp in data) {
      final measured =
          mode == ValidationMode.velocity ? dp.velocity : dp.position;
      if (measured > maxMeasured) maxMeasured = measured;
    }

    if (maxMeasured > sp) {
      return ((maxMeasured - sp) / sp) * 100.0;
    }
    return 0.0;
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

  ValidationRunner({
    required this.device,
    required this.mechanismConfig,
    this.feedforwardGains,
    this.velocityPidGains,
    this.positionPidGains,
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

  // -------------------------------------------------------------------------
  // Controller preparation
  // -------------------------------------------------------------------------

  /// Write the appropriate PID + FeedForward gains to Slot 0 for a velocity
  /// test.  Gains are converted from user units to native RPM-based units
  /// before being written so the SPARK's internal PID operates correctly.
  ///
  /// The SPARK CAN protocol always uses RPM for velocity setpoints and
  /// rotations for position setpoints.  The stored gains are derived from
  /// user-unit data, so they must be scaled:
  ///   kP_native = kP_user × VCF (duty-cycle per RPM)
  ///   kV_native = kV_user × VCF (V per RPM)
  Future<void> _prepareForVelocityTest() async {
    final ff = feedforwardGains;
    final pid = velocityPidGains;
    if (ff == null || pid == null) return;

    final vcf = mechanismConfig.velocityConversionFactor;
    final pcf = mechanismConfig.positionConversionFactor;

    await device.parameters.setPidSlot0(
      p: pid.kP * vcf,
      i: pid.kI * vcf,
      d: pid.kD * vcf,
      f: 0.0,
    );

    double kG = 0.0;
    double kCos = 0.0;
    double kCosRatio = 0.0;
    if (mechanismConfig.type == MechanismType.elevator) {
      kG = ff.kG;
    } else if (mechanismConfig.type == MechanismType.arm) {
      kCos = ff.kG;
      kCosRatio = pcf / 360.0;
    }

    await device.parameters.setFeedForwardSlot0(
      kS: ff.kS,
      kV: ff.kV * vcf,
      kA: ff.kA * vcf,
      kG: kG,
      kCos: kCos,
      kCosRatio: kCosRatio,
    );
  }

  /// Write the appropriate PID + FeedForward gains to Slot 0 for a position
  /// test.  Position PID gains are scaled using PCF (rotations → user units):
  ///   kP_native = kP_user × PCF (duty-cycle per rotation)
  ///   kD_native = kD_user × PCF (duty-cycle per rot/s)
  Future<void> _prepareForPositionTest() async {
    final ff = feedforwardGains;
    final pid = positionPidGains;
    if (ff == null || pid == null) return;

    final vcf = mechanismConfig.velocityConversionFactor;
    final pcf = mechanismConfig.positionConversionFactor;

    await device.parameters.setPidSlot0(
      p: pid.kP * pcf,
      i: pid.kI * pcf,
      d: pid.kD * pcf,
      f: 0.0,
    );

    double kG = 0.0;
    double kCos = 0.0;
    double kCosRatio = 0.0;
    if (mechanismConfig.type == MechanismType.elevator) {
      kG = ff.kG;
    } else if (mechanismConfig.type == MechanismType.arm) {
      kCos = ff.kG;
      kCosRatio = pcf / 360.0;
    }

    await device.parameters.setFeedForwardSlot0(
      kS: ff.kS,
      kV: ff.kV * vcf,
      kA: ff.kA * vcf,
      kG: kG,
      kCos: kCos,
      kCosRatio: kCosRatio,
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

    final totalDuration = params.holdDuration + params.settleDuration;

    try {
      // Write the appropriate gains to the controller for this test type.
      // This ensures the correct PID slot is active and gains are in native
      // (RPM / rotations) units as required by the SPARK CAN protocol.
      if (mode == ValidationMode.velocity) {
        await _prepareForVelocityTest();
      } else {
        await _prepareForPositionTest();
      }

      // Start heartbeat with motor enabled.
      device.heartbeat.start(enabled: true);

      // Wait for status frames to start arriving.
      await Future.delayed(const Duration(milliseconds: 200));

      stopwatch.start();

      while (!_abortRequested) {
        final elapsed = stopwatch.elapsedMilliseconds / 1000.0;

        if (elapsed >= totalDuration) {
          completed = true;
          break;
        }

        // Determine the setpoint for this instant.
        final inHoldPhase = elapsed < params.holdDuration;
        double setpoint;

        if (mode == ValidationMode.velocity) {
          setpoint = inHoldPhase ? params.velocitySetpoint : 0.0;
          // Convert user velocity units to native RPM for the controller.
          // The SPARK CAN protocol always interprets velocity setpoints in RPM.
          final rpmSetpoint =
              mechanismConfig.velocityConversionFactor != 0
                  ? setpoint / mechanismConfig.velocityConversionFactor
                  : setpoint;
          device.control.setVelocity(rpmSetpoint);
        } else {
          // Position hold: always command the target position (including during
          // the settle phase so the mechanism holds still while we observe).
          setpoint = params.positionSetpoint;
          // Convert user position units to native rotations for the controller.
          // The SPARK CAN protocol always interprets position setpoints in rotations.
          final rotSetpoint =
              mechanismConfig.positionConversionFactor != 0
                  ? setpoint / mechanismConfig.positionConversionFactor
                  : setpoint;
          device.control.setPosition(rotSetpoint);
        }

        // Read measured state from status frames.
        final status1 = device.connection.lastStatus1;
        final status2 = device.connection.lastStatus2;

        if (status1 != null) {
          final velocity =
              status1.velocityRpm * mechanismConfig.velocityConversionFactor;
          final position = (status2?.positionRotations ?? 0.0) *
              mechanismConfig.positionConversionFactor;

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
            current: status1.outputCurrentAmps,
          );
          data.add(dp);
          setpoints.add(setpoint);

          onProgress?.call(ValidationProgress(
            elapsedSeconds: elapsed,
            setpoint: setpoint,
            measured:
                mode == ValidationMode.velocity ? velocity : position,
            voltage: dp.voltage,
            current: dp.current,
            sampleCount: data.length,
          ));
        }

        await Future.delayed(const Duration(milliseconds: 10));
      }
    } catch (e) {
      error = e.toString();
    } finally {
      stopwatch.stop();

      try {
        device.control.stop();
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
