# REV System Identification

A Windows desktop application for characterizing REV Robotics SPARK motor controllers. It performs **quasistatic** and **dynamic** tests to compute feedforward constants (kS, kV, kA, kG) and optimal PID gains for flywheels, arms, and elevators — the same approach used by WPILib's SysId tool, wrapped in an interactive, educational interface designed for high-school FRC teams.

## Features

- **USB-CDC serial connection** to SPARK MAX / SPARK Flex controllers at 115200 baud via REV's CAN-over-USB protocol
- **Quasistatic tests** — slowly ramp voltage to map the steady-state Voltage vs. Velocity relationship (extracts kS, kV)
- **Dynamic tests** — step voltage to capture transient acceleration behavior (extracts kA)
- **Gravity compensation** — for arms (angle-dependent: kG·cos θ) and elevators (constant kG)
- **OLS regression** — ordinary least-squares fit of the full feedforward model to all collected data, with R² quality metric
- **PID derivation** — converts feedforward constants into velocity and position PID gains with explanatory tooltips
- **Real-time charts** — live Velocity, Voltage, Position, and Current plots during testing, color-coded per test segment
- **Mechanism visuals** — animated arm and elevator widgets that track encoder position in real time
- **Draggable simulation visuals** — drag the arm or elevator to set a starting position before running a simulated test
- **Interactive chart walkthrough** — step-by-step annotations explaining what each chart shows and how the constants are derived
- **Feedforward tooltips** — hover any computed constant to see exactly how it was calculated, what regression coefficient it corresponds to, and what it means physically
- **Simulated devices** — three built-in physics simulations (flywheel, arm, elevator) with known-answer parameters so students can practice the full workflow without hardware
- **WPILib-compatible export** — save results as a SysId JSON file for use in WPILib projects
- **CAN ID / follower configuration** — configure device CAN IDs and set up follower motors
- **Emergency stop** — immediate motor disable from the test screen

## Architecture

```
lib/
├── can/               # SPARK protocol, status frame parsing, parameter & control APIs
│   ├── interfaces.dart        # Abstract interfaces (ISparkConnection, IHeartbeatManager, etc.)
│   ├── spark_protocol.dart    # CAN frame encoding/decoding
│   ├── spark_connection.dart  # Real USB-serial connection
│   ├── status_parser.dart     # Status frame 0/1/2 parsing
│   ├── parameter_api.dart     # Read/write SPARK parameters
│   └── control_api.dart       # Voltage/duty-cycle commands
├── data/              # Test data model (DataPoint, TestRun, TestType)
├── devices/           # Device manager, connection lifecycle
├── mechanisms/        # Mechanism types (flywheel/arm/elevator), config, soft limits
├── simulation/        # Physics engines & simulated SPARK implementations
│   ├── simulated_physics.dart     # Abstract physics interface
│   ├── flywheel_physics.dart      # Flywheel simulation
│   ├── arm_physics.dart           # Arm simulation (gravity = cos θ)
│   ├── elevator_physics.dart      # Elevator simulation (gravity = constant)
│   └── simulated_device.dart      # Simulated connection, control, parameter, heartbeat
├── state/             # Riverpod state management (app_state.dart)
├── sysid/             # Analysis engines
│   ├── feedforward_analyzer.dart  # OLS regression for kS/kV/kA/kG
│   ├── pid_calculator.dart        # PID gain derivation from feedforward
│   └── test_runner.dart           # Test execution, voltage profiles, safety monitoring
└── ui/
    ├── screens/       # Device, Test, Results, Config screens
    └── widgets/       # Charts, arm/elevator visuals, walkthrough overlay
```

## Feedforward Model

All three mechanism types share the general model:

```
V = kS·sign(ω) + kV·ω + kA·α  [+ kG·gravity_term]
```

