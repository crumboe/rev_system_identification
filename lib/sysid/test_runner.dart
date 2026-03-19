/// System identification test runner.
///
/// Orchestrates quasistatic and dynamic tests: configures the controller,
/// manages the heartbeat, records data from status frames, and enforces
/// soft-limit safety.
library;

import 'dart:async';

import '../can/spark_protocol.dart';
import '../data/test_data.dart';
import '../devices/device_manager.dart';
import '../mechanisms/mechanism.dart';

/// Callback signature for test progress updates.
typedef TestProgressCallback = void Function(TestProgress progress);

/// Progress information emitted during a test.
class TestProgress {
  final double elapsedSeconds;
  final double currentVoltage;
  final double currentVelocity;
  final double currentPosition;
  final double currentCurrent;
  final int sampleCount;
  final bool softLimitWarning;
  final String? message;

  const TestProgress({
    required this.elapsedSeconds,
    required this.currentVoltage,
    required this.currentVelocity,
    required this.currentPosition,
    required this.currentCurrent,
    required this.sampleCount,
    this.softLimitWarning = false,
    this.message,
  });
}

/// Reason a test was stopped.
enum TestStopReason {
  completed,
  userAborted,
  softLimitReached,
  currentLimitTripped,
  errorOccurred,
  connectionLost,
}

/// Result of a test execution.
class TestExecutionResult {
  final TestRun? testRun;
  final TestStopReason stopReason;
  final String? errorMessage;

  const TestExecutionResult({
    this.testRun,
    required this.stopReason,
    this.errorMessage,
  });

  /// A test is successful if it completed normally OR if it ended because
  /// the mechanism reached a soft limit (which is the expected end condition
  /// for arm/elevator quasistatic tests).
  bool get success =>
      stopReason == TestStopReason.completed ||
      stopReason == TestStopReason.softLimitReached;
}

/// Runs system identification tests on a connected SPARK controller.
class TestRunner {
  final SparkDevice device;
  final MechanismConfig mechanismConfig;
  final SysIdTestParams testParams;
  final LoadCondition? loadCondition;
  final double? loadMassKg;

  bool _abortRequested = false;
  bool _isRunning = false;
  double? _filteredCurrentAmps;
  double? _lastRawCurrentAmps;
  double? _prevVoltage;

  bool get isRunning => _isRunning;

  TestRunner({
    required this.device,
    required this.mechanismConfig,
    required this.testParams,
    this.loadCondition,
    this.loadMassKg,
  });

  /// Request the current test to abort.
  void abort() {
    _abortRequested = true;
  }

  /// Emergency stop: immediately zero voltage and disable heartbeat.
  void emergencyStop() {
    _abortRequested = true;
    try {
      device.control.stop();
      device.heartbeat.disable();
    } catch (_) {}
  }

  double _filterCurrentForDisplay(double rawAmps) {
    if (device.isSimulated) return rawAmps;

    // Real devices can report current in bursty updates with occasional
    // zero-like dropouts between packets; hold/dropout-guard then smooth.
    var sample = rawAmps;
    if (sample <= 0.01 && (_lastRawCurrentAmps ?? 0.0) > 0.5) {
      sample = _lastRawCurrentAmps!;
    }
    _lastRawCurrentAmps = sample;

    const alpha = 0.20;
    final prev = _filteredCurrentAmps;
    final filtered = prev == null ? sample : (alpha * sample + (1 - alpha) * prev);
    _filteredCurrentAmps = filtered;
    return filtered;
  }

  // -----------------------------------------------------------------------
  // Test preparation
  // -----------------------------------------------------------------------

