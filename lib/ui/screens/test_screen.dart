/// Test execution screen: run quasistatic/dynamic tests with real-time
/// data visualization and safety monitoring.
library;

import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_chart/fl_chart.dart';

import '../../data/test_data.dart';
import '../../devices/device_manager.dart';
import '../../mechanisms/mechanism.dart';
import '../../simulation/simulated_device.dart';
import '../../state/app_state.dart';
import '../../sysid/test_runner.dart';
import '../widgets/arm_visual.dart';
import '../widgets/chart_walkthrough.dart';
import '../widgets/chart_annotations.dart';
import '../widgets/elevator_visual.dart';
import '../widgets/jog_panel.dart';

class TestScreen extends ConsumerStatefulWidget {
  const TestScreen({super.key});

  @override
  ConsumerState<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends ConsumerState<TestScreen> {
  TestRunner? _runner;
  bool _isRunning = false;
  TestType? _currentTest;
  String _statusMessage = 'Ready to run tests.';
  bool _walkthroughActive = false;

  /// Current position in user units (degrees / inches / rotations),
  /// updated each progress tick for the mechanism visual.
  double _currentPosition = 0.0;

  /// Polls the encoder position from the device when idle.
  Timer? _positionPollTimer;

  /// Live telemetry preview data (rolling 10s window when idle).
  final List<DataPoint> _previewData = [];

  /// Wall-clock reference for preview telemetry timestamps.
  DateTime? _previewStartTime;

  /// Each inner list is one test's data. Segments are separated so charts
  /// render each test in a distinct color with no connecting line.
  final List<List<DataPoint>> _liveSegments = [];

  /// Whether a UI rebuild is already scheduled for a progress update.
  /// Used to coalesce rapid [_onProgress] callbacks into at most one
  /// [setState] per animation frame.
  bool _progressRebuildScheduled = false;

  /// Colors assigned to successive test segments.
  static final _segmentColors = [
    Colors.blue,
    Colors.orange,
    Colors.teal,
    Colors.magenta,
  ];

  void _startNewSegment() {
    _liveSegments.add(<DataPoint>[]);
  }

  /// Returns the segments to display in charts: preview data when idle,
  /// test data when running.
  bool get _hasTestData =>
      _isRunning || _liveSegments.any((s) => s.isNotEmpty);

  List<List<DataPoint>> get _chartSegments {
    if (_hasTestData) {
      return _liveSegments;
    }
    if (_previewData.isNotEmpty) {
      return [_previewData];
    }
    return const [];
  }

  @override
  void initState() {
    super.initState();
    // Poll the device position every 100ms so the visual tracks the encoder
    // even when a test is not running.
    _positionPollTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _pollPosition(),
    );
  }

  @override
  void dispose() {
    _positionPollTimer?.cancel();
    super.dispose();
  }

