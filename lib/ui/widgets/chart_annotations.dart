/// Chart annotation helpers for educational overlays.
///
/// Provides preconfigured walkthrough steps and tooltip builders
/// for each chart type in the application.
library;

import 'package:fluent_ui/fluent_ui.dart' show FluentIcons;

import 'chart_walkthrough.dart';

// ---------------------------------------------------------------------------
// Voltage vs Velocity plot walkthrough (quasistatic results)
// ---------------------------------------------------------------------------

/// Walkthrough steps for the Voltage vs Velocity scatter plot.
List<WalkthroughStep> voltageVelocityWalkthroughSteps({
  required double kS,
  required double kV,
  required double rSquared,
}) {
  return [
    const WalkthroughStep(
      title: 'What is this chart?',
      description:
          'This scatter plot shows every data point from your quasistatic '
          'tests. Each dot is one measurement: the X axis is the motor\'s '
          'velocity and the Y axis is the voltage that was applied at that '
          'instant.\n\n'
          'Quasistatic means the motor was accelerating very slowly, so '
          'we can ignore acceleration effects.',
      icon: FluentIcons.chart,
    ),
    const WalkthroughStep(
      title: 'The Linear Relationship',
      description:
          'Notice how the dots form a roughly straight line? That\'s the '
          'key insight: at steady state, voltage and velocity have a LINEAR '
          'relationship.\n\n'
          'The equation is:  V = kS \u00b7 sign(\u03c9) + kV \u00b7 \u03c9\n\n'
          'kS is the voltage needed to overcome static friction (the '
          'Y-intercept), and kV is how much extra voltage you need per unit '
          'of velocity (the slope).',
      icon: FluentIcons.trending12,
    ),
    WalkthroughStep(
      title: 'kS — Static Friction',
      description:
          'The red regression line intersects the voltage axis at about '
          '${kS.toStringAsFixed(3)} V. This is kS, the voltage required '
          'just to START the motor moving.\n\n'
          'Think of it like pushing a heavy box — you need some minimum force '
          'just to get it moving, before you can control its speed.',
      icon: FluentIcons.pinned,
    ),
    WalkthroughStep(
      title: 'kV — Velocity Constant',
      description:
          'The slope of the red line is kV = '
          '${kV.toStringAsFixed(5)} V per unit velocity.\n\n'
          'This tells you: for every additional unit of speed, you need '
          'this much more voltage. A higher kV means the motor needs more '
          '"effort" to go faster (more friction or back-EMF).',
      icon: FluentIcons.up,
    ),
    WalkthroughStep(
      title: 'R\u00b2 — How Good is the Fit?',
      description:
          'R\u00b2 = ${rSquared.toStringAsFixed(4)}.  This number (0 to 1) '
          'tells you how well the line fits the data.\n\n'
          'R\u00b2 > 0.95 = excellent fit\n'
          'R\u00b2 > 0.90 = good fit\n'
          'R\u00b2 < 0.80 = something may be wrong (check wiring, '
          'mechanism binding, or try collecting more data).\n\n'
          'Scatter around the line is normal — it\'s sensor noise.',
      icon: FluentIcons.check_mark,
    ),
    const WalkthroughStep(
      title: 'What to do with kS and kV',
      description:
          'These constants go into your robot code\'s feedforward controller. '
          'When you command a velocity, the feedforward calculates:\n\n'
          '    voltage = kS \u00b7 sign(target) + kV \u00b7 target\n\n'
          'This gets the motor CLOSE to the right speed before PID makes '
          'fine corrections. Good feedforward = less work for PID = better '
          'control!',
      icon: FluentIcons.rocket,
    ),
  ];
}

// ---------------------------------------------------------------------------
// Step Response plot walkthrough (dynamic results)
// ---------------------------------------------------------------------------

