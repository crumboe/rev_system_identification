/// Root application shell with Fluent UI navigation.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_state.dart';
import 'screens/home_screen.dart';
import 'screens/device_screen.dart';
import 'screens/config_screen.dart';
import 'screens/test_screen.dart';
import 'screens/results_screen.dart';
import 'screens/validation_screen.dart';

/// Main application shell with side navigation.
class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedIndex = ref.watch(selectedPageProvider);

    return NavigationView(
      pane: NavigationPane(
        selected: selectedIndex,
        onChanged: (index) =>
            ref.read(selectedPageProvider.notifier).state = index,
        displayMode: PaneDisplayMode.compact,
        items: [
          PaneItem(
            icon: const Icon(FluentIcons.home),
            title: const Text('Home'),
            body: const HomeScreen(),
          ),
          PaneItem(
            icon: const Icon(FluentIcons.plug_connected),
            title: const Text('Device Setup'),
            body: const DeviceScreen(),
          ),
          PaneItem(
            icon: const Icon(FluentIcons.settings),
            title: const Text('Configuration'),
            body: const ConfigScreen(),
          ),
          PaneItem(
            icon: const Icon(FluentIcons.play),
            title: const Text('Run Tests'),
            body: const TestScreen(),
          ),
          PaneItem(
            icon: const Icon(FluentIcons.chart),
            title: const Text('Results'),
            body: const ResultsScreen(),
          ),
          PaneItem(
            icon: const Icon(FluentIcons.test_beaker),
            title: const Text('Validation'),
            body: const ValidationScreen(),
          ),
        ],
      ),
    );
  }
}
