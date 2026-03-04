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
