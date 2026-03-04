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
  /// [quasistaticRuns] — slow voltage ramp tests (forward + reverse).
  /// [dynamicRuns] — step voltage tests (forward + reverse).
  /// [mechanismType] — affects whether kG is computed and its form.
  static FeedforwardGains analyze({
    required List<TestRun> quasistaticRuns,
    required List<TestRun> dynamicRuns,
    required MechanismType mechanismType,
  }) {
    // Combine all data for regression.
    final allData = <_RegressionRow>[];

    // From quasistatic data: acceleration ≈ 0, so V ≈ kS·sign(ω) + kV·ω + kG·g(θ)
    for (final run in quasistaticRuns) {
      final rows = _buildRegressionRows(run, mechanismType);
      allData.addAll(rows);
    }

    // From dynamic data: includes acceleration component
    for (final run in dynamicRuns) {
      final rows = _buildRegressionRows(run, mechanismType);
      allData.addAll(rows);
    }

    if (allData.length < 4) {
      return const FeedforwardGains(kS: 0, kV: 0, kA: 0, kG: 0);
    }

    // Perform OLS regression: V = kS·sign(ω) + kV·ω + kA·α [+ kG·g]
    return _performRegression(allData, mechanismType);
  }

  /// Build regression rows from a test run.
  ///
  /// Each row computes acceleration via finite differences.
  static List<_RegressionRow> _buildRegressionRows(
    TestRun run,
    MechanismType mechanismType,
  ) {
    final rows = <_RegressionRow>[];
    final data = run.data;

    if (data.length < 2) return rows;

    for (var i = 1; i < data.length; i++) {
      final dt = data[i].timestamp - data[i - 1].timestamp;
      if (dt <= 0) continue;

      final velocity = data[i].velocity;
      if (velocity.abs() < 1e-6) continue; // Skip zero-velocity points

      final acceleration = (data[i].velocity - data[i - 1].velocity) / dt;
      final voltage = data[i].voltage;
      final position = data[i].position;

      // Gravity term
      double gravityTerm = 0.0;
      if (mechanismType == MechanismType.arm) {
        // For arms, gravity depends on angle: cos(θ)
        // Position is in user units (degrees); convert to radians.
        gravityTerm = math.cos(position * math.pi / 180.0);
      } else if (mechanismType == MechanismType.elevator) {
        // For elevators, gravity is constant.
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

  /// Perform ordinary least-squares regression.
  ///
  /// Model: V = kS·sign(ω) + kV·ω + kA·α + kG·g(θ)
  /// This is solved via the normal equations: X^T·X·β = X^T·y
  static FeedforwardGains _performRegression(
    List<_RegressionRow> data,
    MechanismType mechanismType,
  ) {
    final hasGravity = mechanismType.hasGravity;
    final numCols = hasGravity ? 4 : 3; // kS, kV, kA [, kG]
    final n = data.length;

    // Build X matrix and y vector.
    final x = List.generate(
      n,
      (i) => hasGravity
          ? [
              data[i].signVelocity,
              data[i].velocity,
              data[i].acceleration,
              data[i].gravityTerm,
            ]
          : [
              data[i].signVelocity,
              data[i].velocity,
              data[i].acceleration,
            ],
    );
    final y = List.generate(n, (i) => data[i].voltage);

    // Compute X^T · X (numCols × numCols)
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

    // Compute X^T · y (numCols)
    final xty = List.generate(numCols, (r) {
      var sum = 0.0;
      for (var i = 0; i < n; i++) {
        sum += x[i][r] * y[i];
      }
      return sum;
    });

    // Solve via Gaussian elimination with partial pivoting.
    final beta = _solveLinearSystem(xtx, xty);

    // Compute R²
    final yMean = y.reduce((a, b) => a + b) / n;
    var ssTot = 0.0;
    var ssRes = 0.0;
    for (var i = 0; i < n; i++) {
      var predicted = 0.0;
      for (var j = 0; j < numCols; j++) {
        predicted += x[i][j] * beta[j];
      }
      ssTot += (y[i] - yMean) * (y[i] - yMean);
      ssRes += (y[i] - predicted) * (y[i] - predicted);
    }
    final rSquared = ssTot > 0 ? 1.0 - (ssRes / ssTot) : 0.0;

    return FeedforwardGains(
      kS: beta[0].abs(), // kS is always positive
      kV: beta[1],
      kA: beta[2],
      kG: hasGravity ? beta[3] : 0.0,
      rSquared: rSquared,
    );
  }

  /// Solve a linear system Ax = b using Gaussian elimination with partial
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
