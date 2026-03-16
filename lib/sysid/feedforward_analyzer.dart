/// Feedforward analysis: compute kS, kV, kA, kG from collected test data.
///
/// Uses ordinary least-squares regression on the physics model:
///   V = kS·sign(ω) + kV·ω + kA·α [+ kG·gravity_term]
library;

import 'dart:math' as math;

import '../data/test_data.dart';
import '../mechanisms/mechanism.dart';

/// Analyzes raw test data to compute feedforward constants.
class FeedforwardAnalyzer {
  /// Compute feedforward gains from quasistatic and dynamic test data.
  ///
  /// Uses a two-stage regression with bias correction:
  ///
  /// **Stage 1 — quasistatic only:** fit `V = kS·sign(ω) + kV·ω [+ kG·g]`.
  /// The quasistatic ramp has a small but real acceleration
  /// α_qs ≈ rampRate/kV. Since this is nearly constant, it is collinear
  /// with sign(ω) and gets absorbed into the kS estimate as a bias.
  ///
  /// **Stage 2 — dynamic only:** using Stage-1's kS and kV, compute the
  /// residual voltage for each dynamic sample and fit `V_res = kA·α`.
  ///
  /// **Bias correction:** correct kS by subtracting the acceleration
  /// bias that was absorbed during Stage 1:
  ///   kS_true = kS_stage1 − kA · mean(|α_qs|)
  ///
  /// [quasistaticRuns] — slow voltage ramp tests (forward + reverse).
  /// [dynamicRuns] — step voltage tests (forward + reverse).
  /// [mechanismType] — affects whether kG is computed and its form.
  static FeedforwardGains analyze({
    required List<TestRun> quasistaticRuns,
    required List<TestRun> dynamicRuns,
    required MechanismType mechanismType,
  }) {
    // ------------------------------------------------------------------
    // Collect data
    // ------------------------------------------------------------------
    final qsData = <_RegressionRow>[];
    for (final run in quasistaticRuns) {
      qsData.addAll(_buildRegressionRows(run, mechanismType));
    }
    // Trim the bottom of the quasistatic velocity range where the motor
    // has just broken away from static friction and the acceleration is
    // transiently much larger than the steady-state ramp acceleration.
    _trimLowVelocityTransient(qsData);

    final dynData = <_RegressionRow>[];
    for (final run in dynamicRuns) {
      dynData.addAll(_buildRegressionRows(run, mechanismType));
    }

    if (qsData.length + dynData.length < 4) {
      return const FeedforwardGains(kS: 0, kV: 0, kA: 0, kG: 0);
    }

    // ------------------------------------------------------------------
    // Stage 1: quasistatic — V = kS·sign(ω) + kV·ω [+ kG·g(θ)]
    // ------------------------------------------------------------------
    final hasGravity = mechanismType.hasGravity;
    double kS = 0, kV = 0, kG = 0;

    if (qsData.isNotEmpty) {
      final stage1 = _regressQuasistatic(qsData, hasGravity);
      kS = stage1.kS;
      kV = stage1.kV;
      kG = stage1.kG;
    }

    // ------------------------------------------------------------------
    // Stage 2: dynamic — V_residual = kA·α [+ kG·g(θ)]
    //
    // When gravity is present, Stage 1 QS data may not have enough
    // information to distinguish kG from kS (both are constant offsets
    // in a single direction).  So we jointly fit kA and kG from the
    // dynamic data where the wide acceleration range breaks degeneracy.
    // ------------------------------------------------------------------
    double kA = 0;

    if (dynData.isNotEmpty) {
      if (hasGravity) {
        final stage2 = _regressDynamicKaKg(dynData, kS, kV);
        kA = stage2.kA;
        kG = stage2.kG;
      } else {
        kA = _regressDynamicKa(dynData, kS, kV, 0.0, false);
      }
    }

    // ------------------------------------------------------------------
    // Bias correction: the quasistatic ramp has a constant acceleration
    // α_qs ≈ rampRate / kV that Stage 1 absorbed into kS.  Now that kA
    // is known, remove that bias.
    //
    // We compute α_qs analytically from the known ramp rate and the kV
    // estimated in Stage 1.  This avoids the noise amplification inherent
    // in finite-difference acceleration estimates.
    // ------------------------------------------------------------------
    if (kA > 0 && kV > 0 && quasistaticRuns.isNotEmpty) {
      final rampRate = quasistaticRuns.first.testParams.quasistaticRampRate;
      final alphaQs = rampRate / kV; // RPM/s (steady-state QS accel)
      kS -= kA * alphaQs;
    }

    // ------------------------------------------------------------------
    // Compute combined R² over all data
    // ------------------------------------------------------------------
    final allData = <_RegressionRow>[...qsData, ...dynData];
    final rSquared = _computeRSquared(allData, kS, kV, kA, kG, hasGravity);

    return FeedforwardGains(
      kS: kS.abs(),
      kV: kV,
      kA: kA,
      kG: hasGravity ? kG : 0.0,
      rSquared: rSquared,
    );
  }

