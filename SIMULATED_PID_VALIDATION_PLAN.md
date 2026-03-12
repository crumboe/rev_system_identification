# Plan: Simulated PID Validation Popup in Playground

## Summary

Add a **"Simulate PID"** button to the What If PID Playground that opens a popup dialog running a full closed-loop validation test against a **simulated** motor. The physics model uses the identified feedforward gains as the plant (ground truth), while the controller uses the user's adjusted PID + FF slider values. The popup mirrors the existing validation screen layout (live plots + mechanism visual + metrics) but is entirely self-contained — no real hardware needed, no risk of damaging a motor.

## Architecture Overview

The existing infrastructure makes this feasible with minimal new code:

- **Physics models** (`FlywheelPhysics`, `ArmPhysics`, `ElevatorPhysics`) already accept custom kS/kV/kA/kG via constructor parameters
- **`ValidationRunner`** already works with any `SparkDevice` (simulated or real) — no changes needed
- **Simulated device wiring** (`connectSimulated()` pattern in `DeviceManager`) shows exactly how to build a standalone simulated device

**Key design decision**: The physics model (plant) uses the **originally-identified** FF gains as ground truth. The controller uses the playground's **current slider values** (PID + FF). This lets the user see how their tuning changes would theoretically affect control of their specific system.

---

## Implementation Steps

### Phase 1: Standalone Simulated Device Factory

**Goal**: A utility function that creates a self-contained simulated `SparkDevice` without touching `DeviceManager`.

**New file**: `lib/simulation/standalone_sim.dart`

Create a `createStandaloneSimulatedDevice()` function:

- **Inputs**: `MechanismType type`, `FeedforwardGains identifiedGains`, `MechanismConfig config`
- **Outputs**: `SparkDevice` (self-contained, not registered with `DeviceManager`)
- **Logic**:
  - Switch on `MechanismType`:
    - `flywheel` / `simple` → `FlywheelPhysics(kS: gains.kS, kV: gains.kV, kA: gains.kA)`
    - `arm` → `ArmPhysics(kS: gains.kS, kV: gains.kV, kA: gains.kA, kG: gains.kG)`
    - `elevator` → `ElevatorPhysics(kS: gains.kS, kV: gains.kV, kA: gains.kA, kG: gains.kG)`
  - Use `noiseLevel: 0.005` (light noise for visual realism)
  - Wire up components following the pattern in `DeviceManager.connectSimulated()` (line 342):
    - `SimulatedSparkConnection(physics)`
    - `SimulatedParameterApi()`
    - `SimulatedControlApi(physics, parameters)`
    - `SimulatedPidFfController(parameters, physics)` → attach to control API
    - Set `connection.controlApi` and `connection.paramApi`
  - Write conversion factors from `MechanismConfig` to `SimulatedParameterApi`:
    - `kParamPositionConvFactor` ← `config.positionConversionFactor`
    - `kParamVelocityConvFactor` ← `config.velocityConversionFactor`
  - Return `SparkDevice(isSimulated: true, ...)` — do **NOT** add to `DeviceManager._devices`

**Reference**: `lib/devices/device_manager.dart` lines 342–388

---

### Phase 2: Simulated Validation Dialog Widget

**Goal**: A popup dialog that runs validation against the standalone simulated device.

**New file**: `lib/ui/widgets/simulated_validation_dialog.dart`

#### Constructor Inputs

| Parameter | Type | Source |
|-----------|------|--------|
| `identifiedGains` | `FeedforwardGains` | Original system identification results (plant ground truth) |
| `controllerGains` | `FeedforwardGains` | Current playground FF slider values (controller tuning) |
| `pidGains` | `PidResult` | Current playground PID slider values |
| `isPositionMode` | `bool` | Matches playground's current velocity/position toggle |
| `mechanismConfig` | `MechanismConfig` | From `mechanismConfigProvider` (app state) |

#### Dialog Layout

