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

  bool get success => stopReason == TestStopReason.completed;
}

/// Runs system identification tests on a connected SPARK controller.
class TestRunner {
  final SparkDevice device;
  final MechanismConfig mechanismConfig;
  final SysIdTestParams testParams;

  bool _abortRequested = false;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  TestRunner({
    required this.device,
    required this.mechanismConfig,
    required this.testParams,
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

  // -----------------------------------------------------------------------
  // Test preparation
  // -----------------------------------------------------------------------

  /// Configure the controller for system identification testing.
  Future<void> _prepareController() async {
    final params = device.parameters;

    // Set motor type.
    await params.setMotorType(
      mechanismConfig.isBrushless ? kMotorTypeBrushless : kMotorTypeBrushed,
    );

    // Set idle mode to coast for accurate sysid data.
    await params.setIdleMode(kIdleModeCoast);

    // Clear any ramp rate (we want instant response for dynamic tests).
    await params.setOpenLoopRampRate(0.0);

    // Set conversion factors.
    await params.setPositionConversionFactor(
      mechanismConfig.positionConversionFactor,
    );
    await params.setVelocityConversionFactor(
      mechanismConfig.velocityConversionFactor,
    );

    // Set motor inversion.
    await params.setMotorInverted(mechanismConfig.motorInverted);

    // Set current limit.
    await params.setSmartCurrentLimit(mechanismConfig.currentLimitAmps);

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

    try {
      await _prepareController();

      // Clear faults before starting.
      await device.control.clearFaults();

      // Start heartbeat with motor enabled.
      device.heartbeat.start(enabled: true);

      // Wait for status frames to start arriving.
      await Future.delayed(const Duration(milliseconds: 200));

      stopwatch.start();

      // Main test loop — runs at approximately 10ms intervals.
      while (!_abortRequested) {
        final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000.0;

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

        // Check soft limits.
        if (mechanismConfig.hasSoftLimits) {
          final pos = device.connection.lastStatus2?.positionRotations;
          if (pos != null) {
            final userPos = pos * mechanismConfig.positionConversionFactor;
            final fwdLimit = mechanismConfig.forwardSoftLimit!;
            final revLimit = mechanismConfig.reverseSoftLimit!;
            final margin = (fwdLimit - revLimit).abs() * 0.05; // 5% margin

            if (userPos >= fwdLimit - margin ||
                userPos <= revLimit + margin) {
              stopReason = TestStopReason.softLimitReached;
              break;
            }
          }
        }

        // Apply voltage.
        device.control.setVoltage(targetVoltage);

        // Record data from latest status frames.
        final status1 = device.connection.lastStatus1;
        final status2 = device.connection.lastStatus2;

        if (status1 != null) {
          final velocity = status1.velocityRpm *
              mechanismConfig.velocityConversionFactor;
          final position = (status2?.positionRotations ?? 0.0) *
              mechanismConfig.positionConversionFactor;

          final dp = DataPoint(
            timestamp: elapsedSeconds,
            voltage: targetVoltage,
            velocity: velocity,
            position: position,
            current: status1.outputCurrentAmps,
          );
          data.add(dp);

          onProgress?.call(TestProgress(
            elapsedSeconds: elapsedSeconds,
            currentVoltage: targetVoltage,
            currentVelocity: velocity,
            currentPosition: position,
            currentCurrent: status1.outputCurrentAmps,
            sampleCount: data.length,
            softLimitWarning: false,
          ));
        }

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