  /// Stage 1: OLS for quasistatic model (no acceleration column).
  static ({double kS, double kV, double kG}) _regressQuasistatic(
    List<_RegressionRow> data,
    bool hasGravity,
  ) {
    final numCols = hasGravity ? 3 : 2; // [sign(ω), ω, g?]
    final n = data.length;

    final x = List.generate(
      n,
      (i) => hasGravity
          ? [data[i].signVelocity, data[i].velocity, data[i].gravityTerm]
          : [data[i].signVelocity, data[i].velocity],
    );
    final y = List.generate(n, (i) => data[i].voltage);

    final xtx = List.generate(
      numCols,
      (r) => List.generate(numCols, (c) {
        var sum = 0.0;
        for (var i = 0; i < n; i++) {
          sum += x[i][r] * x[i][c];
        }
        return sum;
      }),
    );
    final xty = List.generate(numCols, (r) {
      var sum = 0.0;
      for (var i = 0; i < n; i++) {
        sum += x[i][r] * y[i];
      }
      return sum;
    });

    final beta = _solveLinearSystem(xtx, xty);
    return (
      kS: beta[0],
      kV: beta[1],
      kG: hasGravity ? beta[2] : 0.0,
    );
  }

  /// Stage 2 (no gravity): simple linear regression V_residual = kA · α.
  static double _regressDynamicKa(
    List<_RegressionRow> data,
    double kS,
    double kV,
    double kG,
    bool hasGravity,
  ) {
    var sumAA = 0.0;
    var sumAR = 0.0;
    for (final row in data) {
      final predicted = kS * row.signVelocity + kV * row.velocity +
          (hasGravity ? kG * row.gravityTerm : 0.0);
      final residual = row.voltage - predicted;
      sumAA += row.acceleration * row.acceleration;
      sumAR += row.acceleration * residual;
    }
    return sumAA > 0 ? sumAR / sumAA : 0.0;
  }

  /// Stage 2 (with gravity): joint fit V_residual = kA·α + kG·g(θ).
  static ({double kA, double kG}) _regressDynamicKaKg(
    List<_RegressionRow> data,
    double kS,
    double kV,
  ) {
    // 2×2 system: [α, g(θ)] * [kA, kG]^T = V_residual
    final n = data.length;
    final x = List.generate(
      n,
      (i) => [data[i].acceleration, data[i].gravityTerm],
    );
    final y = List.generate(n, (i) {
      return data[i].voltage -
          kS * data[i].signVelocity -
          kV * data[i].velocity;
    });

    final xtx = List.generate(
      2,
      (r) => List.generate(2, (c) {
        var sum = 0.0;
        for (var i = 0; i < n; i++) {
          sum += x[i][r] * x[i][c];
        }
        return sum;
      }),
    );
    final xty = List.generate(2, (r) {
      var sum = 0.0;
      for (var i = 0; i < n; i++) {
        sum += x[i][r] * y[i];
      }
      return sum;
    });

    final beta = _solveLinearSystem(xtx, xty);
    return (kA: beta[0], kG: beta[1]);
  }

  /// Compute R² over combined data.
  static double _computeRSquared(
    List<_RegressionRow> data,
    double kS,
    double kV,
    double kA,
    double kG,
    bool hasGravity,
  ) {
    if (data.isEmpty) return 0.0;
    final n = data.length;
    var ySum = 0.0;
    for (var i = 0; i < n; i++) {
      ySum += data[i].voltage;
    }
    final yMean = ySum / n;
    var ssTot = 0.0;
    var ssRes = 0.0;
    for (var i = 0; i < n; i++) {
      final row = data[i];
      final predicted = kS * row.signVelocity +
          kV * row.velocity +
          kA * row.acceleration +
          (hasGravity ? kG * row.gravityTerm : 0.0);
      ssTot += (row.voltage - yMean) * (row.voltage - yMean);
      ssRes += (row.voltage - predicted) * (row.voltage - predicted);
    }
    return ssTot > 0 ? 1.0 - (ssRes / ssTot) : 0.0;
  }

  /// Remove low-velocity quasistatic points that are still in the breakaway
  /// transient.  Discards points below 10% of peak |velocity|.
  static void _trimLowVelocityTransient(List<_RegressionRow> data) {
    if (data.isEmpty) return;
    var maxAbsVel = 0.0;
    for (final row in data) {
      final av = row.velocity.abs();
      if (av > maxAbsVel) maxAbsVel = av;
    }
    final threshold = maxAbsVel * 0.10;
    data.removeWhere((row) => row.velocity.abs() < threshold);
  }

