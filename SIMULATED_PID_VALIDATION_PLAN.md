# Simulated PID Validation Upgrade Checklist

## Objective
- [ ] Add a "Simulate PID" flow in the What If PID Playground that opens a popup dialog and runs closed-loop validation on a simulated mechanism only.
- [ ] Keep simulation plant behavior grounded in identified feedforward gains.
- [ ] Keep controller behavior driven by current playground PID + FF slider values.
- [ ] Reuse existing validation architecture where possible.
- [ ] Ship with tests, edge-case handling, and manual verification steps.

## Scope Guardrails
- [ ] No real hardware required.
- [ ] No writes to `DeviceManager` global device registry for this flow.
- [ ] No behavior regressions in existing results, validation, or playground flows.
- [ ] No MAXMotion in popup (only velocity/position test matching playground mode).

## Phase 0: Prep and Baseline

### 0.1 Confirm references and dependencies
- [ ] Review `lib/ui/screens/validation_screen.dart` for dialog layout and metric presentation patterns.
- [ ] Review `lib/sysid/validation_runner.dart` for `ValidationRunner` setup and callbacks.
- [ ] Review `lib/devices/device_manager.dart` simulated wiring pattern (`connectSimulated()`).
- [ ] Review `lib/simulation/simulated_device.dart` for simulated APIs and controller attachment.
- [ ] Review mechanism physics constructors:
  - [ ] `lib/simulation/flywheel_physics.dart`
  - [ ] `lib/simulation/arm_physics.dart`
  - [ ] `lib/simulation/elevator_physics.dart`
- [ ] Review shared data types in `lib/data/test_data.dart`.
- [ ] Review mechanism typing in `lib/mechanisms/mechanism.dart`.

### 0.2 Baseline sanity checks
- [ ] Run existing tests before edits.
- [ ] Record baseline results (pass/fail count, notable warnings).

## Phase 1: Standalone Simulated Device Factory

### 1.1 Create file
- [ ] Add `lib/simulation/standalone_sim.dart`.

### 1.2 Implement factory API
- [ ] Implement `createStandaloneSimulatedDevice()`.
- [ ] Inputs:
  - [ ] `MechanismType type`
  - [ ] `FeedforwardGains identifiedGains`
  - [ ] `MechanismConfig config`
- [ ] Output:
  - [ ] `SparkDevice` (self-contained, unregistered)

### 1.3 Map mechanism type to plant physics
- [ ] `flywheel` / `simple` -> `FlywheelPhysics(kS, kV, kA)`
- [ ] `arm` -> `ArmPhysics(kS, kV, kA, kG)`
- [ ] `elevator` -> `ElevatorPhysics(kS, kV, kA, kG)`
- [ ] Use `identifiedGains` for plant physics values.
- [ ] Use `noiseLevel: 0.005`.

### 1.4 Wire simulated stack
- [ ] Create `SimulatedSparkConnection(physics)`.
- [ ] Create `SimulatedParameterApi()`.
- [ ] Create `SimulatedControlApi(physics, parameters)`.
- [ ] Create `SimulatedPidFfController(parameters, physics)`.
- [ ] Attach controller to control API.
- [ ] Set `connection.controlApi` and `connection.paramApi`.

### 1.5 Initialize conversion factors
- [ ] Write `kParamPositionConvFactor <- config.positionConversionFactor`.
- [ ] Write `kParamVelocityConvFactor <- config.velocityConversionFactor`.

### 1.6 Return simulated device instance
- [ ] Return `SparkDevice(isSimulated: true, ...)`.
- [ ] Confirm device is not added to `DeviceManager._devices`.

### 1.7 Unit-level validation (factory)
- [ ] Verify each `MechanismType` creates expected physics class.
- [ ] Verify conversion factors are written correctly.
- [ ] Verify no global device side effects.

## Phase 2: Simulated Validation Dialog Widget

### 2.1 Create file
- [ ] Add `lib/ui/widgets/simulated_validation_dialog.dart`.

### 2.2 Define dialog public API
- [ ] Constructor includes:
  - [ ] `FeedforwardGains identifiedGains`
  - [ ] `FeedforwardGains controllerGains`
  - [ ] `PidResult pidGains`
  - [ ] `bool isPositionMode`
  - [ ] `MechanismConfig mechanismConfig`

### 2.3 Build UI structure
- [ ] Header with title and close affordance.
- [ ] Controls row with Run button, status text, Emergency Stop.
- [ ] Main content split:
  - [ ] Live charts area (velocity, voltage, position, current)
  - [ ] Mechanism visual area
- [ ] Metrics row:
  - [ ] Rise Time
  - [ ] Overshoot
  - [ ] Steady-State Error

### 2.4 Chart behavior
- [ ] Plot measured data as solid line.
- [ ] Plot setpoint as dashed overlay.
- [ ] Refresh in real time from progress callback.
- [ ] Handle empty/initial states gracefully.

### 2.5 Mechanism visual mapping
- [ ] `arm` -> `ArmVisual`
- [ ] `elevator` -> `ElevatorVisual`
- [ ] `flywheel/simple` -> `JogPanel`

### 2.6 Lifecycle: init
- [ ] Create standalone simulated device with `identifiedGains` + `mechanismConfig`.
- [ ] Write controller tuning to simulated params:
  - [ ] PID: `kParamSlot0P`, `kParamSlot0I`, `kParamSlot0D`
  - [ ] FF: `kParamSlot0FfKs`, `kParamSlot0FfKv`, `kParamSlot0FfKa`, `kParamSlot0FfKg`
  - [ ] Conversion factors
