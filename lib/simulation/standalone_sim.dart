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
import '../simulation/project_physics_factory.dart';
import '../simulation/simulated_device.dart';

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
  final physics = createProjectBackedPhysics(
    gains: identifiedGains,
    config: config,
  );

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