  /// Build regression rows from a test run.
  ///
  /// Computes acceleration via central finite differences over a window of
  /// `2 * accelHalfWindow` samples. The wider window reduces sensor-noise
  /// amplification on the derivative by a factor of ~`accelHalfWindow`,
  /// eliminating the errors-in-variables attenuation that otherwise biases
  /// the kA estimate toward zero.
  static List<_RegressionRow> _buildRegressionRows(
    TestRun run,
    MechanismType mechanismType, {
    int accelHalfWindow = 5,
  }) {
    final data = run.data;
    final k = accelHalfWindow;

    // Need at least 2*k+1 samples for one central difference.
    if (data.length < 2 * k + 1) {
      // Fall back to adjacent differences if too few samples.
      return _buildRegressionRowsAdjacent(run, mechanismType);
    }

    final rows = <_RegressionRow>[];
    for (var i = k; i < data.length - k; i++) {
      final dt = data[i + k].timestamp - data[i - k].timestamp;
      if (dt <= 0) continue;

      final velocity = data[i].velocity;
      if (velocity.abs() < 1e-6) continue;

      final acceleration =
          (data[i + k].velocity - data[i - k].velocity) / dt;
      final voltage = data[i].voltage;
      final position = data[i].position;

      double gravityTerm = 0.0;
      if (mechanismType == MechanismType.arm) {
        gravityTerm = math.cos(position * math.pi / 180.0);
      } else if (mechanismType == MechanismType.elevator) {
        gravityTerm = 1.0;
      }

      rows.add(_RegressionRow(
        voltage: voltage,
        signVelocity: velocity > 0 ? 1.0 : -1.0,
        velocity: velocity,
        acceleration: acceleration,
        gravityTerm: gravityTerm,
      ));
    }

    return rows;
  }

  /// Fallback: adjacent-sample differences (used when run is too short for
  /// the central-difference window).
  static List<_RegressionRow> _buildRegressionRowsAdjacent(
    TestRun run,
    MechanismType mechanismType,
  ) {
    final data = run.data;
    if (data.length < 2) return [];

    final rows = <_RegressionRow>[];
    for (var i = 1; i < data.length; i++) {
      final dt = data[i].timestamp - data[i - 1].timestamp;
      if (dt <= 0) continue;

      final velocity = data[i].velocity;
      if (velocity.abs() < 1e-6) continue;

      final acceleration = (data[i].velocity - data[i - 1].velocity) / dt;
      final voltage = data[i].voltage;
      final position = data[i].position;

      double gravityTerm = 0.0;
      if (mechanismType == MechanismType.arm) {
        gravityTerm = math.cos(position * math.pi / 180.0);
      } else if (mechanismType == MechanismType.elevator) {
        gravityTerm = 1.0;
      }

      rows.add(_RegressionRow(
        voltage: voltage,
        signVelocity: velocity > 0 ? 1.0 : -1.0,
        velocity: velocity,
        acceleration: acceleration,
        gravityTerm: gravityTerm,
      ));
    }

    return rows;
  }
  /// pivoting.  [a] is modified in place.
  static List<double> _solveLinearSystem(
    List<List<double>> a,
    List<double> b,
  ) {
    final n = b.length;

    // Forward elimination.
    for (var col = 0; col < n; col++) {
      // Partial pivoting: find the row with the largest element.
      var maxRow = col;
      var maxVal = a[col][col].abs();
      for (var row = col + 1; row < n; row++) {
        if (a[row][col].abs() > maxVal) {
          maxVal = a[row][col].abs();
          maxRow = row;
        }
      }

      // Swap rows.
      if (maxRow != col) {
        final tmpRow = a[col];
        a[col] = a[maxRow];
        a[maxRow] = tmpRow;
        final tmpB = b[col];
        b[col] = b[maxRow];
        b[maxRow] = tmpB;
      }

      // Check for singularity
      if (a[col][col].abs() < 1e-12) continue;

      // Eliminate.
      for (var row = col + 1; row < n; row++) {
        final factor = a[row][col] / a[col][col];
        for (var j = col; j < n; j++) {
          a[row][j] -= factor * a[col][j];
        }
        b[row] -= factor * b[col];
      }
    }

    // Back substitution.
    final x = List.filled(n, 0.0);
    for (var row = n - 1; row >= 0; row--) {
      if (a[row][row].abs() < 1e-12) continue;
      var sum = b[row];
      for (var col = row + 1; col < n; col++) {
        sum -= a[row][col] * x[col];
      }
      x[row] = sum / a[row][row];
    }

    return x;
  }

  /// Return the median of a list of doubles.
  static double _median(List<double> values) {
    if (values.isEmpty) return 0.0;
    final sorted = List<double>.of(values)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }
}

/// Internal row used for regression.
class _RegressionRow {
  final double voltage;
  final double signVelocity;
  final double velocity;
  final double acceleration;
  final double gravityTerm;

  const _RegressionRow({
    required this.voltage,
    required this.signVelocity,
    required this.velocity,
    required this.acceleration,
    required this.gravityTerm,
  });
}
