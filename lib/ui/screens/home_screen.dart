/// Home screen with quick-start workflow overview.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../state/app_state.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ScaffoldPage.scrollable(
      header: const PageHeader(title: Text('Welcome')),
      children: [
        const InfoBar(
          title: Text("Crumboe's (unofficial) REV System Identification Tool"),
          content: Text(
            'Characterize your REV motor mechanism to determine feedforward '
            'constants (kS, kV, kA, kG) and optimal PID values.',
          ),
          severity: InfoBarSeverity.info,
          isLong: true,
        ),
        FilledButton(
          onPressed: () => launchUrl(
            Uri.parse('https://paypal.me/crumboe22'),
            mode: LaunchMode.externalApplication,
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(FluentIcons.heart, size: 16),
              SizedBox(width: 8),
              Text('Leave a Tip'),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Quick Start',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        _StepCard(
          step: 1,
          title: 'Connect Device',
          description:
              'Plug in your SPARK MAX/Flex via USB-C and connect on the '
              'Device Setup page.',
          icon: FluentIcons.plug_connected,
          onTap: () => ref.read(selectedPageProvider.notifier).state = 1,
        ),
        const SizedBox(height: 8),
        _StepCard(
          step: 2,
          title: 'Configure Mechanism',
          description:
              'Select your mechanism type (Arm, Elevator, or Flywheel), '
              'set conversion factors, units, and safety limits.',
          icon: FluentIcons.settings,
          onTap: () => ref.read(selectedPageProvider.notifier).state = 3,
        ),
        const SizedBox(height: 8),
        _StepCard(
          step: 3,
          title: 'Verify with Jog',
          description:
              'Use the Jog controls on the Config page to slowly move the '
              'mechanism. Verify direction, conversion factors, and set '
              'soft limits from actual positions.',
          icon: FluentIcons.game,
          onTap: () => ref.read(selectedPageProvider.notifier).state = 3,
        ),
        const SizedBox(height: 8),
        _StepCard(
          step: 4,
          title: 'Run Tests',
          description:
              'Execute quasistatic and dynamic tests. The tool will '
              'automatically ramp/step voltage while recording data.',
          icon: FluentIcons.play,
          onTap: () => ref.read(selectedPageProvider.notifier).state = 4,
        ),
        const SizedBox(height: 8),
        _StepCard(
          step: 5,
          title: 'View Results',
          description:
              'Review computed feedforward & PID gains, diagnostic plots, '
              'and optionally export data to CSV.',
          icon: FluentIcons.chart,
          onTap: () => ref.read(selectedPageProvider.notifier).state = 5,
        ),
        const SizedBox(height: 8),
        _StepCard(
          step: 6,
          title: 'Validate Gains',
          description:
              'Write gains to the controller and run closed-loop step '
              'response tests to verify performance. Check rise time, '
              'overshoot, and steady-state error.',
          icon: FluentIcons.test_beaker,
          onTap: () => ref.read(selectedPageProvider.notifier).state = 6,
        ),
        const SizedBox(height: 32),
        const InfoBar(
          title: Text('No hardware? No problem!'),
          content: Text(
            'Select a \u{1F9EA} Simulated device (Flywheel, Arm, or Elevator) '
            'from the COM port dropdown on the Device Setup page to practice '
            'the full sysid workflow with a physics-based model. Each '
            'simulated device has known system constants — see if your '
            'analysis recovers them!',
          ),
          severity: InfoBarSeverity.success,
          isLong: true,
        ),
        const SizedBox(height: 16),
        const InfoBar(
          title: Text('Safety Notice'),
          content: Text(
            'Always configure soft limits for Arms and Elevators before '
            'running tests. Use the Jog controls to verify motion direction '
            'and set limits from actual positions. Enable Current Trip '
            'Protection to auto-stop if the motor stalls against a hard stop. '
            'Keep the area around the mechanism clear and physically support '
            'gravity-loaded mechanisms before powering the motor. '
            'Use the Emergency Stop button if anything goes wrong.',
          ),
          severity: InfoBarSeverity.warning,
          isLong: true,
        ),
      ],
    );
  }
}

class _StepCard extends StatelessWidget {
  final int step;
  final String title;
  final String description;
  final IconData icon;
  final VoidCallback? onTap;

  const _StepCard({
    required this.step,
    required this.title,
    required this.description,
    required this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Card(
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: FluentTheme.of(context).accentColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Text(
                  '$step',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Icon(icon, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 13,
                      color: FluentTheme.of(context)
                          .typography
                          .body
                          ?.color
                          ?.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            const Icon(FluentIcons.chevron_right, size: 16),
          ],
        ),
      ),
    );
  }
}
