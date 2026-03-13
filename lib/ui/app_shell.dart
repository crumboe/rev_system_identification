/// Root application shell with Fluent UI navigation.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/project_file.dart';
import '../state/app_state.dart';
import 'screens/home_screen.dart';
import 'screens/device_screen.dart';
import 'screens/device_config_screen.dart';
import 'screens/config_screen.dart';
import 'screens/test_screen.dart';
import 'screens/results_screen.dart';
import 'screens/validation_screen.dart';
import 'screens/console_screen.dart';


/// Main application shell with side navigation.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  Future<void> _saveProject() async {
    final config = ref.read(mechanismConfigProvider);
    final testParams = ref.read(testParamsProvider);
    final testRuns = ref.read(testRunsProvider);
    final ff = ref.read(feedforwardGainsProvider);
    final velPid = ref.read(pidResultProvider);
    final posPid = ref.read(posPidResultProvider);

    final project = ProjectData(
      config: config,
      testParams: testParams,
      testRuns: testRuns,
      feedforward: ff,
      velocityPid: velPid,
      positionPid: posPid,
    );

    final path = await saveProject(project);
    if (path != null && mounted) {
      await displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: const Text('Project saved'),
          content: Text(path),
          severity: InfoBarSeverity.success,
          action: IconButton(
            icon: const Icon(FluentIcons.clear),
            onPressed: close,
          ),
        );
      });
    }
  }

  Future<void> _loadProject() async {
    final project = await loadProject();
    if (project == null) return;

    ref.read(mechanismConfigProvider.notifier).setConfig(project.config);
    ref.read(testParamsProvider.notifier).setParams(project.testParams);
    ref.read(testRunsProvider.notifier).loadRuns(project.testRuns);
    ref.read(feedforwardGainsProvider.notifier).state = project.feedforward;
    ref.read(pidResultProvider.notifier).state = project.velocityPid;
    ref.read(posPidResultProvider.notifier).state = project.positionPid;

    if (mounted) {
      final name = project.config.systemName.isNotEmpty
          ? project.config.systemName
          : 'Untitled';
      final runCount = project.testRuns.length;
      await displayInfoBar(context, builder: (context, close) {
        return InfoBar(
          title: Text('Loaded "$name"'),
          content: Text(
            '$runCount test run${runCount == 1 ? '' : 's'}'
            '${project.feedforward != null ? ', feedforward gains' : ''}'
            '${project.velocityPid != null ? ', velocity PID' : ''}'
            '${project.positionPid != null ? ', position PID' : ''}',
          ),
          severity: InfoBarSeverity.success,
          action: IconButton(
            icon: const Icon(FluentIcons.clear),
            onPressed: close,
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedIndex = ref.watch(selectedPageProvider);

    final themeMode = ref.watch(themeModeProvider);
    final isDark = themeMode == ThemeMode.dark ||
        (themeMode == ThemeMode.system &&
            MediaQuery.platformBrightnessOf(context) == Brightness.dark);

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
            icon: const Icon(FluentIcons.slider_thumb),
            title: const Text('Device Parameters'),
            body: const DeviceConfigScreen(),
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
          PaneItem(
            icon: const Icon(FluentIcons.command_prompt),
            title: const Text('Console'),
            body: const ConsoleScreen(),
          ),

        ],
        footerItems: [
          PaneItemAction(
            icon: const Icon(FluentIcons.save),
            title: const Text('Save Project'),
            onTap: _saveProject,
          ),
          PaneItemAction(
            icon: const Icon(FluentIcons.folder_open),
            title: const Text('Load Project'),
            onTap: _loadProject,
          ),
          PaneItemAction(
            icon: Icon(isDark ? FluentIcons.sunny : FluentIcons.clear_night),
            title: Text(isDark ? 'Light Mode' : 'Dark Mode'),
            onTap: () {
              ref.read(themeModeProvider.notifier).state =
                  isDark ? ThemeMode.light : ThemeMode.dark;
            },
          ),
        ],
      ),
    );
  }
}