| Constant | Meaning | Units | How it's measured |
|----------|---------|-------|-------------------|
| **kS** | Static friction voltage | V | Y-intercept of the quasistatic Voltage vs. Velocity plot (sign(ω) coefficient) |
| **kV** | Velocity constant | V·s/unit | Slope of the quasistatic Voltage vs. Velocity plot (ω coefficient) |
| **kA** | Acceleration constant | V·s²/unit | Extracted from dynamic tests as the α coefficient in the OLS regression |
| **kG** | Gravity compensation | V | cos(θ) coefficient for arms; constant term for elevators; zero for flywheels |
| **R²** | Fit quality | — | 1 − (SS_res / SS_tot); values > 0.9 indicate a good fit |

## Simulated Systems

The app includes three built-in physics simulations with known-answer parameters. Students can connect to these without any hardware to learn the full system-identification workflow.

### Flywheel

A simple rotational inertia with no gravity. Models a spinning mass (e.g., a shooter wheel).

| Parameter | Default Value | Description |
|-----------|--------------|-------------|
| **kS** | 0.14 V | Static friction voltage |
| **kV** | 0.0185 V·s/rot | Velocity constant (per RPM) |
| **kA** | 0.003 V·s²/rot | Acceleration constant (per RPM/s) |
| **kG** | 0.0 V | No gravity component |
| Nominal voltage | 12.0 V | Simulated bus voltage |
| Current per volt | 2.5 A/V | Simulated current readout scaling |
| Noise level | 1.5% | Gaussian sensor noise amplitude |
| Position unit | rotations | Encoder native unit |
| Velocity unit | RPM | — |

**Physics model:** `V = kS·sign(ω) + kV·ω + kA·α`

No position limits. The flywheel spins freely in either direction.

### Arm

A pivoting arm with angle-dependent gravity. Position 0° is horizontal; positive angles are upward.

| Parameter | Default Value | Description |
|-----------|--------------|-------------|
| **kS** | 0.20 V | Static friction voltage |
| **kV** | 0.018 V·s/deg | Velocity constant (per deg/s) |
| **kA** | 0.002 V·s²/deg | Acceleration constant (per deg/s²) |
| **kG** | 0.80 V | Peak gravity torque at horizontal |
| Nominal voltage | 12.0 V | Simulated bus voltage |
| Current per volt | 3.0 A/V | Simulated current readout scaling |
| Noise level | 1.5% | Gaussian sensor noise amplitude |
| Hard limits | −45° to +90° | Physical hard stops |
| Soft limits (preset) | −40° to +85° | Pre-configured safety margins |
| Position conversion | 360 deg/rot | Encoder rotations → degrees |
| Velocity conversion | 6 deg/s per RPM | Encoder RPM → deg/s |

**Physics model:** `V = kS·sign(ω) + kG·cos(θ) + kV·ω + kA·α`

The `cos(θ)` term means gravity compensation is strongest when the arm is horizontal and vanishes at ±90° (vertical). Hard stops clamp position and zero velocity when the arm hits a limit.

### Elevator

A linear mechanism with constant gravity. Position is height in inches.

| Parameter | Default Value | Description |
|-----------|--------------|-------------|
| **kS** | 0.18 V | Static friction voltage |
| **kV** | 0.12 V·s/in | Velocity constant (per in/s) |
| **kA** | 0.015 V·s²/in | Acceleration constant (per in/s²) |
| **kG** | 0.55 V | Constant gravity compensation |
| Nominal voltage | 12.0 V | Simulated bus voltage |
| Current per volt | 3.5 A/V | Simulated current readout scaling |
| Noise level | 1.5% | Gaussian sensor noise amplitude |
| Hard limits | 0″ to 48″ | Physical hard stops |
| Soft limits (preset) | 2″ to 46″ | Pre-configured safety margins |
| Inches per rotation | 1.504 in/rot | ~1.5″ sprocket with 16:1 reduction |
| Position conversion | 1.504 in/rot | Encoder rotations → inches |
| Velocity conversion | 1.504/60 in/s per RPM | Encoder RPM → in/s |