Modeled after `lib/ui/screens/validation_screen.dart`:

```
┌─────────────────────────────────────────────────────────┐
│  Simulated PID Validation — Velocity/Position Step   [X]│
├─────────────────────────────────────────────────────────┤
│  [▶ Run]  Status: Ready              [⬛ EMERGENCY STOP]│
├───────────────────────────────────┬─────────────────────┤
│  ┌─────────────┬─────────────┐    │                     │
│  │  Velocity   │   Voltage   │    │   Mechanism Visual  │
│  │  (chart)    │   (chart)   │    │   (Arm / Elevator   │
│  ├─────────────┼─────────────┤    │    / JogPanel)      │
│  │  Position   │   Current   │    │                     │
│  │  (chart)    │   (chart)   │    │                     │
│  └─────────────┴─────────────┘    │                     │
├───────────────────────────────────┴─────────────────────┤
│  Rise Time: —    Overshoot: —    Steady-State Error: —  │
└─────────────────────────────────────────────────────────┘
```

- Charts: `fl_chart` `LineChart` — measured data (solid blue) + setpoint overlay (dashed green)
- Mechanism visual: `ArmVisual`, `ElevatorVisual`, or `JogPanel` based on `mechanismConfig.type`
- Metrics strip: Rise Time (ms), Overshoot (%), Steady-State Error

#### Lifecycle

**`initState`**:
1. Call `createStandaloneSimulatedDevice()` with `identifiedGains` and `mechanismConfig`
2. Write playground's controller gains to simulated device parameter API:
   - PID: `kParamSlot0P`, `kParamSlot0I`, `kParamSlot0D`
   - FF: `kParamSlot0FfKs`, `kParamSlot0FfKv`, `kParamSlot0FfKa`, `kParamSlot0FfKg`
   - Conversion factors: `kParamPositionConvFactor`, `kParamVelocityConvFactor`
3. Create `ValidationRunner` with the simulated device, `mechanismConfig`, and gains

**Run button press**:
- If `isPositionMode`: call `_runner.runPositionTest(params, onProgress: _onProgress)`
- Else: call `_runner.runVelocityTest(params, onProgress: _onProgress)`
- `_onProgress` callback: append `DataPoint` to `_liveData`, update setpoints list, `setState()` to refresh charts
- On completion: compute and display Rise Time, Overshoot, Steady-State Error

**`dispose`**:
- Abort any running test (`_runner?.abort()`)
- Close simulated device connection (cleanup internal timers)
- No `DeviceManager` cleanup needed since device was never registered

---

### Phase 3: Wire Button into PID Playground

**Goal**: Add the trigger button to the existing playground UI.

#### `lib/ui/widgets/pid_playground.dart`

- Add a `FilledButton` labeled **"Simulate PID"** next to the existing Reset button
- On press → `showDialog()` with `SimulatedValidationDialog`:
  ```dart
  showDialog(
    context: context,
    builder: (_) => SimulatedValidationDialog(
      identifiedGains: widget.ff,
      controllerGains: FeedforwardGains(
        kS: _kS, kV: _kV, kA: _kA, kG: _kG, rSquared: 0,
      ),
      pidGains: PidResult(kP: _kP, kI: _kI, kD: _kD),
      isPositionMode: widget.isPositionMode,
      mechanismConfig: widget.mechanismConfig,
    ),
  );
  ```
- Add `MechanismConfig mechanismConfig` as a new constructor parameter on `PidPlayground`

#### `lib/ui/screens/results_screen.dart`

- Pass `mechanismConfig` from `ref.watch(mechanismConfigProvider)` to the `PidPlayground` widget

---

### Phase 4: Verification & Polish

#### Testing

- Create `test/simulated_validation_dialog_test.dart`:
  - Construct dialog with known flywheel gains
  - Verify it renders without errors
  - Optionally: run a simulated test programmatically and verify metrics are reasonable

#### Edge Cases

