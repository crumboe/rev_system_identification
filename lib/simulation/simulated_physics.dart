/// Abstract interface for simulated mechanism physics.
///
/// Provides a common API for flywheel, arm, and elevator models
/// so that [SimulatedSparkConnection] and [SimulatedControlApi]
/// can work with any mechanism type.
library;

/// Common interface for all physics simulations.
abstract class SimulatedPhysics {
  /// Advance the simulation by [dtSeconds] at the given [voltage].
  void step(double voltage, double dtSeconds);

  /// Reset all state to initial conditions.
  void reset();

  /// Set the position directly (in encoder rotations).
  /// Used for dragging the visual to a start position.
  void setPositionRotations(double rotations);

  /// The last commanded voltage.
  double get commandedVoltage;
  set commandedVoltage(double v);

  /// Nominal bus voltage (V).
  double get nominalVoltage;

  /// Noisy velocity reading in RPM (as the encoder would report).
  double get noisyVelocityRpm;

  /// Noisy position reading in rotations (as the encoder would report).
  double get noisyPositionRotations;

  /// Simulated output current in amps.
  double get outputCurrentAmps;

  /// Simulated temperature in °C.
  int get temperatureC;

  /// Human-readable label for this simulation.
  String get label;

  /// Ground-truth kS for verification.
  double get kS;

  /// Ground-truth kV for verification.
  double get kV;

  /// Ground-truth kA for verification.
  double get kA;

  /// Ground-truth kG for verification (0 for flywheel).
  double get kG;

  /// External load torque expressed as an equivalent voltage (V).
  ///
  /// Positive values oppose positive motion (drag / resistance).
  /// For flywheels this simulates friction or a load on the wheel.
  /// For arms/elevators this simulates extra weight.
  /// Default is 0 (no external load).
  double get loadTorqueVolts;
  set loadTorqueVolts(double v);
}
