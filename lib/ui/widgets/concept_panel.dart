/// Expandable reference panel listing key control theory concepts.
library;

import 'package:fluent_ui/fluent_ui.dart';

class ConceptEntry {
  final String title;
  final String description;
  final IconData icon;

  const ConceptEntry({
    required this.title,
    required this.description,
    required this.icon,
  });
}

class ConceptPanel extends StatelessWidget {
  /// When true, renders just the list (for use inside a dialog).
  /// When false, wraps in an Expander.
  final bool embedded;

  const ConceptPanel({super.key, this.embedded = false});

  static const List<ConceptEntry> _concepts = [
    ConceptEntry(
      title: 'Static Friction (kS)',
      description:
          'The minimum voltage required to overcome static friction and start '
          'the mechanism moving. Units: Volts.',
      icon: FluentIcons.lightning_bolt,
    ),
    ConceptEntry(
      title: 'Velocity Gain (kV)',
      description:
          'The voltage required per unit of velocity at steady state. '
          'Units: V·s/unit. Higher kV means more voltage is needed to maintain speed.',
      icon: FluentIcons.speed_high,
    ),
    ConceptEntry(
      title: 'Acceleration Gain (kA)',
      description:
          'The voltage required per unit of acceleration. '
          'Units: V·s²/unit. Higher kA means the mechanism has more inertia.',
      icon: FluentIcons.rocket,
    ),
    ConceptEntry(
      title: 'Gravity Compensation (kG)',
      description:
          'Voltage to hold the mechanism against gravity. '
          'For arms: kG·cos(θ). For elevators: kG (constant). Units: Volts.',
      icon: FluentIcons.globe2,
    ),
    ConceptEntry(
      title: 'Proportional Gain (kP)',
      description:
          'The feedback gain proportional to the current error. '
          'Higher kP → faster response but may cause oscillation.',
      icon: FluentIcons.slider_thumb,
    ),
    ConceptEntry(
      title: 'Integral Gain (kI)',
      description:
          'The gain on accumulated error over time. kI removes steady-state '
          'error but can cause windup if too large.',
      icon: FluentIcons.calculator,
    ),
    ConceptEntry(
      title: 'Derivative Gain (kD)',
      description:
          'The gain on the rate of change of error. '
          'kD damps oscillations but amplifies noise.',
      icon: FluentIcons.line_chart,
    ),
    ConceptEntry(
      title: 'Quasistatic Test',
      description:
          'A very slow voltage ramp test where acceleration ≈ 0. Used to '
          'identify kS and kV from the steady-state relationship: '
          'V ≈ kS·sign(ω) + kV·ω.',
      icon: FluentIcons.timer,
    ),
    ConceptEntry(
      title: 'Dynamic Test',
      description:
          'A sudden voltage step that generates significant acceleration. '
          'Used to identify kA from: V ≈ kS·sign(ω) + kV·ω + kA·α.',
      icon: FluentIcons.lightning_bolt,
    ),
    ConceptEntry(
      title: 'Rise Time',
      description:
          'Time for the system to go from 10% to 90% of the target setpoint. '
          'Measures how quickly the system responds.',
      icon: FluentIcons.up,
    ),
    ConceptEntry(
      title: 'Overshoot',
      description:
          'How much the system exceeds the setpoint before settling. '
          'Expressed as a percentage. Values above 20% may indicate instability.',
      icon: FluentIcons.chevron_up_small,
    ),
    ConceptEntry(
      title: 'Steady-State Error',
      description:
          'The persistent error remaining after the system settles. '
          'A well-tuned system has near-zero steady-state error.',
      icon: FluentIcons.equalizer,
    ),
    ConceptEntry(
      title: 'Phase Margin',
      description:
          'How many degrees away from -180° the phase is when the open-loop '
          'gain is 0 dB. Positive phase margin means stable. '
          'Values 30–60° are good.',
      icon: FluentIcons.rotate,
    ),
    ConceptEntry(
      title: 'Gain Margin',
      description:
          'How many dB the gain can increase before the system becomes '
          'unstable. Positive gain margin means stable. '
          'Values above 6 dB are safe.',
      icon: FluentIcons.network_tower,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final list = SizedBox(
      height: 400,
      child: ListView.builder(
        itemCount: _concepts.length,
        itemBuilder: (context, index) {
          final entry = _concepts[index];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 12),
                  child: Icon(entry.icon, size: 18),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.title,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.description,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    if (embedded) return list;

    return Expander(
      header: const Row(
        children: [
          Icon(FluentIcons.info, size: 16),
          SizedBox(width: 8),
          Text('Control Theory Concepts'),
        ],
      ),
      content: list,
    );
  }
}