/// Walkthrough steps for the Step Response (dynamic) plot.
List<WalkthroughStep> stepResponseWalkthroughSteps() {
  return [
    const WalkthroughStep(
      title: 'What is this chart?',
      description:
          'This is a step response plot from your dynamic tests. A constant '
          'voltage was suddenly applied (the "step"), and we recorded the '
          'resulting velocity over time.\n\n'
          'The X axis is time (seconds), the Y axis is velocity.',
      icon: FluentIcons.chart,
    ),
    const WalkthroughStep(
      title: 'The Ramp-Up Phase',
      description:
          'Right after the step voltage is applied, velocity increases '
          'rapidly. The motor is accelerating because the applied voltage '
          'is much more than what\'s needed for the current (low) speed.\n\n'
          'The steepness of this initial ramp tells us about kA — the '
          'acceleration constant.',
      icon: FluentIcons.up,
    ),
    const WalkthroughStep(
      title: 'kA — Acceleration Constant',
      description:
          'kA measures how much voltage is "used up" by acceleration.\n\n'
          'A higher kA means the mechanism has more inertia (it\'s harder '
          'to speed up or slow down). kA is determined by comparing the '
          'dynamic data to the quasistatic model:\n\n'
          '    V = kS\u00b7sign(\u03c9) + kV\u00b7\u03c9 + kA\u00b7\u03b1\n\n'
          'where \u03b1 is the measured acceleration.',
      icon: FluentIcons.scale_volume,
    ),
    const WalkthroughStep(
      title: 'Steady State',
      description:
          'Eventually the curve flattens out — the motor reaches a steady '
          'speed where all the applied voltage is being used to overcome '
          'friction (kS) and back-EMF (kV\u00b7\u03c9), with none left for '
          'acceleration.\n\n'
          'This steady-state velocity should match: \u03c9 = (V - kS) / kV.',
      icon: FluentIcons.accept,
    ),
    const WalkthroughStep(
      title: 'Time Constant',
      description:
          'The shape of the curve is an exponential rise. The "time constant" '
          '(\u03c4) is roughly the time to reach 63% of steady-state speed.\n\n'
          '\u03c4 \u2248 kA / kV\n\n'
          'A small \u03c4 means the mechanism responds quickly. A large \u03c4 '
          'means it\'s sluggish. PID tuning depends heavily on this value!',
      icon: FluentIcons.timer,
    ),
  ];
}

// ---------------------------------------------------------------------------
// Live chart walkthrough (test screen)
// ---------------------------------------------------------------------------

/// Walkthrough steps for live data charts during testing.
List<WalkthroughStep> liveChartWalkthroughSteps() {
  return [
    const WalkthroughStep(
      title: 'Live Data Monitor',
      description:
          'These four charts show real-time data streaming from the motor '
          'controller during a test. Each chart shows the last 500 data '
          'points, scrolling automatically.\n\n'
          'Velocity, Voltage, Position, and Current are all recorded '
          'simultaneously.',
      icon: FluentIcons.chart,
    ),
    const WalkthroughStep(
      title: 'Velocity Chart',
      description:
          'The blue chart tracks how fast the motor is spinning. During a '
          'quasistatic test, you should see a smooth, gradually increasing '
          'ramp. During a dynamic test, you\'ll see a sudden jump.\n\n'
          'If velocity looks noisy or erratic, check your sensor wiring.',
      icon: FluentIcons.speed_high,
    ),
    const WalkthroughStep(
      title: 'Voltage Chart',
      description:
          'The orange chart shows the voltage being sent to the motor. '
          'During quasistatic tests, this ramps linearly. During dynamic '
          'tests, it jumps to a constant step voltage.\n\n'
          'The program controls this automatically — you just watch!',
      icon: FluentIcons.lightning_bolt,
    ),
    const WalkthroughStep(
      title: 'Position & Current',
      description:
          'Position (green) tracks total rotations — useful for Arms and '
          'Elevators to verify soft limits are working.\n\n'
          'Current (red) shows how hard the motor is working. High current '
          'at low speed suggests binding or obstruction. Current should '
          'decrease as the motor reaches steady-state speed.',
      icon: FluentIcons.plug_connected,
    ),
    const WalkthroughStep(
      title: 'Safety Monitoring',
      description:
          'Watch for these warning signs during tests:\n\n'
          '\u2022 Velocity flat at zero = motor not spinning (check wiring)\n'
          '\u2022 Current spikes to limit = mechanism jammed\n'
          '\u2022 Position exceeding soft limits = stop immediately!\n\n'
          'Use the EMERGENCY STOP button (top right) if anything looks wrong.',
      icon: FluentIcons.warning,
    ),
  ];
}