- [ ] Construct `ValidationRunner` with simulated device and config.

### 2.7 Lifecycle: run actions
- [ ] If `isPositionMode` run `runPositionTest(...)`.
- [ ] Else run `runVelocityTest(...)`.
- [ ] Capture `onProgress` updates into live series/state.
- [ ] Compute metrics on completion.
- [ ] Surface completion/failure status in UI.

### 2.8 Lifecycle: cleanup
- [ ] On dialog dispose, call `_runner?.abort()`.
- [ ] Close simulated connection and timers.
- [ ] Confirm no dangling background activity.

### 2.9 Dialog-level validation
- [ ] Open and close without running test.
- [ ] Run full test and verify live updates.
- [ ] Close dialog mid-run and verify safe abort.

## Phase 3: Playground Integration

### 3.1 Update `PidPlayground` API
- [ ] Add `MechanismConfig mechanismConfig` constructor parameter.
- [ ] Propagate parameter usage where needed.

### 3.2 Add trigger button
- [ ] Add `FilledButton` labeled `Simulate PID` near existing reset action.
- [ ] Ensure button availability follows existing gain readiness assumptions.

### 3.3 Open dialog with current tuning context
- [ ] Pass `identifiedGains` from original FF results.
- [ ] Build `controllerGains` from current slider state.
- [ ] Build `PidResult` from current slider state.
- [ ] Pass `isPositionMode` and `mechanismConfig`.

### 3.4 Wire from results screen
- [ ] Update `lib/ui/screens/results_screen.dart` to pass `mechanismConfigProvider` value into `PidPlayground`.

### 3.5 Integration validation
- [ ] Confirm navigation path from Results -> Playground -> Simulate PID works end-to-end.

## Phase 4: Metrics and Behavior Accuracy

### 4.1 Ensure metric definitions are stable
- [ ] Confirm rise time definition used by popup matches existing validation semantics.
- [ ] Confirm overshoot calculation is consistent with sign and mode.
- [ ] Confirm steady-state error window/threshold is reasonable.

### 4.2 Consistency checks
- [ ] Verify popup response trend qualitatively aligns with playground chart expectations.
- [ ] Verify changing slider values changes popup response in expected direction.

## Phase 5: Edge Cases and Safety

- [ ] Gains unavailable state cannot trigger simulation.
- [ ] Emergency stop aborts active run immediately.
- [ ] Multiple rapid Run clicks are debounced/ignored while running.
- [ ] Dialog close during run is safe and repeatable.
- [ ] Arm/elevator initial position defaults are sensible.
- [ ] Errors are surfaced to user with non-crashing UI state.

## Phase 6: Test Coverage

### 6.1 Add widget test file
- [ ] Create `test/simulated_validation_dialog_test.dart`.

### 6.2 Minimum test cases
- [ ] Dialog renders with flywheel config and no exceptions.
- [ ] Run action triggers correct validation method by mode.
- [ ] Progress callback updates chart state.
- [ ] Abort on dispose path executes safely.

### 6.3 Optional deeper tests
- [ ] Assert metrics fall in reasonable range for known gains.
- [ ] Validate mechanism visual selection by `MechanismType`.

### 6.4 Regression checks
- [ ] Run full `flutter test` suite.
- [ ] Resolve any new failures caused by this upgrade.

## Phase 7: Documentation and Dev Notes

- [ ] Update internal docs/comments for new simulation flow entry points.
- [ ] Add brief rationale note in code where plant/controller gain split is applied.
- [ ] Document why standalone simulated device is intentionally unregistered.

## Phase 8: Final Verification (Manual)

- [ ] Simulated device -> SysId -> Results -> PID Playground -> Simulate PID works.
- [ ] Velocity mode opens velocity test behavior.
- [ ] Position mode opens position test behavior.
- [ ] Charts animate with measured + setpoint overlays.
- [ ] Flywheel shows `JogPanel`.
- [ ] Arm shows `ArmVisual` with gravity effects.
- [ ] Elevator shows `ElevatorVisual` with gravity effects.
- [ ] Close and reopen dialog with new gains yields changed response.
- [ ] Close mid-test does not crash or leak.
- [ ] Existing workflows remain intact.

## Definition of Done
- [ ] All checklist items in Phases 1-6 completed.
- [ ] No critical or high regressions introduced.
- [ ] Tests pass locally.
- [ ] Manual verification passes for all mechanism types.
- [ ] Code is ready for review with clear upgrade rationale.

## Upgrade Package File Impact

### Files to modify
- [ ] `lib/ui/widgets/pid_playground.dart`
- [ ] `lib/ui/screens/results_screen.dart`

### Files to create
- [ ] `lib/simulation/standalone_sim.dart`
- [ ] `lib/ui/widgets/simulated_validation_dialog.dart`
- [ ] `test/simulated_validation_dialog_test.dart`

### Reference files (read-only)
- [ ] `lib/ui/screens/validation_screen.dart`
- [ ] `lib/sysid/validation_runner.dart`
- [ ] `lib/devices/device_manager.dart`
- [ ] `lib/simulation/simulated_device.dart`
- [ ] `lib/simulation/flywheel_physics.dart`
- [ ] `lib/simulation/arm_physics.dart`
- [ ] `lib/simulation/elevator_physics.dart`
- [ ] `lib/data/test_data.dart`
- [ ] `lib/mechanisms/mechanism.dart`
- [ ] `lib/ui/widgets/arm_visual.dart`
- [ ] `lib/ui/widgets/elevator_visual.dart`
- [ ] `lib/ui/widgets/jog_panel.dart`
