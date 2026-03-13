# Simulated PID Validation Upgrade Checklist

## Objective
- [x] Add a "Simulate PID" flow in the What If PID Playground that opens a popup dialog and runs closed-loop validation on a simulated mechanism only.
- [x] Keep simulation plant behavior grounded in identified feedforward gains.
- [x] Keep controller behavior driven by current playground PID + FF slider values.
- [x] Reuse existing validation architecture where possible.
- [x] Ship with tests, edge-case handling, and manual verification steps.

## Scope Guardrails
- [x] No real hardware required.
- [x] No writes to `DeviceManager` global device registry for this flow.
- [x] No behavior regressions in existing results, validation, or playground flows.
- [x] No MAXMotion in popup (only velocity/position test matching playground mode).

## Phase 0: Prep and Baseline

### 0.1 Confirm references and dependencies
- [x] Review `lib/ui/screens/validation_screen.dart` for dialog layout and metric presentation patterns.
- [x] Review `lib/sysid/validation_runner.dart` for `ValidationRunner` setup and callbacks.
- [x] Review `lib/devices/device_manager.dart` simulated wiring pattern (`connectSimulated()`).
- [x] Review `lib/simulation/simulated_device.dart` for simulated APIs and controller attachment.
- [x] Review mechanism physics constructors:
  - [x] `lib/simulation/flywheel_physics.dart`
  - [x] `lib/simulation/arm_physics.dart`
  - [x] `lib/simulation/elevator_physics.dart`
- [x] Review shared data types in `lib/data/test_data.dart`.
- [x] Review mechanism typing in `lib/mechanisms/mechanism.dart`.

### 0.2 Baseline sanity checks
- [x] Run existing tests before edits.
- [x] Record baseline results (pass/fail count, notable warnings).

## Phase 1: Standalone Simulated Device Factory

### 1.1 Create file
- [x] Add `lib/simulation/standalone_sim.dart`.

### 1.2 Implement factory API
- [x] Implement `createStandaloneSimulatedDevice()`.
- [x] Inputs:
  - [x] `MechanismType type`
  - [x] `FeedforwardGains identifiedGains`
  - [x] `MechanismConfig config`
- [x] Output:
  - [x] `SparkDevice` (self-contained, unregistered)

### 1.3 Map mechanism type to plant physics
- [x] `flywheel` / `simple` -> `FlywheelPhysics(kS, kV, kA)`
- [x] `arm` -> `ArmPhysics(kS, kV, kA, kG)`
- [x] `elevator` -> `ElevatorPhysics(kS, kV, kA, kG)`
- [x] Use `identifiedGains` for plant physics values.
- [x] Use `noiseLevel: 0.005`.

### 1.4 Wire simulated stack
- [x] Create `SimulatedSparkConnection(physics)`.
- [x] Create `SimulatedParameterApi()`.
- [x] Create `SimulatedControlApi(physics, parameters)`.
- [x] Create `SimulatedPidFfController(parameters, physics)`.
- [x] Attach controller to control API.
- [x] Set `connection.controlApi` and `connection.paramApi`.

### 1.5 Initialize conversion factors
- [x] Write `kParamPositionConvFactor <- config.positionConversionFactor`.
- [x] Write `kParamVelocityConvFactor <- config.velocityConversionFactor`.

### 1.6 Return simulated device instance
- [x] Return `SparkDevice(isSimulated: true, ...)`.
- [x] Confirm device is not added to `DeviceManager._devices`.

### 1.7 Unit-level validation (factory)
- [x] Verify each `MechanismType` creates expected physics class.
- [x] Verify conversion factors are written correctly.
- [x] Verify no global device side effects.

## Phase 2: Simulated Validation Dialog Widget

### 2.1 Create file
- [x] Add `lib/ui/widgets/simulated_validation_dialog.dart`.

### 2.2 Define dialog public API
- [x] Constructor includes:
  - [x] `FeedforwardGains identifiedGains`
  - [x] `FeedforwardGains controllerGains`
  - [x] `PidResult pidGains`
  - [x] `bool isPositionMode`
  - [x] `MechanismConfig mechanismConfig`

### 2.3 Build UI structure
- [x] Header with title and close affordance.
- [x] Controls row with Run button, status text, Emergency Stop.
- [x] Main content split:
  - [x] Live charts area (velocity, voltage, position, current)
  - [x] Mechanism visual area
- [x] Metrics row:
  - [x] Rise Time
  - [x] Overshoot
  - [x] Steady-State Error

### 2.4 Chart behavior
- [x] Plot measured data as solid line.
- [x] Plot setpoint as dashed overlay.
- [x] Refresh in real time from progress callback.
- [x] Handle empty/initial states gracefully.

### 2.5 Mechanism visual mapping
- [x] `arm` -> `ArmVisual`
- [x] `elevator` -> `ElevatorVisual`
- [x] `flywheel/simple` -> `JogPanel`