**Physics model:** `V = kS·sign(v) + kG + kV·v + kA·a`

Unlike the arm, gravity on an elevator is position-independent — `kG` is a flat constant voltage offset needed to hold the carriage at any height. Hard stops clamp position at 0″ and 48″.

## Shared Simulation Behavior

All three simulations share these characteristics:

- **10 ms physics tick rate** — the simulation steps at 100 Hz, matching typical robot loop timing
- **Friction modeling** — static friction (stall below kS) and kinetic friction (opposes motion) are both modeled
- **Sensor noise** — velocity and position readings include ±1.5% Gaussian noise to produce realistic scatter in collected data
- **Draggable start position** — on the test screen, simulated arm and elevator visuals can be dragged to set the initial position before running a test
- **Position persistence** — the simulated position is preserved between connections and tests (not reset on connect)

## Getting Started

### Prerequisites

- Flutter SDK ≥ 3.11.0
- Windows 10 or later (targets Windows desktop only)

### Build & Run

```powershell
flutter pub get
flutter run -d windows
```

### Production Build

```powershell
flutter build windows
```

The executable will be at `build/windows/x64/runner/Release/rev_system_identification.exe`.

### Connecting to Hardware

1. Plug a SPARK MAX or SPARK Flex into USB
2. Open the app → **Devices** screen
3. Select the COM port and click **Connect**
4. The device's CAN ID and firmware version will be read automatically

### Using Simulated Devices

1. On the **Devices** screen, select one of the simulated entries: *🧪 Simulated Flywheel*, *🧪 Simulated Arm*, or *🧪 Simulated Elevator*
2. Mechanism config (conversion factors, soft limits, test params) is auto-populated
3. Switch to the **Test** screen, optionally drag the arm/elevator to a start position, and run tests
4. View computed feedforward and PID values on the **Results** screen

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| fluent_ui | 4.14.0 | Windows-native Fluent Design UI |
| flutter_libserialport | 0.4.0 | USB-CDC serial communication |
| fl_chart | 0.69.2 | Real-time line charts |
| flutter_riverpod | 2.6.1 | State management |

## SPARK Parameter ID Reference

Extracted from the official **REVLib 2026.0.4** C++ driver headers (`CANSparkParameters.h`).
Source: `maven.revrobotics.com/com/revrobotics/frc/REVLib-driver/2026.0.4/REVLib-driver-2026.0.4-headers.zip`

> **Note:** Feedforward parameters (kS, kA, kG, kCos, kCosRatio) starting at ID 204 require SPARK firmware ≥ 25.0.
> Older SPARK MAX firmware will reject these with "Invalid parameter id".
> kV is the legacy velocity-FF slot (`kV_0` = ID 16, `kV_1` = ID 24, etc.).

### General Configuration

| ID | REVLib Constant | Name | Notes |
|----|----------------|------|-------|
| 0 | `c_Spark_kCANID` | CAN ID | 0–62 |
| 1 | `c_Spark_kInputMode` | Input Mode | 0=PWM, 1=CAN, 2=USB (read-only) |
| 2 | `c_Spark_kMotorType` | Motor Type | 0=Brushed, 1=Brushless |
| 3 | `c_Spark_kCommutationAdvance` | Commutation Advance | |
| 5 | `c_Spark_kControlType` | Control Type | Active control mode (read-only) |
| 6 | `c_Spark_kIdleMode` | Idle Mode | 0=Coast, 1=Brake |
| 7 | `c_Spark_kInputDeadband` | Input Deadband | PWM neutral deadband |
| 9 | `c_Spark_kClosedLoopControlSensor` | Closed-Loop Sensor | Feedback sensor selection |
| 10 | `c_Spark_kPolePairs` | Pole Pairs | |
| 11 | `c_Spark_kCurrentChop` | Current Chop | |
| 12 | `c_Spark_kCurrentChopCycles` | Current Chop Cycles | |
| 45 | `c_Spark_kInverted` | Motor Inverted | 0/1 |
| 56 | `c_Spark_kOpenLoopRampRate` | Open-Loop Ramp Rate | Seconds 0→full |
| 63 | `c_Spark_kMotorKv` | Motor Kv | |
| 74 | `c_Spark_kVoltageCompensationMode` | Voltage Comp Mode | |
| 75 | `c_Spark_kCompensatedNominalVoltage` | Compensated Nominal Voltage | 0=off, e.g. 12.0 |
| 114 | `c_Spark_kClosedLoopRampRate` | Closed-Loop Ramp Rate | Seconds 0→full |
| 155 | `c_Spark_kProductId` | Product ID | Read-only |
| 156 | `c_Spark_kDeviceMajorVersion` | Firmware Major Version | Read-only |
| 157 | `c_Spark_kDeviceMinorVersion` | Firmware Minor Version | Read-only |
| 198 | `c_Spark_kParamTableVersion` | Parameter Table Version | |

