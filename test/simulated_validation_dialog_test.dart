/// Tests for the standalone simulated device factory and
/// [SimulatedValidationDialog].
///
/// The factory tests are unit-level: they verify that each [MechanismType]
/// produces the expected physics class, that conversion factors are written
/// correctly, and that the returned device is not added to [DeviceManager].
///
/// The dialog-level tests cover:
/// - Dialog renders with a flywheel config and no exceptions.
/// - Dialog disposes safely (abort path) without crashing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fluent_ui/fluent_ui.dart';

import 'package:rev_system_identification/can/spark_protocol.dart';
import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/devices/device_manager.dart';
import 'package:rev_system_identification/mechanisms/mechanism.dart';
import 'package:rev_system_identification/simulation/arm_physics.dart';
import 'package:rev_system_identification/simulation/elevator_physics.dart';
import 'package:rev_system_identification/simulation/flywheel_physics.dart';
import 'package:rev_system_identification/simulation/simulated_device.dart';
import 'package:rev_system_identification/simulation/standalone_sim.dart';
import 'package:rev_system_identification/ui/widgets/simulated_validation_dialog.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _flywheelGains = FeedforwardGains(
  kS: 0.14,
  kV: 0.0185,
  kA: 0.003,
);

const _armGains = FeedforwardGains(
  kS: 0.20,
  kV: 0.018,
  kA: 0.002,
  kG: 0.80,
);

const _elevatorGains = FeedforwardGains(
  kS: 0.18,
  kV: 0.12,
  kA: 0.015,
  kG: 0.55,
);

const _flywheelConfig = MechanismConfig(
  type: MechanismType.flywheel,
  positionConversionFactor: 1.0,
  velocityConversionFactor: 1.0,
);

const _armConfig = MechanismConfig(
  type: MechanismType.arm,
  positionConversionFactor: 360.0,
  velocityConversionFactor: 360.0 / 60.0,
);

const _elevatorConfig = MechanismConfig(
  type: MechanismType.elevator,
  positionConversionFactor: 0.05,
  velocityConversionFactor: 0.05 / 60.0,
);

// ---------------------------------------------------------------------------
// Phase 1.7 — Standalone factory unit tests
// ---------------------------------------------------------------------------