  /// Configure the controller for system identification testing.
  Future<void> _prepareController() async {
    final params = device.parameters;

    // Enable all periodic status frames so we get full telemetry.
    await params.enableAllStatusFrames();

    // Set motor type.
    await params.setMotorType(
      mechanismConfig.isBrushless ? kMotorTypeBrushless : kMotorTypeBrushed,
    );

    // Set idle mode to coast for accurate sysid data.
    await params.setIdleMode(kIdleModeCoast);

    // Clear any ramp rate (we want instant response for dynamic tests).
    await params.setOpenLoopRampRate(0.0);

    // Write the user's conversion factors to the controller so the
    // SPARK firmware applies them internally.  Status frames, PID error,
    // and setpoints all operate in user units on-controller.
    await params.setPositionConversionFactor(
        mechanismConfig.positionConversionFactor);
    await params.setVelocityConversionFactor(
        mechanismConfig.velocityConversionFactor);

    // Set motor inversion.
    await params.setMotorInverted(mechanismConfig.motorInverted);

    // Set current limit.
    await params.setSmartCurrentLimit(mechanismConfig.currentLimitAmps);

    // Set the closed-loop feedback sensor on the controller.
    await params.setClosedLoopFeedbackSensor(
      mechanismConfig.feedbackSensor.parameterValue,
    );

    // Configure soft limits if applicable.
    if (mechanismConfig.hasSoftLimits) {
      await params.configureSoftLimits(
        forwardLimit: mechanismConfig.forwardSoftLimit!,
        reverseLimit: mechanismConfig.reverseSoftLimit!,
      );
    } else {
      await params.disableSoftLimits();
    }

    // Set fast frame rates for data collection.
    device.control.configureForSysId();

    // Small delay for settings to take effect.
    await Future.delayed(const Duration(milliseconds: 100));
  }

  /// Restore controller to safe default settings after testing.
  Future<void> _restoreController() async {
    device.control.stop();
    device.control.restoreDefaultFrameRates();
    await device.parameters.setIdleMode(kIdleModeBrake);
  }

  // -----------------------------------------------------------------------
  // Quasistatic test
  // -----------------------------------------------------------------------

  /// Run a quasistatic (slow voltage ramp) test.
  ///
  /// Ramps voltage from 0 at [testParams.quasistaticRampRate] V/s in the
  /// direction specified by [testType].
  Future<TestExecutionResult> runQuasistaticTest(
    TestType testType, {
    TestProgressCallback? onProgress,
  }) async {
    assert(testType.isQuasistatic);
    return _runTest(testType, _quasistaticVoltageProfile, onProgress);
  }

  double _quasistaticVoltageProfile(
    TestType testType,
    double elapsedSeconds,
  ) {
    final sign = testType.voltageSign;
    final voltage = sign * testParams.quasistaticRampRate * elapsedSeconds;
    return voltage.clamp(-testParams.maxTestVoltage, testParams.maxTestVoltage);
  }

  // -----------------------------------------------------------------------
  // Dynamic test
  // -----------------------------------------------------------------------

  /// Run a dynamic (step voltage) test.
  ///
  /// Applies [testParams.dynamicStepVoltage] instantly for
  /// [testParams.dynamicStepDuration] seconds.
  Future<TestExecutionResult> runDynamicTest(
    TestType testType, {
    TestProgressCallback? onProgress,
  }) async {
    assert(testType.isDynamic);
    return _runTest(testType, _dynamicVoltageProfile, onProgress);
  }

  double _dynamicVoltageProfile(TestType testType, double elapsedSeconds) {
    final sign = testType.voltageSign;
    return sign * testParams.dynamicStepVoltage;
  }

  // -----------------------------------------------------------------------
  // Common test execution loop
  // -----------------------------------------------------------------------