### PID Slot 0

| ID | REVLib Constant | Name |
|----|----------------|------|
| 13 | `c_Spark_kP_0` | Proportional Gain |
| 14 | `c_Spark_kI_0` | Integral Gain |
| 15 | `c_Spark_kD_0` | Derivative Gain |
| 16 | `c_Spark_kV_0` | Velocity FF (kV) |
| 17 | `c_Spark_kIZone_0` | I-Zone |
| 18 | `c_Spark_kDFilter_0` | D Filter |
| 19 | `c_Spark_kOutputMin_0` | Min Output (−1…+1) |
| 20 | `c_Spark_kOutputMax_0` | Max Output (−1…+1) |
| 96 | `c_Spark_kIMaxAccum_0` | Max I Accumulator |
| 97 | `c_Spark_kAllowedClosedLoopError_0` | Allowed CL Error |

### PID Slot 1

| ID | REVLib Constant | Name |
|----|----------------|------|
| 21 | `c_Spark_kP_1` | Proportional Gain |
| 22 | `c_Spark_kI_1` | Integral Gain |
| 23 | `c_Spark_kD_1` | Derivative Gain |
| 24 | `c_Spark_kV_1` | Velocity FF (kV) |
| 25 | `c_Spark_kIZone_1` | I-Zone |
| 26 | `c_Spark_kDFilter_1` | D Filter |
| 27 | `c_Spark_kOutputMin_1` | Min Output |
| 28 | `c_Spark_kOutputMax_1` | Max Output |
| 100 | `c_Spark_kIMaxAccum_1` | Max I Accumulator |
| 101 | `c_Spark_kAllowedClosedLoopError_1` | Allowed CL Error |

### PID Slot 2

| ID | REVLib Constant | Name |
|----|----------------|------|
| 29 | `c_Spark_kP_2` | Proportional Gain |
| 30 | `c_Spark_kI_2` | Integral Gain |
| 31 | `c_Spark_kD_2` | Derivative Gain |
| 32 | `c_Spark_kV_2` | Velocity FF (kV) |
| 33 | `c_Spark_kIZone_2` | I-Zone |
| 34 | `c_Spark_kDFilter_2` | D Filter |
| 35 | `c_Spark_kOutputMin_2` | Min Output |
| 36 | `c_Spark_kOutputMax_2` | Max Output |
| 104 | `c_Spark_kIMaxAccum_2` | Max I Accumulator |
| 105 | `c_Spark_kAllowedClosedLoopError_2` | Allowed CL Error |

### PID Slot 3

| ID | REVLib Constant | Name |
|----|----------------|------|
| 37 | `c_Spark_kP_3` | Proportional Gain |
| 38 | `c_Spark_kI_3` | Integral Gain |
| 39 | `c_Spark_kD_3` | Derivative Gain |
| 40 | `c_Spark_kV_3` | Velocity FF (kV) |
| 41 | `c_Spark_kIZone_3` | I-Zone |
| 42 | `c_Spark_kDFilter_3` | D Filter |
| 43 | `c_Spark_kOutputMin_3` | Min Output |
| 44 | `c_Spark_kOutputMax_3` | Max Output |
| 108 | `c_Spark_kIMaxAccum_3` | Max I Accumulator |
| 109 | `c_Spark_kAllowedClosedLoopError_3` | Allowed CL Error |

