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

  Map<String, dynamic> toJson() => {
        't': timestamp,
        'v': voltage,
        'vel': velocity,
        'pos': position,
        'i': current,
      };

  factory DataPoint.fromJson(Map<String, dynamic> json) => DataPoint(
        timestamp: (json['t'] as num).toDouble(),
        voltage: (json['v'] as num).toDouble(),
        velocity: (json['vel'] as num).toDouble(),
        position: (json['pos'] as num).toDouble(),
        current: (json['i'] as num).toDouble(),
      );

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

  Map<String, dynamic> toJson() => {
        'id': id,
        'startTime': startTime.toIso8601String(),
        'mechanismType': mechanismType.name,
        'testType': testType.name,
        'durationSeconds': durationSeconds,
        'testParams': testParams.toJson(),
        'data': data.map((d) => d.toJson()).toList(),
      };

  factory TestRun.fromJson(Map<String, dynamic> json) => TestRun(
        id: json['id'] as String,
        startTime: DateTime.parse(json['startTime'] as String),
        mechanismType: MechanismType.values.byName(json['mechanismType'] as String),
        testType: TestType.values.byName(json['testType'] as String),
        durationSeconds: (json['durationSeconds'] as num).toDouble(),
        testParams: SysIdTestParams.fromJson(json['testParams'] as Map<String, dynamic>),
        data: (json['data'] as List)
            .map((d) => DataPoint.fromJson(d as Map<String, dynamic>))
            .toList(),
      );

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

  Map<String, dynamic> toJson() => {
        'kS': kS,
        'kV': kV,
        'kA': kA,
        'kG': kG,
        'rSquared': rSquared,
      };

  factory FeedforwardGains.fromJson(Map<String, dynamic> json) =>
      FeedforwardGains(
        kS: (json['kS'] as num).toDouble(),
        kV: (json['kV'] as num).toDouble(),
        kA: (json['kA'] as num).toDouble(),
        kG: (json['kG'] as num?)?.toDouble() ?? 0.0,
        rSquared: (json['rSquared'] as num?)?.toDouble() ?? 0.0,
      );

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

  /// The velocity time constant (ms) used during auto-tuning, if applicable.
  final double? velocityTimeConstantMs;

  /// The position bandwidth (Hz) used during auto-tuning, if applicable.
  final double? positionBandwidthHz;

  /// Allowed closed-loop error (user units).  When the error is less than
  /// this value the controller stops applying PID output.  Default 0 = no
  /// dead-band.
  final double allowedClosedLoopError;

  /// Warnings about automatic gain adjustments (e.g. low-inertia de-rating).
  final List<String> warnings;

  const PidResult({
    this.kP = 0.0,
    this.kI = 0.0,
    this.kD = 0.0,
    this.allowedClosedLoopError = 0.0,
    this.velocityTimeConstantMs,
    this.positionBandwidthHz,
    this.warnings = const [],
  });

  PidResult copyWith({
    double? kP,
    double? kI,
    double? kD,
    double? allowedClosedLoopError,
    double? velocityTimeConstantMs,
    double? positionBandwidthHz,
    List<String>? warnings,
  }) {
    return PidResult(
      kP: kP ?? this.kP,
      kI: kI ?? this.kI,
      kD: kD ?? this.kD,
      allowedClosedLoopError: allowedClosedLoopError ?? this.allowedClosedLoopError,
      velocityTimeConstantMs: velocityTimeConstantMs ?? this.velocityTimeConstantMs,
      positionBandwidthHz: positionBandwidthHz ?? this.positionBandwidthHz,
      warnings: warnings ?? this.warnings,
    );
  }

  Map<String, dynamic> toJson() => {
        'kP': kP,
        'kI': kI,
        'kD': kD,
        if (allowedClosedLoopError != 0.0)
          'allowedClosedLoopError': allowedClosedLoopError,
        if (velocityTimeConstantMs != null)
          'velocityTimeConstantMs': velocityTimeConstantMs,
        if (positionBandwidthHz != null)
          'positionBandwidthHz': positionBandwidthHz,
        if (warnings.isNotEmpty) 'warnings': warnings,
      };

  factory PidResult.fromJson(Map<String, dynamic> json) => PidResult(
        kP: (json['kP'] as num?)?.toDouble() ?? 0.0,
        kI: (json['kI'] as num?)?.toDouble() ?? 0.0,
        kD: (json['kD'] as num?)?.toDouble() ?? 0.0,
        allowedClosedLoopError:
            (json['allowedClosedLoopError'] as num?)?.toDouble() ?? 0.0,
        velocityTimeConstantMs:
            (json['velocityTimeConstantMs'] as num?)?.toDouble(),
        positionBandwidthHz:
            (json['positionBandwidthHz'] as num?)?.toDouble(),
        warnings: (json['warnings'] as List?)?.cast<String>() ?? const [],
      );

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

  Map<String, dynamic> toJson() => {
        'mechanismType': mechanismType.name,
        'feedforward': feedforward.toJson(),
        'pid': pid.toJson(),
        'testRuns': testRuns.map((r) => r.toJson()).toList(),
      };

  factory SysIdResults.fromJson(Map<String, dynamic> json) => SysIdResults(
        mechanismType:
            MechanismType.values.byName(json['mechanismType'] as String),
        feedforward: FeedforwardGains.fromJson(
            json['feedforward'] as Map<String, dynamic>),
        pid: PidResult.fromJson(json['pid'] as Map<String, dynamic>),
        testRuns: (json['testRuns'] as List)
            .map((r) => TestRun.fromJson(r as Map<String, dynamic>))
            .toList(),
      );
}