  Future<TestExecutionResult> _runTest(
    TestType testType,
    double Function(TestType, double) voltageProfile,
    TestProgressCallback? onProgress,
  ) async {
    if (_isRunning) {
      return const TestExecutionResult(
        stopReason: TestStopReason.errorOccurred,
        errorMessage: 'A test is already running.',
      );
    }

    _isRunning = true;
    _abortRequested = false;

    final data = <DataPoint>[];
    final stopwatch = Stopwatch();
    TestStopReason stopReason = TestStopReason.completed;
    String? errorMessage;
    _filteredCurrentAmps = null;
    _lastRawCurrentAmps = null;
    _prevVoltage = null;

    // Consecutive over-current sample counter for debounced current trip.
    int overCurrentCount = 0;
    const overCurrentThreshold = 5; // ~50ms at 10ms loop rate

    try {
      // Prepare the controller — retry once on timeout since the first
      // attempt after connection can fail if the controller is still
      // initializing (e.g. status frame enables take time to process).
      try {
        await _prepareController();
      } catch (e) {
        // Brief pause then retry — the first attempt may have partially
        // configured the controller, making the second attempt succeed.
        await Future.delayed(const Duration(milliseconds: 250));
        if (_abortRequested) rethrow;
        await _prepareController();
      }

      // Clear faults before starting.
      await device.control.clearFaults();

      // Start heartbeat with motor enabled.
      device.heartbeat.start(enabled: true);

      // Send a zero-voltage command immediately so the controller sees
      // a valid setpoint alongside the first enabled heartbeats.  Some
      // firmware revisions won't fully arm until they receive both.
      device.control.setVoltage(0.0);

      // Wait for the controller to process the heartbeat and arm.
      await Future.delayed(const Duration(milliseconds: 200));

      // Verify status frames are flowing — if the controller didn't
      // start sending telemetry, the test would log zero data.
      if (!device.isSimulated) {
        var waitedMs = 0;
        while (device.connection.lastStatus1 == null && waitedMs < 500) {
          await Future.delayed(const Duration(milliseconds: 50));
          waitedMs += 50;
        }
        if (device.connection.lastStatus1 == null) {
          throw StateError(
            'No status frames received from controller after 700 ms. '
            'Check the USB connection and try again.',
          );
        }
      }

      stopwatch.start();

      // Main test loop — runs at approximately 10ms intervals.
      while (!_abortRequested) {
        final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;
        final status1 = device.connection.lastStatus1;
        final status2 = device.connection.lastStatus2;
        double? filteredCurrent;

        // Check if dynamic test duration exceeded.
        if (testType.isDynamic &&
            elapsedSeconds >= testParams.dynamicStepDuration) {
          break;
        }

        // Check if quasistatic voltage exceeds max.
        final targetVoltage = voltageProfile(testType, elapsedSeconds);
        if (testType.isQuasistatic &&
            targetVoltage.abs() >= testParams.maxTestVoltage) {
          break;
        }

        // Check soft limits (skip first 0.5s to let mechanism start).
        // Only check the limit in the test's travel direction — the
        // mechanism starts at/near one limit and moves toward the other.
        if (mechanismConfig.hasSoftLimits && elapsedSeconds > 0.5) {
          final pos = device.connection.lastStatus2?.positionRotations;
          final vel = device.connection.lastStatus1?.velocityRpm;
          if (pos != null && vel != null) {
            // Status frames already report in user units (onboard CFs).
            final userPos = pos;
            final userVel = vel;
            final fwdLimit = mechanismConfig.forwardSoftLimit!;
            final revLimit = mechanismConfig.reverseSoftLimit!;
            final margin = (fwdLimit - revLimit).abs() * 0.05; // 5% margin

            final hitForward = userPos >= fwdLimit - margin && userVel > 0;
            final hitReverse = userPos <= revLimit + margin && userVel < 0;

            // Forward tests end at the forward limit; reverse at reverse.
            if ((testType.isForward && hitForward) ||
                (!testType.isForward && hitReverse)) {
              stopReason = TestStopReason.softLimitReached;
              break;
            }
          }
        }

        // Check current trip (skip first 0.3s — inrush grace period).
        if (testParams.currentTripAmps != null && elapsedSeconds > 0.3) {
          final rawCurrent = status1?.outputCurrentAmps ?? 0.0;
          final currentAmps = _filterCurrentForDisplay(rawCurrent);
          filteredCurrent = currentAmps;
          if (currentAmps > testParams.currentTripAmps!) {
            overCurrentCount++;
            if (overCurrentCount >= overCurrentThreshold) {
              stopReason = TestStopReason.currentLimitTripped;
              errorMessage =
                  'Current exceeded ${testParams.currentTripAmps!.toStringAsFixed(1)} A '
                  '(measured ${currentAmps.toStringAsFixed(1)} A)';
              break;
            }
          } else {
            overCurrentCount = 0;
          }
        }

        // Record data from latest status frames BEFORE applying this
        // iteration's voltage.  The current status frames reflect the
        // physics state produced by the PREVIOUS voltage command, so we
        // must pair them with that previous voltage to avoid a systematic
        // one-tick lead that inflates kS during the quasistatic ramp.
        if (status1 != null && _prevVoltage != null) {
          // Status frames already report in user units (onboard CFs).
          final velocity = status1.velocityRpm;
          final position = status2?.positionRotations ?? 0.0;
          final current =
              filteredCurrent ?? _filterCurrentForDisplay(status1.outputCurrentAmps);

          final dp = DataPoint(
            timestamp: elapsedSeconds,
            voltage: _prevVoltage!,
            velocity: velocity,
            position: position,
            current: current,
          );
          data.add(dp);
        }

        // Apply voltage for the next physics tick, then publish a live UI
        // update immediately using the commanded voltage. This keeps the
        // Run Tests screen responsive from the moment voltage begins rising,
        // while persisted samples remain paired to the previous command for
        // accurate system identification analysis.
        _prevVoltage = targetVoltage;
        device.control.setVoltage(targetVoltage);

        onProgress?.call(TestProgress(
          elapsedSeconds: elapsedSeconds,
          currentVoltage: targetVoltage,
          currentVelocity: status1?.velocityRpm ?? 0.0,
          currentPosition: status2?.positionRotations ?? 0.0,
          currentCurrent: filteredCurrent ??
              _filteredCurrentAmps ??
              status1?.outputCurrentAmps ??
              0.0,
          sampleCount: data.length,
          softLimitWarning: false,
        ));

        // Wait ~10ms for next sample.
        await Future.delayed(const Duration(milliseconds: 10));
      }

      if (_abortRequested) {
        stopReason = TestStopReason.userAborted;
      }
    } catch (e) {
      stopReason = TestStopReason.errorOccurred;
      errorMessage = e.toString();
    } finally {
      stopwatch.stop();

      // Always stop the motor and disable.
      try {
        device.control.stop();
        device.heartbeat.disable();
        await _restoreController();
      } catch (_) {}

      _isRunning = false;
    }

    final testRun = TestRun(
      id: '${testType.name}_${DateTime.now().millisecondsSinceEpoch}',
      startTime: DateTime.now(),
      mechanismType: mechanismConfig.type,
      testType: testType,
      data: data,
      durationSeconds: stopwatch.elapsedMilliseconds / 1000.0,
      testParams: testParams,
      loadCondition: loadCondition,
      loadMassKg: loadMassKg,
    );

    return TestExecutionResult(
      testRun: testRun,
      stopReason: stopReason,
      errorMessage: errorMessage,
    );
  }

