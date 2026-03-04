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
import '../../state/app_state.dart';
import '../../sysid/test_runner.dart';

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
  final List<DataPoint> _liveData = [];

  // Live chart data (rolling window)
  final int _maxChartPoints = 500;

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

            // Live charts
            Expanded(
              child: Row(
                children: [
                  // Velocity chart
                  Expanded(
                    child: _LiveChart(
                      title: 'Velocity',
                      data: _liveData,
                      maxPoints: _maxChartPoints,
                      yExtractor: (dp) => dp.velocity,
                      yLabel: ref.read(mechanismConfigProvider).type.velocityUnit,
                      color: Colors.blue,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Voltage chart
                  Expanded(
                    child: _LiveChart(
                      title: 'Voltage',
                      data: _liveData,
                      maxPoints: _maxChartPoints,
                      yExtractor: (dp) => dp.voltage,
                      yLabel: 'V',
                      color: Colors.orange,
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
                      data: _liveData,
                      maxPoints: _maxChartPoints,
                      yExtractor: (dp) => dp.position,
                      yLabel: ref.read(mechanismConfigProvider).type.positionUnit,
                      color: Colors.green,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Current chart
                  Expanded(
                    child: _LiveChart(
                      title: 'Current',
                      data: _liveData,
                      maxPoints: _maxChartPoints,
                      yExtractor: (dp) => dp.current,
                      yLabel: 'A',
                      color: Colors.red,
                    ),
                  ),
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
      _liveData.clear();
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
      _liveData.clear();
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
      _liveData.add(DataPoint(
        timestamp: progress.elapsedSeconds,
        voltage: progress.currentVoltage,
        velocity: progress.currentVelocity,
        position: progress.currentPosition,
        current: progress.currentCurrent,
      ));

      // Trim to max chart points
      if (_liveData.length > _maxChartPoints) {
        _liveData.removeRange(0, _liveData.length - _maxChartPoints);
      }
    });
  }

  void _emergencyStop() {
    _runner?.emergencyStop();
    setState(() {
      _isRunning = false;
      _statusMessage = 'EMERGENCY STOP — motor disabled.';
    });
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
  final List<DataPoint> data;
  final int maxPoints;
  final double Function(DataPoint) yExtractor;
  final String yLabel;
  final Color color;

  const _LiveChart({
    required this.title,
    required this.data,
    required this.maxPoints,
    required this.yExtractor,
    required this.yLabel,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final spots = data
        .map((dp) => FlSpot(dp.timestamp, yExtractor(dp)))
        .toList();

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
            child: spots.isEmpty
                ? const Center(child: Text('No data'))
                : LineChart(
                    LineChartData(
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: false,
                          color: color,
                          barWidth: 1.5,
                          dotData: const FlDotData(show: false),
                        ),
                      ],
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