### Feedforward Slot 0 (firmware ≥ 25.0)

| ID | REVLib Constant | Name | Notes |
|----|----------------|------|-------|
| 16 | `c_Spark_kV_0` | kV — Velocity Gain | Shared with PID Slot 0 "F" param |
| 204 | `c_Spark_kS_0` | kS — Static Gain | Volts |
| 205 | `c_Spark_kA_0` | kA — Acceleration Gain | Volts per velocity per second |
| 206 | `c_Spark_kG_0` | kG — Static Gravity Gain | Volts (elevator/linear) |
| 207 | `c_Spark_kCos_0` | kCos — Cosine Gravity Gain | Volts (arm/rotary) |
| 208 | `c_Spark_kCosRatio_0` | kCosRatio | Converts encoder units → absolute rotations |

### Feedforward Slot 1

| ID | REVLib Constant | Name |
|----|----------------|------|
| 24 | `c_Spark_kV_1` | kV — Velocity Gain |
| 209 | `c_Spark_kS_1` | kS — Static Gain |
| 210 | `c_Spark_kA_1` | kA — Acceleration Gain |
| 211 | `c_Spark_kG_1` | kG — Static Gravity Gain |
| 212 | `c_Spark_kCos_1` | kCos — Cosine Gravity Gain |
| 213 | `c_Spark_kCosRatio_1` | kCosRatio |

### Feedforward Slot 2

| ID | REVLib Constant | Name |
|----|----------------|------|
| 32 | `c_Spark_kV_2` | kV — Velocity Gain |
| 214 | `c_Spark_kS_2` | kS — Static Gain |
| 215 | `c_Spark_kA_2` | kA — Acceleration Gain |
| 216 | `c_Spark_kG_2` | kG — Static Gravity Gain |
| 217 | `c_Spark_kCos_2` | kCos — Cosine Gravity Gain |
| 218 | `c_Spark_kCosRatio_2` | kCosRatio |

### Feedforward Slot 3

| ID | REVLib Constant | Name |
|----|----------------|------|
| 40 | `c_Spark_kV_3` | kV — Velocity Gain |
| 219 | `c_Spark_kS_3` | kS — Static Gain |
| 220 | `c_Spark_kA_3` | kA — Acceleration Gain |
| 221 | `c_Spark_kG_3` | kG — Static Gravity Gain |
| 222 | `c_Spark_kCos_3` | kCos — Cosine Gravity Gain |
| 223 | `c_Spark_kCosRatio_3` | kCosRatio |

### Limit Switches & Soft Limits

| ID | REVLib Constant | Name |
|----|----------------|------|
| 50 | `c_Spark_kLimitSwitchFwdPolarity` | Forward Limit Switch Polarity |
| 51 | `c_Spark_kLimitSwitchRevPolarity` | Reverse Limit Switch Polarity |
| 52 | `c_Spark_kHardLimitFwdEn` | Forward Hard Limit Enable |
| 53 | `c_Spark_kHardLimitRevEn` | Reverse Hard Limit Enable |
| 54 | `c_Spark_kSoftLimitFwdEn` | Forward Soft Limit Enable |
| 55 | `c_Spark_kSoftLimitRevEn` | Reverse Soft Limit Enable |
| 115 | `c_Spark_kSoftLimitForward` | Forward Soft Limit (rotations) |
| 116 | `c_Spark_kSoftLimitReverse` | Reverse Soft Limit (rotations) |
| 201 | `c_Spark_kLimitSwitchPositionSensor` | Limit Switch Position Sensor |
| 202 | `c_Spark_kLimitSwitchFwdPosition` | Forward Limit Switch Position |
| 203 | `c_Spark_kLimitSwitchRevPosition` | Reverse Limit Switch Position |