- **Gains not computed**: "Simulate PID" button should already be unreachable since the playground only appears when `_ff != null`
- **Dialog close during running test**: `dispose()` must call `_runner?.abort()` before closing the simulated connection
- **Arm/Elevator initial position**: Set to mechanism-specific sensible defaults (0° for arm, 0" for elevator)
- **Emergency stop**: Should abort the simulated test immediately (same behavior as real validation screen)

---

## Files to Modify

| File | Change |
|------|--------|
| `lib/ui/widgets/pid_playground.dart` | Add "Simulate PID" button, add `mechanismConfig` constructor parameter |
| `lib/ui/screens/results_screen.dart` | Pass `MechanismConfig` to `PidPlayground` |

## Files to Create

| File | Purpose |
|------|---------|
| `lib/simulation/standalone_sim.dart` | Standalone simulated device factory function |
| `lib/ui/widgets/simulated_validation_dialog.dart` | Popup validation dialog widget |
| `test/simulated_validation_dialog_test.dart` | Widget test for the dialog |

## Reference Files (read-only)

| File | What to Reference |
|------|-------------------|
| `lib/ui/screens/validation_screen.dart` | Chart layout, mechanism visual placement, metrics strip, status bar pattern |
| `lib/sysid/validation_runner.dart` | `ValidationRunner` constructor, `runVelocityTest()`, `runPositionTest()`, `ValidationParams` |
| `lib/devices/device_manager.dart` | `connectSimulated()` wiring pattern (lines 342–388) |
| `lib/simulation/simulated_device.dart` | `SimulatedSparkConnection`, `SimulatedParameterApi`, `SimulatedControlApi`, `SimulatedPidFfController` |
| `lib/simulation/flywheel_physics.dart` | Constructor with custom kS/kV/kA |
| `lib/simulation/arm_physics.dart` | Constructor with custom kS/kV/kA/kG |
| `lib/simulation/elevator_physics.dart` | Constructor with custom kS/kV/kA/kG |
| `lib/data/test_data.dart` | `FeedforwardGains`, `PidResult`, `ValidationResult`, `DataPoint`, `ValidationParams` |
| `lib/mechanisms/mechanism.dart` | `MechanismConfig`, `MechanismType` enum |
| `lib/ui/widgets/arm_visual.dart` | Arm mechanism visualization widget |
| `lib/ui/widgets/elevator_visual.dart` | Elevator mechanism visualization widget |
| `lib/ui/widgets/jog_panel.dart` | Flywheel/simple mechanism jog visualization |

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Plant uses identified FF gains (ground truth)** | The real motor doesn't change when you change controller gains. Playground FF sliders only affect the controller side. |
| **Test mode matches playground mode** | Velocity loop → velocity step test; Position loop → position step test. No MAXMotion in the popup. |
| **Mechanism visual included** | Provides spatial context for arm/elevator behavior during simulation. |
| **Standalone device (not registered with DeviceManager)** | Avoids side effects on the main app's device state. Created and disposed entirely within the dialog lifecycle. |
| **`ValidationRunner` reused as-is** | No modifications needed — it already works identically with simulated devices through the interface-based design. |

## Manual Verification Checklist

- [ ] Connect simulated device → run sysid → go to Results → open "What If" PID Playground
- [ ] Adjust PID sliders → click "Simulate PID" → dialog opens with correct title (Velocity/Position)
- [ ] Click "Run" in dialog → charts animate in real-time with step response data
- [ ] Verify response qualitatively matches the playground's step response chart
- [ ] Close dialog → reopen with different gains → run again → verify different response
- [ ] Test with **flywheel** mechanism → JogPanel visual appears
- [ ] Test with **arm** mechanism → ArmVisual appears, gravity compensation visible
- [ ] Test with **elevator** mechanism → ElevatorVisual appears, gravity compensation visible
- [ ] Close dialog mid-test → no crash (abort + dispose cleanup)
- [ ] Run `flutter test` → no regressions in existing test suite