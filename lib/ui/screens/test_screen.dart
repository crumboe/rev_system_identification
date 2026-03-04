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

  /// Each inner list is one test's data. Segments are separated so charts
  /// render each test in a distinct color with no connecting line.
  final List<List<DataPoint>> _liveSegments = [];

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
    final status2 = device.connection.lastStatus2;
    if (status2 == null) return;
    final config = ref.read(mechanismConfigProvider);
    final userPos = status2.positionRotations * config.positionConversionFactor;
    if ((userPos - _currentPosition).abs() > 0.01) {
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
                  enabled: canRun,
                  completed: testRuns.any(
                      (r) => r.testType == TestType.quasistaticForward),
                  onPressed: () =>
                      _runSingleTest(TestType.quasistaticForward, device!, config, testParams),
                ),
                _TestButton(
                  label: 'Quasistatic Reverse',
                  icon: FluentIcons.back,
                  enabled: canRun,
                  completed: testRuns.any(
                      (r) => r.testType == TestType.quasistaticReverse),
                  onPressed: () =>
                      _runSingleTest(TestType.quasistaticReverse, device!, config, testParams),
                ),
                _TestButton(
                  label: 'Dynamic Forward',
                  icon: FluentIcons.fast_forward,
                  enabled: canRun,
                  completed: testRuns
                      .any((r) => r.testType == TestType.dynamicForward),
                  onPressed: () =>
                      _runSingleTest(TestType.dynamicForward, device!, config, testParams),
                ),
                _TestButton(
                  label: 'Dynamic Reverse',
                  icon: FluentIcons.rewind,
                  enabled: canRun,
                  completed: testRuns
                      .any((r) => r.testType == TestType.dynamicReverse),
                  onPressed: () =>
                      _runSingleTest(TestType.dynamicReverse, device!, config, testParams),
                ),
                const SizedBox(width: 16),
                FilledButton(
                  onPressed: canRun
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
                                    segments: _liveSegments,
                                    segmentColors: _segmentColors,
                                    yExtractor: (dp) => dp.velocity,
                                    yLabel: config.type.velocityUnit,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Voltage chart
                                Expanded(
                                  child: _LiveChart(
                                    title: 'Voltage',
                                    segments: _liveSegments,
                                    segmentColors: _segmentColors,
                                    yExtractor: (dp) => dp.voltage,
                                    yLabel: 'V',
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
                                    segments: _liveSegments,
                                    segmentColors: _segmentColors,
                                    yExtractor: (dp) => dp.position,
                                    yLabel: config.type.positionUnit,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Current chart
                                Expanded(
                                  child: _LiveChart(
                                    title: 'Current',
                                    segments: _liveSegments,
                                    segmentColors: _segmentColors,
                                    yExtractor: (dp) => dp.current,
                                    yLabel: 'A',
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
                      child: ArmVisual(
                        currentAngleDeg: _currentPosition,
                        forwardLimitDeg: config.forwardSoftLimit,
                        reverseLimitDeg: config.reverseSoftLimit,
                        isDraggable: device != null && device.isSimulated && !_isRunning,
                        onAngleChanged: (deg) => _onDragPosition(device, config, deg),
                      ),
                    ),
                  ],
                  if (config.type == MechanismType.elevator) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 220,
                      child: ElevatorVisual(
                        currentPositionIn: _currentPosition,
                        forwardLimitIn: config.forwardSoftLimit,
                        reverseLimitIn: config.reverseSoftLimit,
                        isDraggable: device != null && device.isSimulated && !_isRunning,
                        onPositionChanged: (inches) => _onDragPosition(device, config, inches),
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
    setState(() {
      _isRunning = true;
      _currentTest = testType;
      _liveSegments.clear();
      _startNewSegment();
      _currentPosition = 0.0;
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
          : 'Test stopped: ${result.stopReason.name}'
              '${result.errorMessage != null ? " — ${result.errorMessage}" : ""}';
    });
  }

  Future<void> _runFullCharacterization(
    SparkDevice device,
    MechanismConfig config,
    SysIdTestParams testParams,
  ) async {
    setState(() {
      _isRunning = true;
      _statusMessage = 'Running full characterization...';
      _liveSegments.clear();
      _startNewSegment();
      _currentPosition = 0.0;
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
    setState(() {
      if (_liveSegments.isEmpty) _startNewSegment();
      _liveSegments.last.add(DataPoint(
        timestamp: progress.elapsedSeconds,
        voltage: progress.currentVoltage,
        velocity: progress.currentVelocity,
        position: progress.currentPosition,
        current: progress.currentCurrent,
      ));
      _currentPosition = progress.currentPosition;
    });
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

  const _LiveChart({
    required this.title,
    required this.segments,
    required this.segmentColors,
    required this.yExtractor,
    required this.yLabel,
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
                      minX: 0,
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