void main() {
  group('createStandaloneSimulatedDevice', () {
    test('flywheel type creates FlywheelPhysics', () async {
      final device = await createStandaloneSimulatedDevice(
        type: MechanismType.flywheel,
        identifiedGains: _flywheelGains,
        config: _flywheelConfig,
      );
      final conn = device.connection as SimulatedSparkConnection;
      expect(conn.physics, isA<FlywheelPhysics>());
      device.dispose();
    });

    test('simple type creates FlywheelPhysics', () async {
      final device = await createStandaloneSimulatedDevice(
        type: MechanismType.simple,
        identifiedGains: _flywheelGains,
        config: _flywheelConfig,
      );
      final conn = device.connection as SimulatedSparkConnection;
      expect(conn.physics, isA<FlywheelPhysics>());
      device.dispose();
    });

    test('arm type creates ArmPhysics', () async {
      final device = await createStandaloneSimulatedDevice(
        type: MechanismType.arm,
        identifiedGains: _armGains,
        config: _armConfig,
      );
      final conn = device.connection as SimulatedSparkConnection;
      expect(conn.physics, isA<ArmPhysics>());
      device.dispose();
    });

    test('elevator type creates ElevatorPhysics', () async {
      final device = await createStandaloneSimulatedDevice(
        type: MechanismType.elevator,
        identifiedGains: _elevatorGains,
        config: _elevatorConfig,
      );
      final conn = device.connection as SimulatedSparkConnection;
      expect(conn.physics, isA<ElevatorPhysics>());
      device.dispose();
    });

    test('identified kS is reflected in physics', () async {
      final device = await createStandaloneSimulatedDevice(
        type: MechanismType.flywheel,
        identifiedGains: _flywheelGains,
        config: _flywheelConfig,
      );
      final conn = device.connection as SimulatedSparkConnection;
      expect(conn.physics.kS, closeTo(_flywheelGains.kS, 1e-9));
      device.dispose();
    });

    test('conversion factors are written to parameter store', () async {
      const pcf = 2.5;
      const vcf = 3.75;
      final device = await createStandaloneSimulatedDevice(
        type: MechanismType.flywheel,
        identifiedGains: _flywheelGains,
        config: const MechanismConfig(
          type: MechanismType.flywheel,
          positionConversionFactor: pcf,
          velocityConversionFactor: vcf,
        ),
      );
      final params = device.parameters as SimulatedParameterApi;
      expect(
        params.getParamSync(kParamPositionConvFactor),
        closeTo(pcf, 1e-9),
      );
      expect(
        params.getParamSync(kParamVelocityConvFactor),
        closeTo(vcf, 1e-9),
      );
      device.dispose();
    });

    test('device is simulated', () async {
      final device = await createStandaloneSimulatedDevice(
        type: MechanismType.flywheel,
        identifiedGains: _flywheelGains,
        config: _flywheelConfig,
      );
      expect(device.isSimulated, isTrue);
      device.dispose();
    });

    test('device is NOT added to DeviceManager', () async {
      final dm = DeviceManager();
      final before = dm.devices.length;

      final device = await createStandaloneSimulatedDevice(
        type: MechanismType.flywheel,
        identifiedGains: _flywheelGains,
        config: _flywheelConfig,
      );

      // Factory must not register the device in any DeviceManager instance.
      expect(dm.devices.length, equals(before));

      device.dispose();
      dm.disconnectAll();
    });

    test('zero kA is replaced with a positive fallback (no division-by-zero)',
        () async {
      const gainsWithZeroKa = FeedforwardGains(kS: 0.1, kV: 0.02, kA: 0.0);
      final device = await createStandaloneSimulatedDevice(
        type: MechanismType.flywheel,
        identifiedGains: gainsWithZeroKa,
        config: _flywheelConfig,
      );
      final conn = device.connection as SimulatedSparkConnection;
      expect(conn.physics.kA, greaterThan(0));
      device.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Phase 6.2 — Dialog-level tests
  // -------------------------------------------------------------------------

  group('SimulatedValidationDialog', () {
    /// Wraps the dialog in a minimal [FluentApp] with [Navigator].
    Widget buildTestApp({
      required FeedforwardGains identifiedGains,
      required MechanismConfig config,
      bool isPositionMode = false,
    }) {
      return FluentApp(
        home: NavigationView(
          content: Builder(
            builder: (context) => SimulatedValidationDialog(
              identifiedGains: identifiedGains,
              controllerGains: identifiedGains,
              pidGains: const PidResult(kP: 0.5, kI: 0.0, kD: 0.01),
              isPositionMode: isPositionMode,
              mechanismConfig: config,
            ),
          ),
        ),
      );
    }

    testWidgets('renders with flywheel config and no exceptions',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        identifiedGains: _flywheelGains,
        config: _flywheelConfig,
      ));

      // Allow initState async work to settle.
      await tester.pump(const Duration(milliseconds: 50));

      // Dialog should show the title area.
      expect(find.text('Run'), findsOneWidget);
      expect(find.text('Emergency Stop'), findsOneWidget);
    });

    testWidgets('renders in position mode without exceptions', (tester) async {
      await tester.pumpWidget(buildTestApp(
        identifiedGains: _armGains,
        config: _armConfig,
        isPositionMode: true,
      ));

      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Run'), findsOneWidget);
    });

    testWidgets('dispose path is safe when no test is running', (tester) async {
      await tester.pumpWidget(buildTestApp(
        identifiedGains: _flywheelGains,
        config: _flywheelConfig,
      ));
      await tester.pump(const Duration(milliseconds: 50));

      // Replace the widget tree — triggers dispose.
      await tester.pumpWidget(const FluentApp(home: SizedBox()));
      // If no exception is thrown, the abort/close path is safe.
    });

    testWidgets('emergency stop button is disabled when not running',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        identifiedGains: _flywheelGains,
        config: _flywheelConfig,
      ));
      await tester.pump(const Duration(milliseconds: 50));

      // Find the Emergency Stop button.  It should be disabled (no test running).
      final emergencyBtn = find.widgetWithText(Button, 'Emergency Stop');
      expect(emergencyBtn, findsOneWidget);

      // The button is disabled initially (onPressed is null when not running).
      final buttonWidget = tester.widget<Button>(emergencyBtn);
      expect(buttonWidget.onPressed, isNull);
    });

    testWidgets('run button is disabled while device is initialising',
        (tester) async {
      await tester.pumpWidget(buildTestApp(
        identifiedGains: _flywheelGains,
        config: _flywheelConfig,
      ));

      // Pump once — device is still initialising (async).
      await tester.pump();

      final runBtn = find.widgetWithText(FilledButton, 'Run');
      expect(runBtn, findsOneWidget);
      final btnWidget = tester.widget<FilledButton>(runBtn);
      expect(btnWidget.onPressed, isNull);
    });
  });
}
