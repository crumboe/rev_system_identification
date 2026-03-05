/// Unit tests for data model classes (DataPoint, TestRun, SysIdResults).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/mechanisms/mechanism.dart';

void main() {
  // =========================================================================
  // DataPoint
  // =========================================================================

  group('DataPoint', () {
    test('toCsvRow formats all fields to 6 decimals', () {
      const dp = DataPoint(
        timestamp: 1.5,
        voltage: 6.0,
        velocity: 300.0,
        position: 12.5,
        current: 3.5,
      );
      final csv = dp.toCsvRow();
      expect(csv, contains('1.500000'));
      expect(csv, contains('6.000000'));
      expect(csv, contains('300.000000'));
      expect(csv, contains('12.500000'));
      expect(csv, contains('3.500000'));
    });

    test('csvHeader has 5 columns', () {
      final cols = DataPoint.csvHeader.split(',');
      expect(cols.length, equals(5));
      expect(cols, contains('timestamp'));
      expect(cols, contains('voltage'));
      expect(cols, contains('velocity'));
      expect(cols, contains('position'));
      expect(cols, contains('current'));
    });
  });

  // =========================================================================
  // TestRun
  // =========================================================================

  group('TestRun', () {
    test('sampleCount matches data length', () {
      final run = TestRun(
        id: 'test',
        startTime: DateTime.now(),
        mechanismType: MechanismType.flywheel,
        testType: TestType.quasistaticForward,
        data: List.generate(
          100,
          (i) => DataPoint(
            timestamp: i * 0.01,
            voltage: 0,
            velocity: 0,
            position: 0,
            current: 0,
          ),
        ),
        durationSeconds: 1.0,
        testParams: const SysIdTestParams(),
      );
      expect(run.sampleCount, equals(100));
    });

    test('sampleRate is sampleCount / duration', () {
      final run = TestRun(
        id: 'test',
        startTime: DateTime.now(),
        mechanismType: MechanismType.flywheel,
        testType: TestType.dynamicForward,
        data: List.generate(
          200,
          (i) => DataPoint(
            timestamp: i * 0.005,
            voltage: 0,
            velocity: 0,
            position: 0,
            current: 0,
          ),
        ),
        durationSeconds: 1.0,
        testParams: const SysIdTestParams(),
      );
      expect(run.sampleRate, closeTo(200.0, 1e-6));
    });

    test('sampleRate is 0 when duration is 0', () {
      final run = TestRun(
        id: 'test',
        startTime: DateTime.now(),
        mechanismType: MechanismType.flywheel,
        testType: TestType.quasistaticForward,
        data: [],
        durationSeconds: 0.0,
        testParams: const SysIdTestParams(),
      );
      expect(run.sampleRate, equals(0.0));
    });
  });

  // =========================================================================
  // SysIdResults
  // =========================================================================

  group('SysIdResults', () {
    test('holds all constituent data', () {
      const ff = FeedforwardGains(kS: 0.14, kV: 0.0185, kA: 0.003);
      const pid = PidResult(kP: 0.1, kI: 0.0, kD: 0.01);
      final results = SysIdResults(
        mechanismType: MechanismType.flywheel,
        feedforward: ff,
        pid: pid,
        testRuns: [],
      );
      expect(results.mechanismType, equals(MechanismType.flywheel));
      expect(results.feedforward.kS, equals(0.14));
      expect(results.pid.kP, equals(0.1));
      expect(results.testRuns, isEmpty);
    });
  });
}