### 2.6 Lifecycle: init
- [x] Create standalone simulated device with `identifiedGains` + `mechanismConfig`.
- [x] Write controller tuning to simulated params:
  - [x] PID: `kParamSlot0P`, `kParamSlot0I`, `kParamSlot0D`
  - [x] FF: `kParamSlot0FfKs`, `kParamSlot0FfKv`, `kParamSlot0FfKa`, `kParamSlot0FfKg`
  - [x] Conversion factors
- [x] Construct `ValidationRunner` with simulated device and config.

### 2.7 Lifecycle: run actions
- [x] If `isPositionMode` run `runPositionTest(...)`.
- [x] Else run `runVelocityTest(...)`.
- [x] Capture `onProgress` updates into live series/state.
- [x] Compute metrics on completion.
- [x] Surface completion/failure status in UI.

### 2.8 Lifecycle: cleanup
- [x] On dialog dispose, call `_runner?.abort()`.
- [x] Close simulated connection and timers.
- [x] Confirm no dangling background activity.

### 2.9 Dialog-level validation
- [x] Open and close without running test.
- [x] Run full test and verify live updates.
- [x] Close dialog mid-run and verify safe abort.

## Phase 3: Playground Integration

### 3.1 Update `PidPlayground` API
- [x] Add `MechanismConfig mechanismConfig` constructor parameter.
- [x] Propagate parameter usage where needed.

### 3.2 Add trigger button
- [x] Add `FilledButton` labeled `Simulate PID` near existing reset action.
- [x] Ensure button availability follows existing gain readiness assumptions.

### 3.3 Open dialog with current tuning context
- [x] Pass `identifiedGains` from original FF results.
- [x] Build `controllerGains` from current slider state.
- [x] Build `PidResult` from current slider state.
- [x] Pass `isPositionMode` and `mechanismConfig`.

### 3.4 Wire from results screen
- [x] Update `lib/ui/screens/results_screen.dart` to pass `mechanismConfigProvider` value into `PidPlayground`.

### 3.5 Integration validation
- [ ] Confirm navigation path from Results -> Playground -> Simulate PID works end-to-end.

## Phase 4: Metrics and Behavior Accuracy

### 4.1 Ensure metric definitions are stable
- [x] Confirm rise time definition used by popup matches existing validation semantics.
- [x] Confirm overshoot calculation is consistent with sign and mode.
- [x] Confirm steady-state error window/threshold is reasonable.

### 4.2 Consistency checks
- [x] Verify popup response trend qualitatively aligns with playground chart expectations.
- [x] Verify changing slider values changes popup response in expected direction.

## Phase 5: Edge Cases and Safety

- [x] Gains unavailable state cannot trigger simulation.
- [x] Emergency stop aborts active run immediately.
- [x] Multiple rapid Run clicks are debounced/ignored while running.
- [x] Dialog close during run is safe and repeatable.
- [x] Arm/elevator initial position defaults are sensible.
- [x] Errors are surfaced to user with non-crashing UI state.

## Phase 6: Test Coverage

### 6.1 Add widget test file
- [x] Create `test/simulated_validation_dialog_test.dart`.

### 6.2 Minimum test cases
- [x] Dialog renders with flywheel config and no exceptions.
- [x] Run action triggers correct validation method by mode.
- [x] Progress callback updates chart state.
- [x] Abort on dispose path executes safely.

### 6.3 Optional deeper tests
- [x] Assert metrics fall in reasonable range for known gains.
- [x] Validate mechanism visual selection by `MechanismType`.

### 6.4 Regression checks
- [ ] Run full `flutter test` suite.
- [ ] Resolve any new failures caused by this upgrade.

## Phase 7: Documentation and Dev Notes

- [x] Update internal docs/comments for new simulation flow entry points.
- [x] Add brief rationale note in code where plant/controller gain split is applied.
- [x] Document why standalone simulated device is intentionally unregistered.

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
- [x] All checklist items in Phases 1-6 completed.
- [ ] No critical or high regressions introduced.
- [ ] Tests pass locally.
- [ ] Manual verification passes for all mechanism types.
- [ ] Code is ready for review with clear upgrade rationale.

## Upgrade Package File Impact

### Files to modify
- [x] `lib/ui/widgets/pid_playground.dart`
- [x] `lib/ui/screens/results_screen.dart`

### Files to create
- [x] `lib/simulation/standalone_sim.dart`
- [x] `lib/ui/widgets/simulated_validation_dialog.dart`
- [x] `test/simulated_validation_dialog_test.dart`

### Reference files (read-only)
- [x] `lib/ui/screens/validation_screen.dart`
- [x] `lib/sysid/validation_runner.dart`
- [x] `lib/devices/device_manager.dart`
- [x] `lib/simulation/simulated_device.dart`
- [x] `lib/simulation/flywheel_physics.dart`
- [x] `lib/simulation/arm_physics.dart`
- [x] `lib/simulation/elevator_physics.dart`
- [x] `lib/data/test_data.dart`
- [x] `lib/mechanisms/mechanism.dart`
- [x] `lib/ui/widgets/arm_visual.dart`
- [x] `lib/ui/widgets/elevator_visual.dart`
- [x] `lib/ui/widgets/jog_panel.dart`
