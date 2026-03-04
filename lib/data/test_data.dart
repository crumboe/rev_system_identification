/// Data models for system identification test runs and results.
library;

import '../mechanisms/mechanism.dart';

/// A single timestamped data point recorded during a test.
class DataPoint {
  /// Time in seconds since test start.
  final double timestamp;

  /// Applied voltage (V).
  final double voltage;

  /// Measured velocity in user units per second.
  final double velocity;

  /// Measured position in user units.
  final double position;

  /// Measured current in amps.
  final double current;

  const DataPoint({
    required this.timestamp,
    required this.voltage,
    required this.velocity,
    required this.position,
    required this.current,
  });

  /// CSV header row.
  static const csvHeader = 'timestamp,voltage,velocity,position,current';

  /// CSV row for this data point.
  String toCsvRow() =>
      '${timestamp.toStringAsFixed(6)},'
      '${voltage.toStringAsFixed(6)},'
      '${velocity.toStringAsFixed(6)},'
      '${position.toStringAsFixed(6)},'
      '${current.toStringAsFixed(6)}';
}

/// The type of system identification test.
enum TestType {
  quasistaticForward,
  quasistaticReverse,
  dynamicForward,
  dynamicReverse,
}

extension TestTypeX on TestType {
  String get displayName => switch (this) {
        TestType.quasistaticForward => 'Quasistatic Forward',
        TestType.quasistaticReverse => 'Quasistatic Reverse',
        TestType.dynamicForward => 'Dynamic Forward',
        TestType.dynamicReverse => 'Dynamic Reverse',
      };

  bool get isQuasistatic =>
      this == TestType.quasistaticForward ||
      this == TestType.quasistaticReverse;

  bool get isDynamic =>
      this == TestType.dynamicForward || this == TestType.dynamicReverse;

  bool get isForward =>
      this == TestType.quasistaticForward ||
      this == TestType.dynamicForward;

  /// Voltage sign: +1 for forward, −1 for reverse.
  double get voltageSign => isForward ? 1.0 : -1.0;
}

/// A complete test run with metadata and recorded data.
class TestRun {
  /// Unique ID for this test run.
  final String id;

  /// When this test was run.
  final DateTime startTime;

  /// The mechanism being tested.
  final MechanismType mechanismType;

  /// The test type.
  final TestType testType;

  /// Recorded data points.
  final List<DataPoint> data;

  /// Duration of the test in seconds.
  final double durationSeconds;

  /// Test parameters used.
  final SysIdTestParams testParams;

  TestRun({
    required this.id,
    required this.startTime,
    required this.mechanismType,
    required this.testType,
    required this.data,
    required this.durationSeconds,
    required this.testParams,
  });

  /// Number of data points recorded.
  int get sampleCount => data.length;

  /// Effective sample rate in Hz.
  double get sampleRate =>
      durationSeconds > 0 ? sampleCount / durationSeconds : 0;
}

/// Computed feedforward constants from system identification.
class FeedforwardGains {
  /// Static friction voltage (V). Motor just barely starts moving.
  final double kS;

  /// Velocity gain (V·s/unit). Voltage per unit velocity at steady state.
  final double kV;

  /// Acceleration gain (V·s²/unit). Voltage per unit acceleration.
  final double kA;

  /// Gravity compensation voltage (V).
  /// For arms: kG·cos(θ) component.
  /// For elevators: constant kG.
  /// For flywheels: 0.
  final double kG;

  /// R² goodness-of-fit for the regression.
  final double rSquared;

  const FeedforwardGains({
    required this.kS,
    required this.kV,
    required this.kA,
    this.kG = 0.0,
    this.rSquared = 0.0,
  });

  @override
  String toString() =>
      'FF(kS=${kS.toStringAsFixed(4)}, kV=${kV.toStringAsFixed(4)}, '
      'kA=${kA.toStringAsFixed(4)}, kG=${kG.toStringAsFixed(4)}, '
      'R²=${rSquared.toStringAsFixed(4)})';
}

/// Computed PID gains from the identified plant model.
///
/// With the new REV FeedForwardConfig API, feedforward (kS, kV, kA, kG)
/// is configured separately on the controller. PID handles only the
/// closed-loop error correction.
class PidResult {
  final double kP;
  final double kI;
  final double kD;

  const PidResult({
    this.kP = 0.0,
    this.kI = 0.0,
    this.kD = 0.0,
  });

  @override
  String toString() =>
      'PID(P=${kP.toStringAsFixed(6)}, I=${kI.toStringAsFixed(6)}, '
      'D=${kD.toStringAsFixed(6)})';
}

/// Complete results from a system identification session.
class SysIdResults {
  final MechanismType mechanismType;
  final FeedforwardGains feedforward;
  final PidResult pid;
  final List<TestRun> testRuns;

  const SysIdResults({
    required this.mechanismType,
    required this.feedforward,
    required this.pid,
    required this.testRuns,
  });
}
