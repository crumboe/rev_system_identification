/// Factory for creating standalone simulated [SparkDevice] instances.
///
/// The resulting device is fully wired (connection → control API →
/// PID+FF controller → physics) but is intentionally NOT registered in
/// [DeviceManager].  It exists solely for the "Simulate PID" dialog, which
/// needs a private device that will not interfere with the global device
/// registry or any real hardware sessions.
///
/// The physics plant is constructed from the identified feedforward gains so
/// that the simulated closed-loop response is grounded in the real mechanism's
/// characteristics rather than arbitrary defaults.
library;

import '../can/spark_protocol.dart';
import '../data/test_data.dart';
import '../devices/device_manager.dart';
import '../mechanisms/mechanism.dart';
import '../simulation/arm_physics.dart';
import '../simulation/elevator_physics.dart';
import '../simulation/flywheel_physics.dart';
import '../simulation/simulated_device.dart';
import '../simulation/simulated_physics.dart';

/// Creates a standalone simulated [SparkDevice] grounded in [identifiedGains].
///
/// The plant physics are built from the identified feedforward constants
/// (kS, kV, kA, kG) so that the simulated step response is representative
/// of the real mechanism.  Conversion factors from [config] are written to
/// the simulated parameter store immediately, mirroring what [ValidationRunner]
/// does before a live test.
///
/// The returned [SparkDevice] is opened and ready to use. It is
/// **not** added to [DeviceManager._devices] — this is intentional: the
/// device is a private resource owned by the Simulate PID dialog and must
/// not appear in the global device list or affect any connected hardware.
///
/// Parameters:
/// - [type] — selects flywheel/simple, arm, or elevator physics.
/// - [identifiedGains] — plant physics values (kS, kV, kA, kG).
/// - [config] — provides conversion factors written to the simulated params.
Future<SparkDevice> createStandaloneSimulatedDevice({
  required MechanismType type,
  required FeedforwardGains identifiedGains,
  required MechanismConfig config,
}) async {
  // Build the physics plant using identified feedforward gains so the
  // simulated response is grounded in the real mechanism's characteristics.
  final physics = _buildPhysics(type, identifiedGains);

  final connection = SimulatedSparkConnection(physics);
  await connection.open();

  final heartbeat = SimulatedHeartbeatManager();
  final parameters = SimulatedParameterApi();
  final control = SimulatedControlApi(physics, parameters);

  // Wire the closed-loop PID+FF controller into the simulation stack.
  final pidFf = SimulatedPidFfController(parameters, physics);
  control.attachPidFfController(pidFf);
  connection.controlApi = control;
  connection.paramApi = parameters;

  // Write conversion factors so setpoints and status-frame measurements
  // use user units throughout, matching real-hardware behaviour.
  parameters.setParameter(
    kParamPositionConvFactor,
    config.positionConversionFactor,
  );
  parameters.setParameter(
    kParamVelocityConvFactor,
    config.velocityConversionFactor,
  );

  // The device is intentionally unregistered from DeviceManager — it is
  // a private simulation used only by the Simulate PID dialog.
  final device = SparkDevice(
    connection: connection,
    heartbeat: heartbeat,
    parameters: parameters,
    control: control,
    label: physics.label,
    canId: 99,
    isSimulated: true,
  );
  device.canIdReadSucceeded = true;
  return device;
}

/// Build the appropriate physics model for [type] using the identified [gains].
///
/// [noiseLevel] is fixed at 0.005 (0.5 %) so the simulation is representative
/// without being dominated by sensor noise artefacts.
///
/// A positive [kA] guard prevents division-by-zero inside the integrators if
/// analysis somehow produced a zero or negative value.
SimulatedPhysics _buildPhysics(MechanismType type, FeedforwardGains gains) {
  const noiseLevel = 0.005;
  return switch (type) {
    MechanismType.arm => ArmPhysics(
        kS: gains.kS,
        kV: gains.kV,
        kA: gains.kA > 0 ? gains.kA : 0.002,
        kG: gains.kG,
        noiseLevel: noiseLevel,
      ),
    MechanismType.elevator => ElevatorPhysics(
        kS: gains.kS,
        kV: gains.kV,
        kA: gains.kA > 0 ? gains.kA : 0.015,
        kG: gains.kG,
        noiseLevel: noiseLevel,
      ),
    MechanismType.flywheel || MechanismType.simple => FlywheelPhysics(
        kS: gains.kS,
        kV: gains.kV,
        kA: gains.kA > 0 ? gains.kA : 0.003,
        noiseLevel: noiseLevel,
      ),
  };
}