### Current Limits

| ID | REVLib Constant | Name |
|----|----------------|------|
| 59 | `c_Spark_kSmartCurrentStallLimit` | Smart Current Stall Limit |
| 60 | `c_Spark_kSmartCurrentFreeLimit` | Smart Current Free Limit |
| 61 | `c_Spark_kSmartCurrentConfig` | Smart Current Config (RPM) |
| 62 | `c_Spark_kSmartCurrentReserved` | Smart Current Reserved |

### Encoder Configuration

| ID | REVLib Constant | Name |
|----|----------------|------|
| 69 | `c_Spark_kEncoderCountsPerRev` | Encoder CPR |
| 70 | `c_Spark_kEncoderAverageDepth` | Encoder Average Depth |
| 71 | `c_Spark_kEncoderSampleDelta` | Encoder Sample Delta |
| 72 | `c_Spark_kEncoderInverted` | Encoder Inverted |
| 112 | `c_Spark_kPositionConversionFactor` | Position Conversion Factor |
| 113 | `c_Spark_kVelocityConversionFactor` | Velocity Conversion Factor |

### Alternate / Analog / Duty-Cycle Encoders

| ID | REVLib Constant | Name |
|----|----------------|------|
| 119 | `c_Spark_kAnalogPositionConversion` | Analog Position Conversion |
| 120 | `c_Spark_kAnalogVelocityConversion` | Analog Velocity Conversion |
| 121 | `c_Spark_kAnalogAverageDepth` | Analog Average Depth |
| 122 | `c_Spark_kAnalogSensorMode` | Analog Sensor Mode |
| 123 | `c_Spark_kAnalogInverted` | Analog Inverted |
| 124 | `c_Spark_kAnalogSampleDelta` | Analog Sample Delta |
| 127 | `c_Spark_kCompatibilityPortConfig` | Compatibility Port Config |
| 128 | `c_Spark_kAltEncoderCountsPerRev` | Alt Encoder CPR |
| 129 | `c_Spark_kAltEncoderAverageDepth` | Alt Encoder Average Depth |
| 130 | `c_Spark_kAltEncoderSampleDelta` | Alt Encoder Sample Delta |
| 131 | `c_Spark_kAltEncoderInverted` | Alt Encoder Inverted |
| 132 | `c_Spark_kAltEncoderPositionConversion` | Alt Encoder Position Factor |
| 133 | `c_Spark_kAltEncoderVelocityConversion` | Alt Encoder Velocity Factor |
| 136 | `c_Spark_kUvwSensorSampleRate` | UVW Sensor Sample Rate |
| 137 | `c_Spark_kUvwSensorAverageDepth` | UVW Sensor Average Depth |
| 139 | `c_Spark_kDutyCyclePositionFactor` | Duty Cycle Position Factor |
| 140 | `c_Spark_kDutyCycleVelocityFactor` | Duty Cycle Velocity Factor |
| 141 | `c_Spark_kDutyCycleInverted` | Duty Cycle Inverted |
| 142 | `c_Spark_kDutyCycleSensorMode` | Duty Cycle Sensor Mode |
| 143 | `c_Spark_kDutyCycleAverageDepth` | Duty Cycle Average Depth |
| 145 | `c_Spark_kDutyCycleOffsetLegacy` | Duty Cycle Offset (legacy) |
| 152 | `c_Spark_kDutyCycleZeroCentered` | Duty Cycle Zero Centered |
| 153 | `c_Spark_kDutyCycleSensorPrescaler` | Duty Cycle Prescaler |
| 154 | `c_Spark_kDutyCycleOffset` | Duty Cycle Offset |
| 196 | `c_Spark_kDutyCycleEncoderStartPulseUs` | Duty Cycle Start Pulse (µs) |
| 197 | `c_Spark_kDutyCycleEncoderEndPulseUs` | Duty Cycle End Pulse (µs) |
| 226 | `c_Spark_kDetachedEncoderDeviceID` | Detached Encoder Device ID |