  void _pollPosition() {
    if (_isRunning) return; // test runner drives position during a run
    final device = ref.read(deviceManagerProvider).leader;
    if (device == null || !device.isConnected) return;

    final status0 = device.connection.lastStatus0;
    final status1 = device.connection.lastStatus1;
    final status2 = device.connection.lastStatus2;
    // Don't require status2 — voltage/current can be charted even without
    // a position frame (e.g. no motor connected, or Status 2 not yet received).
    if (status0 == null && status1 == null && status2 == null) return;

    // Status frames already report in user units (onboard CFs).
    final userPos = status2?.positionRotations ?? _currentPosition;

    // Build a preview data point from status frames.
    _previewStartTime ??= DateTime.now();
    final elapsed =
        DateTime.now().difference(_previewStartTime!).inMilliseconds / 1000.0;

    final velocity = status1?.velocityRpm ?? 0.0;
    final voltage = status1 != null
        ? status1.busVoltage * (status0?.appliedOutput ?? 0.0)
        : 0.0;
    final current = status1?.outputCurrentAmps ?? 0.0;

    _previewData.add(DataPoint(
      timestamp: elapsed,
      voltage: voltage,
      velocity: velocity,
      position: userPos,
      current: current,
    ));

    // Trim to a 10-second rolling window.
    final cutoff = elapsed - 10.0;
    _previewData.removeWhere((dp) => dp.timestamp < cutoff);

    if ((userPos - _currentPosition).abs() > 0.01 || _previewData.isNotEmpty) {
      setState(() => _currentPosition = userPos);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dm = ref.watch(deviceManagerProvider);
    final config = ref.watch(mechanismConfigProvider);
    final testParams = ref.watch(testParamsProvider);
    final device = dm.leader;
    final testRuns = ref.watch(testRunsProvider);

    final canRun = device != null &&
        device.isConnected &&
        !_isRunning &&
        config.validate().isEmpty;

    // Disable forward tests when position is at/above the forward soft limit,
    // and reverse tests when position is at/below the reverse soft limit.
    final atForwardLimit = config.forwardSoftLimit != null &&
        _currentPosition >= config.forwardSoftLimit!;
    final atReverseLimit = config.reverseSoftLimit != null &&
        _currentPosition <= config.reverseSoftLimit!;
    final canRunForward = canRun && !atForwardLimit;
    final canRunReverse = canRun && !atReverseLimit;

    return ScaffoldPage(
      header: PageHeader(
        title: const Text('Run Tests'),
        commandBar: CommandBar(
          mainAxisAlignment: MainAxisAlignment.end,
          primaryItems: [
            CommandBarButton(
              icon: Icon(
                FluentIcons.lightbulb,
                color: _walkthroughActive ? Colors.warningPrimaryColor : null,
              ),
              label: Text(_walkthroughActive ? 'Hide Guide' : 'Chart Guide'),
              onPressed: () =>
                  setState(() => _walkthroughActive = !_walkthroughActive),
            ),
            CommandBarButton(
              icon: const Icon(FluentIcons.stop, color: Colors.warningPrimaryColor),
              label: const Text('EMERGENCY STOP'),
              onPressed: _isRunning ? _emergencyStop : null,
            ),
          ],
        ),
      ),
      content: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status bar
            InfoBar(
              title: Text(_isRunning
                  ? 'Running: ${_currentTest?.displayName ?? ""}'
                  : 'Status'),
              content: Text(_statusMessage),
              severity: _isRunning
                  ? InfoBarSeverity.warning
                  : InfoBarSeverity.info,
            ),
            const SizedBox(height: 16),

            // Test buttons
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _TestButton(
                  label: 'Quasistatic Forward',
                  icon: FluentIcons.forward,
                  enabled: canRunForward,
                  completed: testRuns.any(
                      (r) => r.testType == TestType.quasistaticForward),
                  onPressed: () =>
                      _runSingleTest(TestType.quasistaticForward, device!, config, testParams),
                ),
                _TestButton(
                  label: 'Quasistatic Reverse',
                  icon: FluentIcons.back,
                  enabled: canRunReverse,
                  completed: testRuns.any(
                      (r) => r.testType == TestType.quasistaticReverse),
                  onPressed: () =>
                      _runSingleTest(TestType.quasistaticReverse, device!, config, testParams),
                ),
                _TestButton(
                  label: 'Dynamic Forward',
                  icon: FluentIcons.fast_forward,
                  enabled: canRunForward,
                  completed: testRuns
                      .any((r) => r.testType == TestType.dynamicForward),
                  onPressed: () =>
                      _runSingleTest(TestType.dynamicForward, device!, config, testParams),
                ),
                _TestButton(
                  label: 'Dynamic Reverse',
                  icon: FluentIcons.rewind,
                  enabled: canRunReverse,
                  completed: testRuns
                      .any((r) => r.testType == TestType.dynamicReverse),
                  onPressed: () =>
                      _runSingleTest(TestType.dynamicReverse, device!, config, testParams),
                ),
                const SizedBox(width: 16),
                FilledButton(
                  onPressed: canRunForward
                      ? () => _runFullCharacterization(device, config, testParams)
                      : null,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: Text('Run All Tests'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Live charts + mechanism visual
            Expanded(
              child: Row(
                children: [
                  // Charts area
                  Expanded(
                    flex: 3,
                    child: ChartWalkthrough(
                      isActive: _walkthroughActive,
                      steps: liveChartWalkthroughSteps(),
                      onDismiss: () =>
                          setState(() => _walkthroughActive = false),
                      child: Column(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                // Velocity chart
                                Expanded(
                                  child: _LiveChart(
                                    title: 'Velocity',
                                    segments: _chartSegments,
                                    segmentColors: _segmentColors,
                                    yExtractor: (dp) => dp.velocity,
                                    yLabel: config.velocityUnit,
                                    rollingWindow: _hasTestData ? null : 10.0,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Voltage chart
                                Expanded(
                                  child: _LiveChart(
                                    title: 'Voltage',
                                    segments: _chartSegments,
                                    segmentColors: _segmentColors,
                                    yExtractor: (dp) => dp.voltage,
                                    yLabel: 'V',
                                    rollingWindow: _hasTestData ? null : 10.0,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: Row(
                              children: [
                                // Position chart
                                Expanded(
                                  child: _LiveChart(
                                    title: 'Position',
                                    segments: _chartSegments,
                                    segmentColors: _segmentColors,
                                    yExtractor: (dp) => dp.position,
                                    yLabel: config.positionUnit,
                                    rollingWindow: _hasTestData ? null : 10.0,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Current chart
                                Expanded(
                                  child: _LiveChart(
                                    title: 'Current',
                                    segments: _chartSegments,
                                    segmentColors: _segmentColors,
                                    yExtractor: (dp) => dp.current,
                                    yLabel: 'A',
                                    rollingWindow: _hasTestData ? null : 10.0,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Mechanism visual panel (arm / elevator only)
                  if (config.type == MechanismType.arm) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 260,
                      child: Column(
                        children: [
                          Expanded(
                            child: ArmVisual(
                              currentAngleDeg: _currentPosition,
                              forwardLimitDeg: config.forwardSoftLimit,
                              reverseLimitDeg: config.reverseSoftLimit,
                              isDraggable: device != null && device.isSimulated && !_isRunning,
                              onAngleChanged: (deg) => _onDragPosition(device, config, deg),
                            ),
                          ),
                          if (device != null &&
                              device.isConnected) ...[
                            const SizedBox(height: 4),
                            SizedBox(
                              height: 190,
                              child: JogPanel(
                                device: device,
                                config: config,
                                enabled: !_isRunning,
                                onPositionChanged: (pos) =>
                                    setState(() => _currentPosition = pos),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  if (config.type == MechanismType.elevator) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 260,
                      child: Column(
                        children: [
                          Expanded(
                            child: ElevatorVisual(
                              currentPosition: _currentPosition,
                              forwardLimit: config.forwardSoftLimit,
                              reverseLimit: config.reverseSoftLimit,
                              unitLabel: config.useImperialUnits ? 'in' : 'm',
                              isDraggable: device != null && device.isSimulated && !_isRunning,
                              onPositionChanged: (pos) => _onDragPosition(device, config, pos),
                            ),
                          ),
                          if (device != null &&
                              device.isConnected) ...[
                            const SizedBox(height: 4),
                            SizedBox(
                              height: 190,
                              child: JogPanel(
                                device: device,
                                config: config,
                                enabled: !_isRunning,
                                onPositionChanged: (pos) =>
                                    setState(() => _currentPosition = pos),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                  // Flywheel / Simple: no visual, but show jog panel
                  if ((config.type == MechanismType.flywheel ||
                          config.type == MechanismType.simple) &&
                      device != null &&
                      device.isConnected) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 260,
                      child: JogPanel(
                        device: device,
                        config: config,
                        enabled: !_isRunning,
                        onPositionChanged: (pos) =>
                            setState(() => _currentPosition = pos),
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // Completed tests summary
            const SizedBox(height: 8),
            if (testRuns.isNotEmpty)
              Text(
                'Completed: ${testRuns.map((r) => r.testType.displayName).join(", ")}',
                style: const TextStyle(fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _runSingleTest(
    TestType testType,
    SparkDevice device,
    MechanismConfig config,
    SysIdTestParams testParams,
  ) async {
    // Pre-test safety confirmation for real hardware
    if (!device.isSimulated) {
      final confirmed = await _showPreTestConfirmation(device, config, testParams);
      if (!confirmed) return;
    }

    setState(() {
      _isRunning = true;
      _currentTest = testType;
      _liveSegments.clear();
      _previewData.clear();
      _previewStartTime = null;
      _startNewSegment();
      _statusMessage = 'Running ${testType.displayName}...';
    });

    _runner = TestRunner(
      device: device,
      mechanismConfig: config,
      testParams: testParams,
    );

    final result = testType.isQuasistatic
        ? await _runner!.runQuasistaticTest(
            testType,
            onProgress: _onProgress,
          )
        : await _runner!.runDynamicTest(
            testType,
            onProgress: _onProgress,
          );

    if (result.testRun != null) {
      ref.read(testRunsProvider.notifier).addRun(result.testRun!);
    }

    setState(() {
      _isRunning = false;
      _currentTest = null;
      _runner = null;
      _statusMessage = result.success
          ? '${testType.displayName} completed — '
              '${result.testRun!.sampleCount} samples in '
              '${result.testRun!.durationSeconds.toStringAsFixed(1)}s'
          : result.stopReason == TestStopReason.currentLimitTripped
              ? '\u26A0 Current limit tripped! Motor stopped for safety.'
                  '${result.errorMessage != null ? " ${result.errorMessage}" : ""}'
              : 'Test stopped: ${result.stopReason.name}'
                  '${result.errorMessage != null ? " — ${result.errorMessage}" : ""}';
    });
  }

  Future<void> _runFullCharacterization(
    SparkDevice device,
    MechanismConfig config,
    SysIdTestParams testParams,
  ) async {
    // Pre-test safety confirmation for real hardware
    if (!device.isSimulated) {
      final confirmed = await _showPreTestConfirmation(device, config, testParams);
      if (!confirmed) return;
    }

    setState(() {
      _isRunning = true;
      _statusMessage = 'Running full characterization...';
      _liveSegments.clear();
      _previewData.clear();
      _previewStartTime = null;
      _startNewSegment();
    });

    _runner = TestRunner(
      device: device,
      mechanismConfig: config,
      testParams: testParams,
    );

    final results = await _runner!.runFullCharacterization(
      onProgress: _onProgress,
      onTestComplete: (testType, result) {
        if (result.testRun != null) {
          ref.read(testRunsProvider.notifier).addRun(result.testRun!);
        }
        setState(() {
          _currentTest = testType;
          _statusMessage = '${testType.displayName}: ${result.stopReason.name}';
          // Start a new segment for the next test so it gets its own color.
          _startNewSegment();
        });
      },
    );

    final successCount = results.where((r) => r.success).length;

    setState(() {
      _isRunning = false;
      _currentTest = null;
      _runner = null;
      _statusMessage =
          'Characterization complete: $successCount/4 tests succeeded.';
    });
  }

  void _onProgress(TestProgress progress) {
    // Always append data immediately so nothing is lost.
    if (_liveSegments.isEmpty) _startNewSegment();
    _liveSegments.last.add(DataPoint(
      timestamp: progress.elapsedSeconds,
      voltage: progress.currentVoltage,
      velocity: progress.currentVelocity,
      position: progress.currentPosition,
      current: progress.currentCurrent,
    ));
    _currentPosition = progress.currentPosition;

    // Coalesce rebuilds: schedule at most one setState per frame so rapid
    // 10ms progress callbacks don't pile up redundant widget rebuilds.
    if (!_progressRebuildScheduled) {
      _progressRebuildScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _progressRebuildScheduled = false;
        if (mounted) setState(() {});
      });
    }
  }

  /// Shows a pre-test safety confirmation dialog for real hardware.
  /// Returns true if the user confirmed, false if cancelled.
  Future<bool> _showPreTestConfirmation(
    SparkDevice device,
    MechanismConfig config,
    SysIdTestParams testParams,
  ) async {
    final unit = config.positionUnit;
    final status2 = device.connection.lastStatus2;
    // Status frames already report in user units (onboard CFs).
    final currentPos = status2?.positionRotations;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return ContentDialog(
          title: const Text('Pre-Test Safety Check'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const InfoBar(
                title: Text('Real Hardware Detected'),
                content: Text(
                  'The motor will move during this test. Verify the '
                  'following before proceeding:',
                ),
                severity: InfoBarSeverity.warning,
                isLong: true,
              ),
              const SizedBox(height: 12),
              _checkItem('Area around the mechanism is clear'),
              _checkItem('Mechanism is free to move within soft limits'),
              _checkItem(
                'Soft limits are correctly configured '
                '(${config.reverseSoftLimit?.toStringAsFixed(1) ?? "?"} $unit '
                'to ${config.forwardSoftLimit?.toStringAsFixed(1) ?? "?"} $unit)',
              ),
              if (currentPos != null)
                _checkItem(
                  'Current position: ${currentPos.toStringAsFixed(1)} $unit',
                ),
              _checkItem(
                'Current trip: ${testParams.currentTripAmps != null ? "${testParams.currentTripAmps!.toStringAsFixed(0)} A" : "DISABLED"}',
              ),
              if (testParams.currentTripAmps == null &&
                  config.type.requiresSoftLimits)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: InfoBar(
                    title: Text('No current protection'),
                    content: Text(
                      'Current trip is disabled for a gravity-loaded '
                      'mechanism. Consider enabling it on the Config page.',
                    ),
                    severity: InfoBarSeverity.error,
                    isLong: true,
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'Max voltage: ${testParams.maxTestVoltage.toStringAsFixed(1)} V',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
          actions: [
            Button(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Start Test'),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  void _emergencyStop() {
    _runner?.emergencyStop();
    setState(() {
      _isRunning = false;
      _statusMessage = 'EMERGENCY STOP — motor disabled.';
    });
  }

  /// Called when the user drags the simulated mechanism visual.
  /// [userUnits] is degrees for arm, inches for elevator.
  void _onDragPosition(
    SparkDevice? device,
    MechanismConfig config,
    double userUnits,
  ) {
    if (device == null || !device.isSimulated) return;
    final conn = device.connection;
    if (conn is SimulatedSparkConnection) {
      // Convert user units back to rotations.
      final convFactor = config.positionConversionFactor;
      final rotations = convFactor != 0 ? userUnits / convFactor : 0.0;
      conn.physics.setPositionRotations(rotations);
      setState(() => _currentPosition = userUnits);
    }
  }
}

Widget _checkItem(String text) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Icon(FluentIcons.checkbox_composite, size: 14),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 12)),
        ),
      ],
    ),
  );
}

class _TestButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool enabled;
  final bool completed;
  final VoidCallback onPressed;

  const _TestButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.completed,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Button(
      onPressed: enabled ? onPressed : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (completed)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(FluentIcons.check_mark, size: 12, color: Colors.successPrimaryColor),
            ),
          Icon(icon, size: 14),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}

class _LiveChart extends StatelessWidget {
  final String title;
  final List<List<DataPoint>> segments;
  final List<Color> segmentColors;
  final double Function(DataPoint) yExtractor;
  final String yLabel;

  /// If non-null, the X axis uses a fixed window of this many seconds
  /// ending at the latest data point (rolling preview mode).
  final double? rollingWindow;

  const _LiveChart({
    required this.title,
    required this.segments,
    required this.segmentColors,
    required this.yExtractor,
    required this.yLabel,
    this.rollingWindow,
  });

  @override
  Widget build(BuildContext context) {
    // Build a separate line bar per segment so tests don't connect.
    final lineBars = <LineChartBarData>[];
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      if (seg.isEmpty) continue;
      lineBars.add(LineChartBarData(
        spots: seg.map((dp) => FlSpot(dp.timestamp, yExtractor(dp))).toList(),
        isCurved: false,
        color: segmentColors[i % segmentColors.length],
        barWidth: 1.5,
        dotData: const FlDotData(show: false),
      ));
    }

    // Compute X axis bounds.
    double? minX;
    double? maxX;
    if (rollingWindow != null && lineBars.isNotEmpty) {
      // Find the latest timestamp across all segments.
      double latest = 0;
      for (final bar in lineBars) {
        if (bar.spots.isNotEmpty && bar.spots.last.x > latest) {
          latest = bar.spots.last.x;
        }
      }
      maxX = latest;
      minX = latest - rollingWindow!;
      if (minX < 0) minX = 0;
    }

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$title ($yLabel)',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: lineBars.isEmpty
                ? const Center(child: Text('No data'))
                : LineChart(
                    LineChartData(
                      minX: minX ?? 0,
                      maxX: maxX,
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipItems: (touchedSpots) {
                            return touchedSpots.map((spot) {
                              return LineTooltipItem(
                                '${spot.y.toStringAsFixed(2)} $yLabel\n'
                                't=${spot.x.toStringAsFixed(1)}s',
                                const TextStyle(fontSize: 10),
                              );
                            }).toList();
                          },
                        ),
                      ),
                      lineBarsData: lineBars,
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        bottomTitles: AxisTitles(
                          axisNameWidget: const Text('Time (s)',
                              style: TextStyle(fontSize: 10)),
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
                            getTitlesWidget: (v, _) => Text(
                              v.toStringAsFixed(1),
                              style: const TextStyle(fontSize: 9),
                            ),
                          ),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 44,
                            getTitlesWidget: (v, _) => Text(
                              v.toStringAsFixed(1),
                              style: const TextStyle(fontSize: 9),
                            ),
                          ),
                        ),
                      ),
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: null,
                        getDrawingHorizontalLine: (v) => FlLine(
                          color: const Color(0x20808080),
                          strokeWidth: 0.5,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