  // -----------------------------------------------------------------------
  // Full characterization workflow
  // -----------------------------------------------------------------------

  /// Run all four tests in sequence (quasistatic forward/reverse, dynamic
  /// forward/reverse) with pauses between them.
  ///
  /// Calls [onTestComplete] after each individual test, and [onProgress]
  /// during each test.
  Future<List<TestExecutionResult>> runFullCharacterization({
    TestProgressCallback? onProgress,
    void Function(TestType completed, TestExecutionResult result)?
        onTestComplete,
    Duration pauseBetweenTests = const Duration(seconds: 3),
  }) async {
    final results = <TestExecutionResult>[];

    const testOrder = [
      TestType.quasistaticForward,
      TestType.quasistaticReverse,
      TestType.dynamicForward,
      TestType.dynamicReverse,
    ];

    for (final testType in testOrder) {
      if (_abortRequested) break;

      final result = testType.isQuasistatic
          ? await runQuasistaticTest(testType, onProgress: onProgress)
          : await runDynamicTest(testType, onProgress: onProgress);

      results.add(result);
      onTestComplete?.call(testType, result);

      if (!result.success) break;

      // Pause between tests to let the mechanism settle.
      if (testType != testOrder.last) {
        await Future.delayed(pauseBetweenTests);
      }
    }

    return results;
  }
}