### Position PID Wrapping

| ID | REVLib Constant | Name |
|----|----------------|------|
| 149 | `c_Spark_kPositionPIDWrapEnable` | Position PID Wrapping Enable |
| 150 | `c_Spark_kPositionPIDMinInput` | Position PID Min Input |
| 151 | `c_Spark_kPositionPIDMaxInput` | Position PID Max Input |

### Follower Mode

| ID | REVLib Constant | Name |
|----|----------------|------|
| 57 | `c_Spark_kLegacyFollowerID` | Legacy Follower ID |
| 58 | `c_Spark_kLegacyFollowerConfig` | Legacy Follower Config |
| 194 | `c_Spark_kFollowerModeLeaderId` | Follower Mode Leader ID |
| 195 | `c_Spark_kFollowerModeIsInverted` | Follower Mode Is Inverted |

### MAXMotion Slot 0

| ID | REVLib Constant | Name |
|----|----------------|------|
| 166 | `c_Spark_kMAXMotionCruiseVelocity_0` | Cruise Velocity |
| 167 | `c_Spark_kMAXMotionMaxAccel_0` | Max Acceleration |
| 168 | `c_Spark_kMAXMotionMaxJerk_0` | Max Jerk |
| 169 | `c_Spark_kMAXMotionAllowedProfileError_0` | Allowed Profile Error |
| 170 | `c_Spark_kMAXMotionPositionMode_0` | Position Mode |

### MAXMotion Slots 1–3

Slots 1–3 follow the same pattern with a +5 stride per slot:

| Slot | Cruise Vel | Max Accel | Max Jerk | Allowed Error | Pos Mode |
|------|-----------|-----------|----------|---------------|----------|
| 1 | 171 | 172 | 173 | 174 | 175 |
| 2 | 176 | 177 | 178 | 179 | 180 |
| 3 | 181 | 182 | 183 | 184 | 185 |

### Status Frame Periods

| ID | REVLib Constant | Name |
|----|----------------|------|
| 158 | `c_Spark_kStatus0Period` | Status 0 Period |
| 159 | `c_Spark_kStatus1Period` | Status 1 Period |
| 160 | `c_Spark_kStatus2Period` | Status 2 Period |
| 161 | `c_Spark_kStatus3Period` | Status 3 Period |
| 162 | `c_Spark_kStatus4Period` | Status 4 Period |
| 163 | `c_Spark_kStatus5Period` | Status 5 Period |
| 164 | `c_Spark_kStatus6Period` | Status 6 Period |
| 165 | `c_Spark_kStatus7Period` | Status 7 Period |
| 199 | `c_Spark_kStatus8Period` | Status 8 Period |
| 224 | `c_Spark_kStatus9Period` | Status 9 Period |

### Force Enable Status Frames

| ID | REVLib Constant | Name |
|----|----------------|------|
| 186–193 | `c_Spark_kForceEnableStatus_0` … `_7` | Force Enable Status 0–7 |
| 200 | `c_Spark_kForceEnableStatus_8` | Force Enable Status 8 |
| 225 | `c_Spark_kForceEnableStatus_9` | Force Enable Status 9 |

### Control Types

| Value | REVLib Constant | Name |
|-------|----------------|------|
| 0 | `c_Spark_kControlType_DUTY_CYCLE` | Duty Cycle |
| 1 | `c_Spark_kControlType_VELOCITY` | Velocity |
| 2 | `c_Spark_kControlType_VOLTAGE` | Voltage |
| 3 | `c_Spark_kControlType_POSITION` | Position |
| 4 | `c_Spark_kControlType_CURRENT` | Current |
| 5 | `c_Spark_kControlType_MAXMOTION_POSITION` | MAXMotion Position |
| 6 | `c_Spark_kControlType_MAXMOTION_VELOCITY` | MAXMotion Velocity |
