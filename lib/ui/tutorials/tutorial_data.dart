/// Tutorial content definitions for all 25 topics.
///
/// Each topic is a [TutorialTopic] with categorized, step-by-step
/// explanations aimed at FRC students new to motor control.
library;

import 'package:fluent_ui/fluent_ui.dart';

import 'diagrams/can_wiring_diagram.dart';
import 'diagrams/constant_plot_animator.dart';
import 'diagrams/motor_encoder_diagram.dart';
import 'diagrams/pid_response_diagram.dart';
import 'diagrams/power_distribution_diagram.dart';
import 'tutorial_keys.dart';
import 'tutorial_models.dart';

/// Master list of all tutorial topics.
final List<TutorialTopic> allTutorials = [
  // =========================================================================
  // Hardware Topics
  // =========================================================================

  TutorialTopic(
    id: 'hw_motor_encoder',
    title: 'Motor & Encoder Assembly',
    category: TutorialCategory.hardware,
    steps: [
      TutorialStep(
        title: 'The NEO Motor',
        description:
            'The REV NEO is a brushless DC motor used in FRC robots. '
            'It has three phase wires (not the usual two of a brushed motor) '
            'and a built-in Hall-effect encoder that reports position and velocity.\n\n'
            'Brushless motors are more efficient and longer-lasting than brushed '
            'motors, but they require a motor controller (like a SPARK) to '
            'commutate the phases electronically.',
        icon: FluentIcons.settings,
        customContent: (_) => const MotorEncoderDiagram(),
      ),
      const TutorialStep(
        title: 'The Built-In Encoder',
        description:
            'The NEO\'s Hall-effect encoder generates 42 counts per revolution. '
            'The SPARK controller reads these counts and converts them to:\n\n'
            '• Position (in rotations)\n'
            '• Velocity (in RPM)\n\n'
            'You can also attach an external absolute encoder (like the REV '
            'Through Bore Encoder) for applications that need to know exact '
            'position on power-up, such as swerve drive steering.',
        icon: FluentIcons.compass_n_w,
      ),
      const TutorialStep(
        title: 'Mounting the Motor',
        description:
            'When mounting the NEO motor to your mechanism:\n\n'
            '1. Secure the motor with the provided mounting bolts\n'
            '2. Ensure the output shaft spins freely before tightening\n'
            '3. Connect the motor phase wires to the SPARK in the correct order\n'
            '4. If the motor spins the wrong direction, you can swap any two '
            'phase wires OR invert the motor in software\n\n'
            'Tip: It\'s easier to fix direction in software than to re-wire. '
            'This tool has a "Motor Inverted" setting on the Device Parameters screen.',
        icon: FluentIcons.construction_cone,
      ),
    ],
  ),

  TutorialTopic(
    id: 'hw_spark_wiring',
    title: 'SPARK Controller Wiring',
    category: TutorialCategory.hardware,
    steps: [
      const TutorialStep(
        title: 'Power Connections',
        description:
            'The SPARK MAX/Flex needs 12V power from your robot\'s power '
            'distribution board (PDB or PDH):\n\n'
            '• Red wire → 12V (through a 40A breaker slot)\n'
            '• Black wire → Ground\n\n'
            'IMPORTANT: Always use properly sized wire (12 AWG for 40A '
            'breakers). Loose connections cause voltage drops that make '
            'system identification results inaccurate.',
        icon: FluentIcons.lightning_bolt,
      ),
      const TutorialStep(
        title: 'CAN Bus Wiring',
        description:
            'CAN (Controller Area Network) is a two-wire communication bus:\n\n'
            '• CAN High (Yellow) — carries the signal\n'
            '• CAN Low (Green) — carries the inverted signal\n\n'
            'Devices are daisy-chained: the CAN H/L from one device connects '
            'to the CAN H/L of the next. The last device in the chain should '
            'have a 120Ω termination resistor.\n\n'
            'For this tool, USB connection is used instead of CAN for direct '
            'computer-to-SPARK communication.',
        icon: FluentIcons.plug_connected,
      ),
      const TutorialStep(
        title: 'Motor Phase Wires',
        description:
            'The NEO motor connects to the SPARK via three phase wires '
            '(A, B, C). The SPARK electronically commutates these phases '
            'to spin the motor.\n\n'
            'If the motor spins in the wrong direction:\n'
            '• Option 1: Swap any two of the three phase wires\n'
            '• Option 2: Set "Motor Inverted" in software (recommended)\n\n'
            'The encoder data cable also plugs into the SPARK\'s encoder port.',
        icon: FluentIcons.plug_connected,
      ),
      const TutorialStep(
        title: 'USB Connection',
        description:
            'For system identification, connect your computer directly to '
            'the SPARK via USB-C:\n\n'
            '• Use a data-capable USB-C cable (not a charge-only cable)\n'
            '• The SPARK will appear as a serial port (COM port on Windows)\n'
            '• Only one SPARK can be connected via USB at a time\n\n'
            'The USB connection provides both communication and enough power '
            'for the SPARK\'s processor — but NOT enough to drive the motor. '
            'You still need 12V power for motor operation.',
        icon: FluentIcons.usb,
      ),
    ],
  ),

  TutorialTopic(
    id: 'hw_power_distribution',
    title: 'Breadboard & Power Distribution',
    category: TutorialCategory.hardware,
    steps: [
      const TutorialStep(
        title: 'Power Distribution Board',
        description:
            'The PDB (Power Distribution Board) or PDH (Power Distribution Hub) '
            'distributes 12V from your battery to all devices:\n\n'
            '• Each motor controller gets its own breaker slot\n'
            '• Breaker size depends on the motor: 40A for NEO/NEO 550\n'
            '• The main breaker protects the entire system\n\n'
            'For bench testing with this tool, you can use a 12V power supply '
            'instead of a battery, connected through the PDB.',
        icon: FluentIcons.lightning_bolt,
      ),
      const TutorialStep(
        title: 'Bench Test Setup',
        description:
            'For system identification on a workbench, you need:\n\n'
            '1. 12V power supply (or charged battery) → PDB\n'
            '2. PDB → SPARK (through breaker)\n'
            '3. SPARK → Motor (phase wires + encoder cable)\n'
            '4. USB-C cable from SPARK → your computer\n'
            '5. E-stop switch (recommended for safety)\n\n'
            'Mount the motor securely to the bench so it doesn\'t walk '
            'during dynamic tests.',
        icon: FluentIcons.construction_cone,
      ),
    ],
  ),

  TutorialTopic(
    id: 'hw_usb',
    title: 'USB Connection',
    category: TutorialCategory.hardware,
    requiredScreenIndex: 1, // Device Setup screen
    steps: [
      TutorialStep(
        title: 'Connecting via USB',
        description:
            'Plug a USB-C data cable from your computer to the SPARK\'s '
            'USB-C port. Then:\n\n'
            '1. Click the port dropdown to see available serial ports\n'
            '2. Select the SPARK\'s COM port\n'
            '3. Click "Connect"\n\n'
            'If you don\'t see a COM port, check that:\n'
            '• You\'re using a data-capable USB-C cable\n'
            '• The SPARK has power (status LED should be on)\n'
            '• USB drivers are installed',
        icon: FluentIcons.usb,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.devicePortDropdown),
          HighlightTarget(globalKey: TutorialKeys.deviceConnectButton),
        ],
      ),
      const TutorialStep(
        title: 'Simulated Device',
        description:
            'Don\'t have hardware? No problem! Select one of the simulated '
            'devices from the port dropdown:\n\n'
            '• 🧠 Simulated Flywheel\n'
            '• 🧠 Simulated Arm\n'
            '• 🧠 Simulated Elevator\n\n'
            'These use a physics simulation with known constants, so you can '
            'practice the full workflow and verify the tool recovers the '
            'correct kS, kV, kA, and kG values.',
        icon: FluentIcons.game,
      ),
    ],
  ),

  TutorialTopic(
    id: 'hw_estop',
    title: 'E-Stop & Mechanism Limits',
    category: TutorialCategory.hardware,
    steps: [
      const TutorialStep(
        title: 'Emergency Stop',
        description:
            'Always have a way to cut power to the motor quickly:\n\n'
            '• Use a physical e-stop switch in the power circuit\n'
            '• Keep the SPARK\'s USB connected so software stop works\n'
            '• Know the keyboard shortcut: click the Stop button or '
            'disconnect the device\n\n'
            'IMPORTANT: During dynamic tests, the motor will spin up '
            'quickly. Make sure your mechanism is safe to operate.',
        icon: FluentIcons.warning,
      ),
      const TutorialStep(
        title: 'Soft Limits',
        description:
            'Soft limits prevent the motor from driving past safe positions '
            '(set in software, not hardware):\n\n'
            '• Forward Soft Limit: maximum position the motor can reach\n'
            '• Reverse Soft Limit: minimum position the motor can reach\n\n'
            'Soft limits are essential for arms and elevators where '
            'over-travel could damage the mechanism. Flywheels don\'t '
            'need soft limits since they spin continuously.\n\n'
            'Configure these on the Configuration screen before running tests.',
        icon: FluentIcons.pinned,
      ),
    ],
  ),

  // =========================================================================
  // Software Topics
  // =========================================================================

  TutorialTopic(
    id: 'sw_connection_flow',
    title: 'Device Connection Flow',
    category: TutorialCategory.software,
    requiredScreenIndex: 1, // Device Setup screen
    steps: [
      TutorialStep(
        title: 'Select a Port',
        description:
            'The Device Setup screen shows all available serial ports. '
            'Your SPARK will appear as a COM port (Windows) or /dev/tty* '
            '(macOS/Linux).\n\n'
            'Click the port dropdown and select your SPARK\'s port. '
            'If you\'re not sure which port it is, unplug the USB cable, '
            'note which ports are listed, plug it back in, and look for '
            'the new one.',
        icon: FluentIcons.plug_connected,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.devicePortDropdown),
        ],
      ),
      TutorialStep(
        title: 'Connect to Device',
        description:
            'Click "Connect" to establish communication with the SPARK.\n\n'
            'Once connected, the tool will:\n'
            '1. Read the SPARK\'s CAN ID\n'
            '2. Start a heartbeat to keep the device active\n'
            '3. Enable status frame reporting for telemetry\n\n'
            'If the connection fails, check your USB cable and ensure the '
            'SPARK has 12V power.',
        icon: FluentIcons.plug_connected,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.deviceConnectButton),
        ],
      ),
      TutorialStep(
        title: 'CAN ID',
        description:
            'Each SPARK on a CAN bus has a unique ID (0–62). The default '
            'is 0.\n\n'
            'For this tool, the CAN ID is read automatically from the '
            'connected device. If you need to change it, use the CAN ID '
            'field on this screen.\n\n'
            'Note: When using USB, only one SPARK is connected at a time, '
            'but for robot use, each SPARK needs a unique CAN ID.',
        icon: FluentIcons.number_field,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.deviceCanIdField),
        ],
      ),
    ],
  ),

  TutorialTopic(
    id: 'sw_mechanism_type',
    title: 'Mechanism Type Selection',
    category: TutorialCategory.software,
    requiredScreenIndex: 3, // Config screen
    steps: [
      TutorialStep(
        title: 'Choosing Your Mechanism Type',
        description:
            'This tool supports four mechanism types, each with different '
            'physics models:\n\n'
            '• Flywheel — Pure rotation (shooter wheels, intake rollers)\n'
            '  No gravity. Simplest model: V = kS + kV·ω + kA·α\n\n'
            '• Arm — Pivoting mechanism (arms, wrists)\n'
            '  Gravity depends on angle: V = kS + kV·ω + kA·α + kG·cos(θ)\n\n'
            '• Elevator — Linear vertical motion (elevators, lifts)\n'
            '  Constant gravity: V = kS + kV·v + kA·a + kG\n\n'
            '• Simple — General mechanism (drivetrains, horizontal slides)\n'
            '  No gravity, supports both position and velocity control',
        icon: FluentIcons.settings,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.mechanismTypeSelector),
        ],
      ),
      const TutorialStep(
        title: 'Why Does It Matter?',
        description:
            'The mechanism type determines:\n\n'
            '1. Which feedforward constants are computed\n'
            '   (kG is only relevant for arms and elevators)\n\n'
            '2. How the test runner handles gravity compensation\n\n'
            '3. What units are used\n'
            '   (arm = degrees, elevator = meters, flywheel = rotations)\n\n'
            '4. Whether soft limits are required\n'
            '   (arms and elevators need them, flywheels don\'t)\n\n'
            'Choose the type that best matches your physical mechanism. '
            'If unsure, start with "Simple" and change later if needed.',
        icon: FluentIcons.info,
      ),
    ],
  ),

  TutorialTopic(
    id: 'sw_encoder_config',
    title: 'Encoder Configuration',
    category: TutorialCategory.software,
    requiredScreenIndex: 3, // Config screen
    steps: [
      TutorialStep(
        title: 'Feedback Sensor Selection',
        description:
            'The SPARK supports two feedback sources:\n\n'
            '• Primary Encoder — The NEO\'s built-in Hall sensor\n'
            '  Good for most applications. Measures relative position '
            '(resets to 0 on power-up).\n\n'
            '• Absolute Encoder — REV Through Bore Encoder\n'
            '  Reports true absolute position (0–1 rotation range). '
            'Useful for swerve steering, arm angles, or anything that '
            'needs to know its position immediately on boot.',
        icon: FluentIcons.compass_n_w,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.encoderConfigSection),
        ],
      ),
      TutorialStep(
        title: 'Conversion Factors',
        description:
            'Conversion factors translate from motor rotations to your '
            'mechanism\'s native units:\n\n'
            '• Position conversion: multiplied by motor rotations → '
            'mechanism position\n'
            '  Example: 1:10 gear ratio means 0.1 rotations per motor rotation\n\n'
            '• Velocity conversion: multiplied by motor RPM → '
            'mechanism velocity\n\n'
            'For a 1:1 direct drive, both factors are 1.0.\n\n'
            'Getting this right is critical — wrong conversion factors '
            'will produce incorrect feedforward gains.',
        icon: FluentIcons.calculator,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.conversionFactorField),
        ],
      ),
      const TutorialStep(
        title: 'Zeroing the Encoder',
        description:
            'Before running tests, make sure the encoder reads the correct '
            'position:\n\n'
            '1. Move your mechanism to a known reference position\n'
            '   (e.g., arm at horizontal, elevator at bottom)\n'
            '2. Use the "Zero Encoder" button to set current position = 0\n'
            '3. Verify by jogging the mechanism and checking the position '
            'readout matches reality\n\n'
            'For absolute encoders, the zero point is set by the magnet '
            'alignment and doesn\'t need software zeroing.',
        icon: FluentIcons.reset,
      ),
    ],
  ),

  TutorialTopic(
    id: 'sw_soft_limits',
    title: 'Soft Limits Setup',
    category: TutorialCategory.software,
    requiredScreenIndex: 3, // Config screen
    steps: [
      TutorialStep(
        title: 'Setting Soft Limits',
        description:
            'Soft limits are software-enforced position boundaries that '
            'prevent the motor from driving past safe positions.\n\n'
            'To set them:\n'
            '1. Use jog controls to move the mechanism to its forward limit\n'
            '2. Note the position value → enter as Forward Soft Limit\n'
            '3. Jog to the reverse limit\n'
            '4. Note the position → enter as Reverse Soft Limit\n\n'
            'The test runner will automatically stop tests if a soft limit '
            'is reached, protecting your mechanism.',
        icon: FluentIcons.pinned,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.softLimitsSection),
        ],
      ),
      const TutorialStep(
        title: 'When Soft Limits Are Needed',
        description:
            'Required for:\n'
            '• Arms — prevent over-rotation that could hit the frame\n'
            '• Elevators — prevent slamming into top/bottom hard stops\n\n'
            'Not needed for:\n'
            '• Flywheels — they spin continuously\n'
            '• Simple mechanisms that are safe to move freely\n\n'
            'Tip: Leave some margin between your soft limits and the '
            'physical hard stops. If the motor is still decelerating when '
            'the soft limit triggers, it won\'t damage anything.',
        icon: FluentIcons.shield,
      ),
    ],
  ),

  TutorialTopic(
    id: 'sw_motor_id',
    title: 'Motor ID & Direction',
    category: TutorialCategory.software,
    requiredScreenIndex: 2, // Device Parameters screen
    steps: [
      TutorialStep(
        title: 'Motor Type & Direction',
        description:
            'The SPARK needs to know:\n\n'
            '• Motor type: Brushless (NEO/NEO 550) or Brushed (CIM, etc.)\n'
            '  Wrong motor type = motor won\'t spin or could be damaged\n\n'
            '• Motor inverted: Reverses the positive direction\n'
            '  Use this if your motor spins backward from what you expect\n\n'
            'These settings are read from the SPARK when you connect. '
            'Change them here if needed.',
        icon: FluentIcons.settings,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.motorTypeSelector),
          HighlightTarget(globalKey: TutorialKeys.motorInversionToggle),
        ],
      ),
      TutorialStep(
        title: 'Current Limit',
        description:
            'The smart current limit protects your motor and mechanism:\n\n'
            '• Default: 40A for NEO, 20A for NEO 550\n'
            '• Lower values reduce heat but limit torque\n'
            '• Higher values allow more torque but risk overheating\n\n'
            'During system identification, the current limit acts as a '
            'safety net — the test will stop if current exceeds this value '
            'for too long, indicating a stall condition.',
        icon: FluentIcons.lightning_bolt,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.currentLimitField),
        ],
      ),
    ],
  ),

  // =========================================================================
  // Electrical Topics
  // =========================================================================

  TutorialTopic(
    id: 'elec_power',
    title: 'Power & Ground Distribution',
    category: TutorialCategory.electrical,
    steps: [
      TutorialStep(
        title: 'The Power Circuit',
        description:
            'The complete power path in an FRC robot:\n\n'
            'Battery (12V) → Main Breaker → PDB/PDH → Breaker Slot → SPARK → Motor\n\n'
            'Each connection must be solid. Loose connections cause:\n'
            '• Voltage drops under load (bad for system ID accuracy)\n'
            '• Intermittent faults that corrupt test data\n'
            '• Potential fire hazard from overheating connections\n\n'
            'Use properly crimped connectors (Anderson PowerPoles, Weidmüller, '
            'or WAGO) — never twist-and-tape for power wires.',
        icon: FluentIcons.lightning_bolt,
        customContent: (_) => const PowerDistributionDiagram(),
      ),
      const TutorialStep(
        title: 'Ground Path',
        description:
            'Ground is just as important as the positive rail:\n\n'
            '• All ground wires must return to the PDB/PDH ground bus\n'
            '• Ground wire gauge must match the positive wire gauge\n'
            '• The battery negative terminal is the system ground reference\n\n'
            'Common mistake: A bad ground connection can cause the SPARK\'s '
            'voltage readings to be offset, which directly affects the '
            'computed kS and kV values.',
        icon: FluentIcons.globe,
      ),
      const TutorialStep(
        title: 'Voltage Under Load',
        description:
            'When the motor draws current, the battery voltage drops. '
            'This is normal! A fully charged FRC battery:\n\n'
            '• No load: ~12.8V\n'
            '• Light load: ~12.0V\n'
            '• Heavy load: ~10.5V or lower\n\n'
            'The SPARK measures actual bus voltage and reports it in status '
            'frames. This tool uses the measured voltage (not a fixed 12V) '
            'for more accurate system identification.',
        icon: FluentIcons.chart,
      ),
    ],
  ),

  TutorialTopic(
    id: 'elec_can',
    title: 'CAN Networking',
    category: TutorialCategory.electrical,
    steps: [
      const TutorialStep(
        title: 'CAN Bus Basics',
        description:
            'CAN (Controller Area Network) is a two-wire bus used in FRC:\n\n'
            '• CAN High (Yellow) and CAN Low (Green)\n'
            '• Differential signaling: noise immunity in electrically noisy environments\n'
            '• All devices share the same two wires (bus topology)\n'
            '• Each device has a unique CAN ID (0–62 for SPARK)\n\n'
            'Speed: 1 Mbps — fast enough for real-time motor control.',
        icon: FluentIcons.org,
      ),
      TutorialStep(
        title: 'Daisy-Chain Wiring',
        description:
            'FRC devices are wired in a daisy-chain:\n\n'
            'roboRIO → SPARK #1 → SPARK #2 → ... → SPARK #N\n\n'
            'Each device has CAN input and output ports. Connect:\n'
            '• Previous device\'s CAN OUT → next device\'s CAN IN\n'
            '• Use twisted pair wire to reduce noise\n'
            '• Keep total bus length under 5 meters for reliability\n\n'
            'For system identification via USB, CAN wiring is not required '
            '— USB provides a direct point-to-point connection.',
        icon: FluentIcons.plug_connected,
        customContent: (_) => const CanWiringDiagram(),
      ),
      const TutorialStep(
        title: 'Termination',
        description:
            'A CAN bus needs 120Ω termination resistors at each end to '
            'prevent signal reflections:\n\n'
            '• The roboRIO has a built-in termination resistor\n'
            '• The PDP/PDH also has one\n'
            '• If these are your first and last devices, you\'re set\n\n'
            'If you have communication issues, check that you have exactly '
            'two termination resistors on the bus (one at each end).',
        icon: FluentIcons.repair,
      ),
    ],
  ),

  TutorialTopic(
    id: 'elec_signal_path',
    title: 'Signal Path',
    category: TutorialCategory.electrical,
    steps: [
      const TutorialStep(
        title: 'From Encoder to Screen',
        description:
            'The data flow for system identification:\n\n'
            '1. Motor encoder detects rotation → generates Hall pulses\n'
            '2. SPARK processor counts pulses → computes position & velocity\n'
            '3. SPARK packages data into CAN-format status frames\n'
            '4. Status frames sent over USB serial at 115200 baud\n'
            '5. This tool receives frames → parses velocity, position, current\n'
            '6. Data is plotted in real-time and stored for analysis\n\n'
            'This entire loop runs at ~100 Hz (10 ms per sample), giving '
            'high-quality data for regression analysis.',
        icon: FluentIcons.flow,
      ),
      const TutorialStep(
        title: 'Command Path',
        description:
            'When this tool commands the motor:\n\n'
            '1. Tool constructs a voltage command (e.g., 3.5V)\n'
            '2. Command is encoded as a CAN control frame\n'
            '3. Frame is sent over USB to the SPARK\n'
            '4. SPARK applies the voltage to the motor phases\n'
            '5. A heartbeat frame must be sent every 100ms to keep the '
            'motor enabled (safety feature)\n\n'
            'If the heartbeat is lost, the motor immediately stops — '
            'this is by design for safety.',
        icon: FluentIcons.send,
      ),
    ],
  ),

  // =========================================================================
  // Testing Workflow Topics
  // =========================================================================

  TutorialTopic(
    id: 'test_quasistatic',
    title: 'Quasistatic Test Explained',
    category: TutorialCategory.testing,
    requiredScreenIndex: 4, // Test screen
    steps: [
      const TutorialStep(
        title: 'What is a Quasistatic Test?',
        description:
            'A quasistatic test applies a very slowly increasing voltage '
            'to the motor. "Quasistatic" means "almost static" — the motor '
            'accelerates so slowly that at each moment it\'s nearly at '
            'steady state.\n\n'
            'This means acceleration ≈ 0, so the voltage equation simplifies:\n\n'
            'V = kS·sign(ω) + kV·ω  (+ kG for arms/elevators)\n\n'
            'By plotting voltage vs. velocity, we can directly read off:\n'
            '• kS = the Y-intercept (voltage needed to start moving)\n'
            '• kV = the slope (voltage per unit velocity)',
        icon: FluentIcons.timer,
      ),
      const TutorialStep(
        title: 'The Voltage Ramp',
        description:
            'During a quasistatic test:\n\n'
            '1. Voltage starts at 0V\n'
            '2. Increases by the ramp rate each second (default: 0.25 V/s)\n'
            '3. Motor slowly speeds up as voltage overcomes friction\n'
            '4. Test ends after the set duration (default: 4 seconds)\n\n'
            'The slow ramp rate is critical — if it\'s too fast, the '
            'motor has significant acceleration and the data includes '
            'kA effects, corrupting the kS/kV estimates.\n\n'
            'A forward QS test ramps positive, a reverse QS test ramps negative.',
        icon: FluentIcons.up,
      ),
      const TutorialStep(
        title: 'Reading QS Results',
        description:
            'After a quasistatic test, look at the voltage vs. velocity plot:\n\n'
            '• The data should form a roughly straight line\n'
            '• The line\'s Y-intercept ≈ kS (static friction voltage)\n'
            '• The line\'s slope ≈ kV (voltage per unit velocity)\n\n'
            'Signs of a good QS test:\n'
            '→ Clean linear data with minimal scatter\n'
            '→ R² close to 1.0\n\n'
            'Signs of a bad QS test:\n'
            '→ Curved data (ramp rate too fast)\n'
            '→ Very noisy data (loose connections or encoder issues)',
        icon: FluentIcons.chart,
      ),
    ],
  ),

  TutorialTopic(
    id: 'test_dynamic',
    title: 'Dynamic Test Explained',
    category: TutorialCategory.testing,
    requiredScreenIndex: 4, // Test screen
    steps: [
      const TutorialStep(
        title: 'What is a Dynamic Test?',
        description:
            'A dynamic test applies a sudden step voltage to the motor, '
            'causing rapid acceleration. This is how we measure kA — '
            'the voltage needed per unit of acceleration.\n\n'
            'The full voltage equation:\n'
            'V = kS·sign(ω) + kV·ω + kA·α  (+ kG for arms/elevators)\n\n'
            'Since we already know kS and kV (from the quasistatic test), '
            'we can isolate kA by subtracting the known terms from the '
            'measured voltage and fitting the residual against acceleration.',
        icon: FluentIcons.lightning_bolt,
      ),
      const TutorialStep(
        title: 'The Step Response',
        description:
            'During a dynamic test:\n\n'
            '1. A constant voltage is applied instantly (default: 7V)\n'
            '2. The motor accelerates rapidly from rest\n'
            '3. Velocity increases until drag and friction balance the voltage\n'
            '4. Test ends after set duration (default: 2 seconds)\n\n'
            'We measure the acceleration (rate of velocity change) and compute:\n'
            'kA = (V - kS·sign(ω) - kV·ω) / α\n\n'
            'Higher kA means more inertia — the mechanism is harder to '
            'accelerate.',
        icon: FluentIcons.rocket,
      ),
    ],
  ),

  TutorialTopic(
    id: 'test_first_test',
    title: 'Running Your First Test',
    category: TutorialCategory.testing,
    requiredScreenIndex: 4, // Test screen
    steps: [
      const TutorialStep(
        title: 'Pre-Test Checklist',
        description:
            'Before you run your first test, verify:\n\n'
            '✓ Device is connected (green indicator on Device Setup)\n'
            '✓ Mechanism type is set correctly (Configuration screen)\n'
            '✓ Conversion factors are correct (if using gears)\n'
            '✓ Soft limits are configured (for arms and elevators)\n'
            '✓ Motor spins freely (no obstructions)\n'
            '✓ The area around the mechanism is clear\n'
            '✓ You have a way to emergency stop (e-stop or disconnect)\n\n'
            'For your first time, consider using a simulated device '
            'to learn the workflow risk-free.',
        icon: FluentIcons.check_mark,
      ),
      TutorialStep(
        title: 'Running the Tests',
        description:
            'A complete system identification requires four tests:\n\n'
            '1. Quasistatic Forward — slow ramp, positive direction\n'
            '2. Quasistatic Reverse — slow ramp, negative direction\n'
            '3. Dynamic Forward — step voltage, positive direction\n'
            '4. Dynamic Reverse — step voltage, negative direction\n\n'
            'Select each test type and click "Start Test". The motor will '
            'move, data will be collected, and a chart will show real-time '
            'telemetry.\n\n'
            'Wait for each test to complete before starting the next one.',
        icon: FluentIcons.play,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.testTypeSelector),
          HighlightTarget(globalKey: TutorialKeys.startTestButton),
        ],
      ),
      const TutorialStep(
        title: 'After the Tests',
        description:
            'Once all four tests are complete:\n\n'
            '1. Navigate to the Results screen\n'
            '2. Click "Compute" to run the regression analysis\n'
            '3. Review the computed feedforward gains (kS, kV, kA, kG)\n'
            '4. Check the R² value — ideally > 0.98\n\n'
            'If results look wrong:\n'
            '• R² < 0.90 → check for mechanical issues or wrong config\n'
            '• kS is negative → motor direction may be inverted\n'
            '• kV is very large → conversion factors may be wrong',
        icon: FluentIcons.chart,
      ),
    ],
  ),

  TutorialTopic(
    id: 'test_data',
    title: 'Understanding Test Data',
    category: TutorialCategory.testing,
    requiredScreenIndex: 5, // Results screen
    steps: [
      TutorialStep(
        title: 'The Data Plots',
        description:
            'The Results screen shows several diagnostic plots:\n\n'
            '• Voltage vs. Velocity — shows the linear relationship used to '
            'compute kS and kV. Points should cluster along a straight line.\n\n'
            '• Voltage vs. Time — shows what the test actually looked like. '
            'QS tests show a ramp, dynamic tests show a step.\n\n'
            '• Velocity vs. Time — shows the motor\'s speed response. '
            'QS should be a smooth curve, dynamic should show rapid rise.',
        icon: FluentIcons.chart,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.feedforwardGainsCard),
        ],
      ),
      TutorialStep(
        title: 'R² and Fit Quality',
        description:
            'R² (R-squared) measures how well the model fits the data:\n\n'
            '• R² = 1.0 → perfect fit (all data on the regression line)\n'
            '• R² = 0.99 → excellent fit (typical for simulated data)\n'
            '• R² = 0.95–0.99 → good fit (typical for real hardware)\n'
            '• R² < 0.90 → poor fit (check for issues)\n\n'
            'Low R² possible causes:\n'
            '→ Mechanical binding or inconsistent friction\n'
            '→ Wrong mechanism type selected\n'
            '→ Incorrect conversion factors\n'
            '→ Electrical noise or loose connections',
        icon: FluentIcons.diagnostic,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.rSquaredIndicator),
        ],
      ),
    ],
  ),

  // =========================================================================
  // Constants Deep Dive Topics
  // =========================================================================

  TutorialTopic(
    id: 'const_ks',
    title: 'kS — Static Friction',
    category: TutorialCategory.constants,
    steps: [
      TutorialStep(
        title: 'What is kS?',
        description:
            'kS (static friction voltage) is the minimum voltage required '
            'to overcome static friction and start the mechanism moving.\n\n'
            'Think of it like pushing a heavy box on a floor — you have to '
            'push hard enough to "break it free" before it starts sliding. '
            'Once moving, it takes less force to keep it going.\n\n'
            'Units: Volts\n'
            'Typical values: 0.1–0.5V for smooth mechanisms, 0.5–2.0V for '
            'mechanisms with significant friction.',
        icon: FluentIcons.lightning_bolt,
        customContent: (_) => const ConstantPlotAnimator(type: ConstantType.kS),
      ),
      const TutorialStep(
        title: 'Why kS Matters',
        description:
            'kS is crucial for accurate feedforward control:\n\n'
            'Without kS compensation, your motor controller has to "waste" '
            'voltage overcoming friction before any motion happens. This '
            'creates a dead zone in your control.\n\n'
            'In the feedforward equation:\n'
            'V = kS·sign(ω) + kV·ω + kA·α\n\n'
            '• sign(ω) = +1 when moving forward, -1 when moving backward\n'
            '• This ensures kS is always applied in the direction of motion\n\n'
            'Good kS compensation eliminates the "sticking" feeling when '
            'starting from rest.',
        icon: FluentIcons.info,
      ),
    ],
  ),

  TutorialTopic(
    id: 'const_kv',
    title: 'kV — Velocity Gain',
    category: TutorialCategory.constants,
    steps: [
      TutorialStep(
        title: 'What is kV?',
        description:
            'kV (velocity gain) is the voltage required per unit of velocity '
            'at steady state.\n\n'
            'It represents the back-EMF (electromotive force) of the motor: '
            'as the motor spins faster, it generates a voltage that opposes '
            'the applied voltage. To maintain a constant speed, you must '
            'apply enough voltage to overcome this back-EMF.\n\n'
            'Units: V·s/unit (e.g., V·s/rotation for flywheels)\n'
            'The relationship is linear: V_backEMF = kV · ω',
        icon: FluentIcons.speed_high,
        customContent: (_) => const ConstantPlotAnimator(type: ConstantType.kV),
      ),
      const TutorialStep(
        title: 'kV and Motor Speed',
        description:
            'kV directly determines the motor\'s maximum speed:\n\n'
            '• Maximum velocity = (V_battery - kS) / kV\n'
            '  At 12V with kS=0.2V and kV=0.02 V·s/RPM:\n'
            '  Max speed = (12 - 0.2) / 0.02 = 590 RPM\n\n'
            'Lower kV means:\n'
            '→ Higher top speed\n'
            '→ Usually a lighter/less-geared mechanism\n\n'
            'Higher kV means:\n'
            '→ Lower top speed\n'
            '→ Usually a heavier/more-geared mechanism\n'
            '→ More voltage needed to maintain speed',
        icon: FluentIcons.chart,
      ),
    ],
  ),

  TutorialTopic(
    id: 'const_ka',
    title: 'kA — Acceleration Gain',
    category: TutorialCategory.constants,
    steps: [
      TutorialStep(
        title: 'What is kA?',
        description:
            'kA (acceleration gain) is the voltage required per unit of '
            'acceleration. It represents the mechanism\'s inertia — how '
            'hard it is to change the motor\'s speed.\n\n'
            'Think of it like the mass of a car: a heavy car needs more '
            'force (voltage) to accelerate at the same rate as a light car.\n\n'
            'Units: V·s²/unit\n'
            'The relationship: V_accel = kA · α (where α = acceleration)\n\n'
            'kA is identified from the dynamic (step) test, where '
            'acceleration is significant.',
        icon: FluentIcons.rocket,
        customContent: (_) => const ConstantPlotAnimator(type: ConstantType.kA),
      ),
      const TutorialStep(
        title: 'kA and System Response',
        description:
            'kA affects how quickly your mechanism can respond to commands:\n\n'
            '• Small kA (low inertia):\n'
            '  → Fast acceleration\n'
            '  → More responsive to control\n'
            '  → PID gains can be more aggressive\n\n'
            '• Large kA (high inertia):\n'
            '  → Slow acceleration\n'
            '  → Sluggish response\n'
            '  → PID gains must be conservative (lower kP)\n\n'
            'kA also determines the plant time constant:\n'
            'τ = kA / kV (seconds)\n\n'
            'This time constant sets a natural limit on how fast your '
            'PID loop can be tuned.',
        icon: FluentIcons.info,
      ),
    ],
  ),

  TutorialTopic(
    id: 'const_kg',
    title: 'kG — Gravity Compensation',
    category: TutorialCategory.constants,
    steps: [
      const TutorialStep(
        title: 'What is kG?',
        description:
            'kG (gravity compensation voltage) is the voltage needed to '
            'hold a mechanism stationary against gravity.\n\n'
            'This constant only applies to mechanisms affected by gravity:\n\n'
            '• Arms: kG varies with angle — kG·cos(θ)\n'
            '  At horizontal (θ=0°): full kG voltage needed\n'
            '  At vertical (θ=90°): no gravity compensation needed\n\n'
            '• Elevators: kG is constant regardless of height\n'
            '  The carriage weighs the same at any height\n\n'
            '• Flywheels/Simple: kG = 0 (no gravity effect)',
        icon: FluentIcons.globe2,
      ),
      TutorialStep(
        title: 'Gravity for Arms',
        description:
            'For an arm mechanism, gravity torque depends on the angle:\n\n'
            'V_gravity = kG · cos(θ)\n\n'
            'Where θ is measured from horizontal:\n'
            '• θ = 0° (horizontal): cos(0°) = 1.0 → full kG needed\n'
            '• θ = 45°: cos(45°) ≈ 0.71 → 71% of kG needed\n'
            '• θ = 90° (vertical up): cos(90°) = 0 → no gravity compensation\n\n'
            'This is why arms are harder to identify than flywheels — the '
            'gravity term varies throughout the test range.',
        icon: FluentIcons.globe2,
        customContent: (_) => const ConstantPlotAnimator(type: ConstantType.kG),
      ),
      const TutorialStep(
        title: 'Why kG Matters for Control',
        description:
            'Without kG compensation:\n\n'
            '• Your arm will droop when holding a position\n'
            '• Your elevator will slowly sink under its own weight\n'
            '• The PID controller has to work extra hard, causing steady-state '
            'error or integral windup\n\n'
            'With kG as a feedforward term:\n'
            '• The feedforward provides exactly the voltage gravity demands\n'
            '• The PID only needs to handle small errors\n'
            '• Much smoother, more responsive control\n\n'
            'This is the biggest advantage of running system identification '
            'on gravity-affected mechanisms.',
        icon: FluentIcons.check_mark,
      ),
    ],
  ),

  TutorialTopic(
    id: 'const_pid',
    title: 'PID Gains Explained',
    category: TutorialCategory.constants,
    steps: [
      TutorialStep(
        title: 'What is PID Control?',
        description:
            'PID (Proportional-Integral-Derivative) is a feedback controller '
            'that adjusts the motor voltage based on the error between the '
            'desired state and the actual state.\n\n'
            '• P (Proportional): Reacts to current error\n'
            '  Larger error → stronger correction\n\n'
            '• I (Integral): Reacts to accumulated error over time\n'
            '  Eliminates persistent offset (steady-state error)\n\n'
            '• D (Derivative): Reacts to rate of error change\n'
            '  Damps oscillations, acts as a "brake"\n\n'
            'PID works alongside feedforward — feedforward handles the '
            'physics, PID handles the remaining small errors.',
        icon: FluentIcons.slider_thumb,
        customContent: (_) => const PidResponseDiagram(),
      ),
      const TutorialStep(
        title: 'How This Tool Computes PID',
        description:
            'This tool derives PID gains mathematically from the feedforward '
            'constants, rather than manual trial-and-error:\n\n'
            'For velocity control:\n'
            '• kP = kA / (τ · V_nominal)\n'
            '  where τ is the desired time constant\n'
            '• kI = 0 (feedforward handles steady-state)\n'
            '• kD = kA / V_nominal\n\n'
            'For position control:\n'
            '• Uses pole placement with desired bandwidth and damping ratio\n'
            '• Accounts for the plant dynamics (kV, kA)\n\n'
            'You can adjust the aggressiveness using the tuning sliders '
            'on the Results screen.',
        icon: FluentIcons.calculator,
      ),
      const TutorialStep(
        title: 'Tuning Tips',
        description:
            'After the auto-computed PID gains:\n\n'
            '1. Run a Validation test on the Validation screen\n'
            '   This tests the gains on your actual mechanism\n\n'
            '2. Check the step response:\n'
            '   • Too slow? → Decrease velocity time constant (faster)\n'
            '   • Oscillating? → Increase time constant (slower/safer)\n'
            '   • Steady-state error? → The feedforward may need adjustment\n\n'
            '3. For position control:\n'
            '   • Increase bandwidth for faster tracking\n'
            '   • Keep damping ratio ≥ 0.7 to avoid oscillation\n'
            '   • Critically damped (ζ=1.0) is a safe starting point',
        icon: FluentIcons.repair,
      ),
    ],
  ),

  // =========================================================================
  // Best Practices Topics
  // =========================================================================

  TutorialTopic(
    id: 'bp_mistakes',
    title: 'Common Mistakes',
    category: TutorialCategory.bestPractices,
    steps: [
      const TutorialStep(
        title: 'Wrong Conversion Factors',
        description:
            'The #1 mistake: incorrect position/velocity conversion factors.\n\n'
            'Symptoms:\n'
            '• kV is way too large or too small\n'
            '• Computed PID gains cause violent oscillation or no response\n'
            '• Validation tests show huge error\n\n'
            'How to verify:\n'
            '1. Jog the motor on the Configuration screen\n'
            '2. Physically measure one rotation of the output\n'
            '3. Compare the encoder readout to the physical measurement\n'
            '4. Adjust conversion factor until they match\n\n'
            'Example: 10:1 gear ratio → position conversion = 1/10 = 0.1',
        icon: FluentIcons.warning,
      ),
      const TutorialStep(
        title: 'Reversed Motor Direction',
        description:
            'If the motor\'s positive direction doesn\'t match the encoder\'s '
            'positive direction:\n\n'
            '• kS may come out negative (physically impossible)\n'
            '• The regression fit will be poor (low R²)\n'
            '• Forward/reverse tests will look inconsistent\n\n'
            'Fix: Toggle "Motor Inverted" on the Device Parameters screen.\n\n'
            'How to check: Jog the motor with a positive voltage and verify '
            'the position increases (not decreases).',
        icon: FluentIcons.sync,
      ),
      const TutorialStep(
        title: 'Skipping Tests',
        description:
            'All four tests are needed for accurate identification:\n\n'
            '• Without quasistatic tests → can\'t separate kS from kV\n'
            '• Without dynamic tests → can\'t measure kA\n'
            '• Without both directions → can\'t account for asymmetric friction\n\n'
            'You might get "approximate" results with fewer tests, but:\n'
            '→ R² will be worse\n'
            '→ kS may be wrong\n'
            '→ PID gains derived from bad FF constants will perform poorly\n\n'
            'It only takes an extra 30 seconds per test — run them all!',
        icon: FluentIcons.error,
      ),
    ],
  ),

  TutorialTopic(
    id: 'bp_validation',
    title: 'Validation Check',
    category: TutorialCategory.bestPractices,
    requiredScreenIndex: 6, // Validation screen
    steps: [
      TutorialStep(
        title: 'Expected Value Ranges',
        description:
            'After computing gains, verify they\'re in reasonable ranges:\n\n'
            'kS: 0.05–2.0V (usually 0.1–0.5V)\n'
            '  > 2.0V → very high friction (check mechanism)\n'
            '  < 0 → motor direction is reversed\n\n'
            'kV: Depends on units, but should be positive and reasonable\n'
            '  For RPM: typically 0.01–0.05 V·s/RPM\n\n'
            'kA: Should be small and positive\n'
            '  Very large kA → heavy/geared mechanism\n'
            '  kA ≤ 0 → something is wrong\n\n'
            'R²: > 0.95 is good, > 0.99 is excellent',
        icon: FluentIcons.check_mark,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.validationTestSelector),
        ],
      ),
      const TutorialStep(
        title: 'Closed-Loop Validation',
        description:
            'The best validation is to test the computed gains on the real '
            'mechanism:\n\n'
            '1. Go to the Validation screen\n'
            '2. Select a velocity step test\n'
            '3. Run the test — the SPARK uses your computed gains\n'
            '4. Check the step response:\n\n'
            '   Good response:\n'
            '   → Fast rise to setpoint with minimal overshoot\n'
            '   → Settles within 0.5 seconds\n'
            '   → Steady-state error < 5%\n\n'
            '   Bad response:\n'
            '   → Large oscillations → reduce PID aggressiveness\n'
            '   → Never reaches setpoint → check feedforward values\n'
            '   → Slow approach → increase PID aggressiveness',
        icon: FluentIcons.test_beaker,
      ),
    ],
  ),

  TutorialTopic(
    id: 'bp_export',
    title: 'Exporting & Using Results',
    category: TutorialCategory.bestPractices,
    requiredScreenIndex: 7, // Deploy screen
    steps: [
      TutorialStep(
        title: 'Export Options',
        description:
            'Once you\'re happy with your gains, export them for use '
            'in your robot code:\n\n'
            '• Code Snippets — Ready-to-paste Java, Python, or C++ code\n'
            '  Includes feedforward constants and PID configuration\n\n'
            '• WPILib SysId JSON — Compatible with WPILib\'s analysis tools\n'
            '  Contains the raw test data, not just the computed gains\n\n'
            '• CSV — Raw timestamped data for your own analysis\n'
            '  Useful if you want to plot in Excel or custom tools\n\n'
            '• PDF Report — Summary with all gains, plots, and test info',
        icon: FluentIcons.download,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.codeSnippetArea),
        ],
      ),
      TutorialStep(
        title: 'Deploying to the SPARK',
        description:
            'You can also write the gains directly to the SPARK\'s flash '
            'memory:\n\n'
            '1. Review the gains on the Deploy screen\n'
            '2. Click "Burn to Flash" to write them permanently\n'
            '3. The gains survive power cycles\n\n'
            'This writes to PID Slot 0:\n'
            '• kP, kI, kD for closed-loop feedback\n'
            '• kV feedforward (not the same as kV from sysid!)\n\n'
            'After deploying, your robot code only needs to set the '
            'setpoint — the SPARK handles the rest using the on-board '
            'PID + feedforward.',
        icon: FluentIcons.rocket,
        highlights: [
          HighlightTarget(globalKey: TutorialKeys.burnFlashButton),
        ],
      ),
    ],
  ),
];
