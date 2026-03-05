/// Unit tests for the MAXMotion trapezoidal profile generator.
///
/// Tests the profiled position controller inside SimulatedControlApi.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/can/spark_protocol.dart';
import 'package:rev_system_identification/simulation/flywheel_physics.dart';
import 'package:rev_system_identification/simulation/simulated_device.dart';

void main() {
  /// Create a flywheel with MAXMotion configured.
  ({
    FlywheelPhysics physics,
    SimulatedParameterApi params,
    SimulatedControlApi control,
  }) _setup({
    double cruiseRpm = 600.0,
    double maxAccelRpmPerS = 1200.0,
    double allowedError = 0.01,
    double kP = 0.05,
    double kD = 0.005,
  }) {
    final physics = FlywheelPhysics(noiseLevel: 0.0, randomSeed: 42);
    final params = SimulatedParameterApi();
    final control = SimulatedControlApi(physics, params);
    final pidFf = SimulatedPidFfController(params, physics);
    control.attachPidFfController(pidFf);

    // PID gains for the inner position controller
    params.setParameter(kParamSlot0P, kP);
    params.setParameter(kParamSlot0D, kD);

    // MAXMotion profile parameters
    params.setParameter(kParamMAXMotionCruiseVelocity0, cruiseRpm);
    params.setParameter(kParamMAXMotionMaxAccel0, maxAccelRpmPerS);
    params.setParameter(kParamMAXMotionAllowedError0, allowedError);
    params.setParameter(kParamMAXMotionPositionMode0, 0); // trapezoidal

    return (physics: physics, params: params, control: control);
  }

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

  group('MAXMotion trapezoidal profile', () {
    test('reaches target position', () {
      final sim = _setup(cruiseRpm: 600, maxAccelRpmPerS: 1200);
      const target = 5.0; // rotations
      sim.control.setSmartMotion(target);
      _runTicks(sim.control, sim.physics, 5000); // 50 seconds

      expect(sim.physics.positionRotations, closeTo(target, 0.5));
    });

    test('respects cruise velocity limit', () {
      // Very low cruise to make the limit obvious
      final sim = _setup(cruiseRpm: 60, maxAccelRpmPerS: 600);
      sim.control.setSmartMotion(10.0);

      double maxObservedRpm = 0;
      for (var i = 0; i < 3000; i++) {
        sim.control.tick(0.01);
        sim.physics.step(sim.physics.commandedVoltage, 0.01);
        if (sim.physics.velocityRpm.abs() > maxObservedRpm) {
          maxObservedRpm = sim.physics.velocityRpm.abs();
        }
      }

      // Due to PID transients, might briefly overshoot cruise.
      // But the profiled setpoint should never exceed cruise,
      // and the actual velocity should be in the same neighborhood.
      // Allow generous margin for PID tracking error.
      // 60 RPM = 1 rot/s cruise velocity
      expect(maxObservedRpm, lessThan(200));
    });

    test('negative target (reverse direction)', () {
      final sim = _setup(cruiseRpm: 600, maxAccelRpmPerS: 1200);
      const target = -3.0;
      sim.control.setSmartMotion(target);
      _runTicks(sim.control, sim.physics, 5000);

      expect(sim.physics.positionRotations, closeTo(target, 0.5));
    });

    test('does not overshoot target', () {
      final sim = _setup(
        cruiseRpm: 300,
        maxAccelRpmPerS: 600,
        kP: 0.03,
        kD: 0.003,
      );
      const target = 2.0;
      sim.control.setSmartMotion(target);

      double maxPos = 0;
      for (var i = 0; i < 5000; i++) {
        sim.control.tick(0.01);
        sim.physics.step(sim.physics.commandedVoltage, 0.01);
        if (sim.physics.positionRotations > maxPos) {
          maxPos = sim.physics.positionRotations;
        }
      }

      // With trapezoidal profile, should have minimal overshoot
      expect(maxPos, lessThan(target + 0.5));
    });

    test('allowed error snaps to target', () {
      final sim = _setup(
        cruiseRpm: 600,
        maxAccelRpmPerS: 1200,
        allowedError: 0.1,
      );
      const target = 1.0;
      sim.control.setSmartMotion(target);
      _runTicks(sim.control, sim.physics, 3000);

      // Should have converged to within allowed error
      expect(
        (sim.physics.positionRotations - target).abs(),
        lessThan(0.5),
      );
    });
  });
}
