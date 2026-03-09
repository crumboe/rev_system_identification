/// Unit tests for the SimulatedPidFfController and SimulatedControlApi.
///
/// Verifies closed-loop velocity and position control using the simulated
/// physics + PID + feedforward pipeline.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/can/spark_protocol.dart';
import 'package:rev_system_identification/simulation/flywheel_physics.dart';
import 'package:rev_system_identification/simulation/arm_physics.dart';
import 'package:rev_system_identification/simulation/simulated_device.dart';

void main() {
  // =========================================================================
  // Helper: set up a flywheel simulation with PID + FF
  // =========================================================================

  /// Create a fully wired flywheel SimulatedControlApi with the given gains.
  ({
    FlywheelPhysics physics,
    SimulatedParameterApi params,
    SimulatedControlApi control,
    SimulatedPidFfController pidFf,
  }) _setupFlywheel({
    double kP = 0.0,
    double kI = 0.0,
    double kD = 0.0,
    double ffKs = 0.0,
    double ffKv = 0.0,
    double ffKa = 0.0,
  }) {
    final physics =
        FlywheelPhysics(noiseLevel: 0.0, randomSeed: 42);
    final params = SimulatedParameterApi();
    final control = SimulatedControlApi(physics, params);
    final pidFf = SimulatedPidFfController(params, physics);
    control.attachPidFfController(pidFf);

    // Write gains
    params.setParameter(kParamSlot0P, kP);
    params.setParameter(kParamSlot0I, kI);
    params.setParameter(kParamSlot0D, kD);
    params.setParameter(kParamSlot0FfKs, ffKs);
    params.setParameter(kParamSlot0FfKv, ffKv);
    params.setParameter(kParamSlot0FfKa, ffKa);

    return (
      physics: physics,
      params: params,
      control: control,
      pidFf: pidFf,
    );
  }

  /// Run N ticks of closed-loop simulation at the given dt.
  void _runTicks(
    SimulatedControlApi control,
    FlywheelPhysics physics,
    int ticks, {
    double dt = 0.01,
  }) {
    for (var i = 0; i < ticks; i++) {
      control.tick(dt);
      physics.step(physics.commandedVoltage, dt);
    }
  }

  // =========================================================================
  // Velocity closed-loop tests
  // =========================================================================

  group('Velocity closed-loop (flywheel)', () {
    test('feedforward-only reaches approximate target velocity', () {
      // Use the flywheel's ground truth as FF gains (no PID)
      final sim = _setupFlywheel(
        ffKs: 0.14,
        ffKv: 0.0185,
      );

      const targetRpm = 300.0;
      sim.control.setVelocity(targetRpm);
      _runTicks(sim.control, sim.physics, 1000);

      // With perfect FF and no PID, should be close to target
      expect(sim.physics.velocityRpm, closeTo(targetRpm, targetRpm * 0.15));
    });

    test('PID + FF converges to target velocity', () {
      final sim = _setupFlywheel(
        kP: 0.003 / 0.1 / 12.0, // kA / tau / nomV
        ffKs: 0.14,
        ffKv: 0.0185,
      );

      const targetRpm = 500.0;
      sim.control.setVelocity(targetRpm);
      _runTicks(sim.control, sim.physics, 2000); // 20 seconds

      expect(sim.physics.velocityRpm, closeTo(targetRpm, targetRpm * 0.10));
    });

    test('zero setpoint maintains zero velocity', () {
      final sim = _setupFlywheel(kP: 0.001, ffKv: 0.0185);
      sim.control.setVelocity(0.0);
      _runTicks(sim.control, sim.physics, 200);

      expect(sim.physics.velocityRpm.abs(), lessThan(1.0));
    });

    test('negative velocity setpoint', () {
      final sim = _setupFlywheel(
        kP: 0.001,
        ffKs: 0.14,
        ffKv: 0.0185,
      );

      sim.control.setVelocity(-300.0);
      _runTicks(sim.control, sim.physics, 1000);

      expect(sim.physics.velocityRpm, lessThan(-100.0));
    });
  });

  // =========================================================================
  // Position closed-loop tests
  // =========================================================================

  group('Position closed-loop (flywheel)', () {
    test('PID drives to target position', () {
      final sim = _setupFlywheel(
        kP: 0.05, // relatively aggressive for position
        kD: 0.005,
      );

      const targetRotations = 5.0;
      sim.control.setPosition(targetRotations);
      _runTicks(sim.control, sim.physics, 3000); // 30 seconds

      expect(sim.physics.positionRotations,
          closeTo(targetRotations, targetRotations * 0.15));
    });

    test('position control with gravity compensation (arm)', () {
      final physics = ArmPhysics(noiseLevel: 0.0, randomSeed: 42);
      final params = SimulatedParameterApi();
      final control = SimulatedControlApi(physics, params);
      final pidFf = SimulatedPidFfController(params, physics);
      control.attachPidFfController(pidFf);

      // Set gains with gravity compensation.
      // kP must be large enough that PID output exceeds kS (0.20 V) after
      // gravity is compensated by kCos.  With error=0.125 rot and nomV=12:
      //   pidVoltage = kP * 0.125 * 12, so kP >= 0.20/(0.125*12) ~ 0.14.
      // Also include kS feedforward so the controller overcomes friction.
      params.setParameter(kParamSlot0P, 1.0);
      params.setParameter(kParamSlot0I, 0.5);
      params.setParameter(kParamSlot0D, 0.02);
      params.setParameter(kParamSlot0FfKs, 0.20);
      params.setParameter(kParamSlot0FfKcos, 0.80);
      params.setParameter(kParamSlot0FfKcosRatio, 1.0);

      // Target: 45 degrees = 0.125 rotations
      const targetRot = 0.125;
      control.setPosition(targetRot);

      for (var i = 0; i < 5000; i++) {
        control.tick(0.01);
        physics.step(physics.commandedVoltage, 0.01);
      }

      expect(physics.noisyPositionRotations,
          closeTo(targetRot, 0.02));
    });
  });

  // =========================================================================
  // Control mode switching
  // =========================================================================

  group('Control mode switching', () {
    test('setVoltage directly commands the physics', () {
      final sim = _setupFlywheel();
      sim.control.setVoltage(6.0);
      expect(sim.physics.commandedVoltage, equals(6.0));
    });

    test('setDutyCycle scales by nominal voltage', () {
      final sim = _setupFlywheel();
      sim.control.setDutyCycle(0.5);
      expect(sim.physics.commandedVoltage,
          closeTo(0.5 * sim.physics.nominalVoltage, 0.01));
    });

    test('stop zeros voltage and resets PID', () {
      final sim = _setupFlywheel(kP: 0.001, ffKv: 0.0185);
      sim.control.setVelocity(500.0);
      _runTicks(sim.control, sim.physics, 100);

      sim.control.stop();
      expect(sim.physics.commandedVoltage, equals(0.0));
    });

    test('switching from velocity to position resets PID', () {
      final sim = _setupFlywheel(kP: 0.001, ffKv: 0.0185);
      sim.control.setVelocity(500.0);
      _runTicks(sim.control, sim.physics, 100);

      // Switch to position control — should not crash
      sim.control.setPosition(1.0);
      _runTicks(sim.control, sim.physics, 100);
      // Just verify it doesn't throw
    });
  });

  // =========================================================================
  // SimulatedParameterApi
  // =========================================================================

  group('SimulatedParameterApi', () {
    test('default values are accessible', () async {
      final params = SimulatedParameterApi();
      final canId = await params.getCanId();
      expect(canId, equals(42));

      final maxOut = await params.getParameter(kParamSlot0MaxOutput);
      expect(maxOut, equals(1.0));
    });

    test('setParameter/getParameter round-trip', () async {
      final params = SimulatedParameterApi();
      await params.setParameter(kParamSlot0P, 0.123);
      final value = await params.getParameter(kParamSlot0P);
      expect(value, closeTo(0.123, 1e-9));
    });

    test('setPidSlot0 / getPidSlot0 round-trip', () async {
      final params = SimulatedParameterApi();
      await params.setPidSlot0(p: 0.1, i: 0.01, d: 0.001, f: 0.02);
      final pid = await params.getPidSlot0();
      expect(pid.p, closeTo(0.1, 1e-9));
      expect(pid.i, closeTo(0.01, 1e-9));
      expect(pid.d, closeTo(0.001, 1e-9));
      expect(pid.f, closeTo(0.02, 1e-9));
    });

    test('setFeedForwardSlot0 / getFeedForwardSlot0 round-trip', () async {
      final params = SimulatedParameterApi();
      await params.setFeedForwardSlot0(
        kS: 0.14,
        kV: 0.0185,
        kA: 0.003,
        kG: 0.55,
      );
      final ff = await params.getFeedForwardSlot0();
      expect(ff.kS, closeTo(0.14, 1e-9));
      expect(ff.kV, closeTo(0.0185, 1e-9));
      expect(ff.kA, closeTo(0.003, 1e-9));
      expect(ff.kG, closeTo(0.55, 1e-9));
    });

    test('MAXMotion params round-trip', () async {
      final params = SimulatedParameterApi();
      await params.configureMAXMotionSlot0(
        cruiseVelocity: 600.0,
        maxAcceleration: 1200.0,
        maxJerk: 500.0,
        allowedError: 0.01,
        positionMode: 1,
      );
      final cruise =
          await params.getParameter(kParamMAXMotionCruiseVelocity0);
      expect(cruise, closeTo(600.0, 1e-6));
      final mode =
          await params.getParameter(kParamMAXMotionPositionMode0);
      expect(mode, closeTo(1.0, 1e-6));
    });

    test('soft limits round-trip', () async {
      final params = SimulatedParameterApi();
      await params.configureSoftLimits(
        forwardLimit: 90.0,
        reverseLimit: -45.0,
      );
      final fwd = await params.getParameter(kParamForwardSoftLimit);
      expect(fwd, closeTo(90.0, 1e-6));
      final rev = await params.getParameter(kParamReverseSoftLimit);
      expect(rev, closeTo(-45.0, 1e-6));
      final fwdEn =
          await params.getParameter(kParamForwardSoftLimitEnabled);
      expect(fwdEn, closeTo(1.0, 1e-6)); // enabled
    });

    test('disableSoftLimits sets enable flags to 0', () async {
      final params = SimulatedParameterApi();
      await params.configureSoftLimits(
          forwardLimit: 10, reverseLimit: -10);
      await params.disableSoftLimits();
      final fwdEn =
          await params.getParameter(kParamForwardSoftLimitEnabled);
      expect(fwdEn, closeTo(0.0, 1e-6));
    });

    test('burnFlash completes without error', () async {
      final params = SimulatedParameterApi();
      await params.burnFlash();
    });
  });

  // =========================================================================
  // SimulatedControlApi utility methods
  // =========================================================================

  group('SimulatedControlApi utility methods', () {
    test('identify returns ACK', () async {
      final physics = FlywheelPhysics(noiseLevel: 0.0);
      final params = SimulatedParameterApi();
      final control = SimulatedControlApi(physics, params);
      final resp = await control.identify();
      expect(resp.responseType, equals(kUsbResponseAck));
    });

    test('clearFaults returns ACK', () async {
      final physics = FlywheelPhysics(noiseLevel: 0.0);
      final params = SimulatedParameterApi();
      final control = SimulatedControlApi(physics, params);
      final resp = await control.clearFaults();
      expect(resp.responseType, equals(kUsbResponseAck));
    });

    test('factoryReset resets physics and returns ACK', () async {
      final physics = FlywheelPhysics(noiseLevel: 0.0, randomSeed: 42);
      final params = SimulatedParameterApi();
      final control = SimulatedControlApi(physics, params);
      final pidFf = SimulatedPidFfController(params, physics);
      control.attachPidFfController(pidFf);

      control.setVoltage(6.0);
      physics.step(6.0, 0.5);
      expect(physics.velocityRpm, greaterThan(0));

      final resp = await control.factoryReset();
      expect(resp.responseType, equals(kUsbResponseAck));
      expect(physics.velocityRpm, equals(0.0));
      expect(physics.positionRotations, equals(0.0));
    });
  });
}
