import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:system_theme/system_theme.dart';

import 'state/app_state.dart';
import 'ui/app_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemTheme.accentColor.load();
  runApp(const ProviderScope(child: RevSysIdApp()));
}

class RevSysIdApp extends ConsumerWidget {
  const RevSysIdApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    return FluentApp(
      title: "Crumboe's (unofficial) REV System Identification Tool",
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      darkTheme: FluentThemeData(
        brightness: Brightness.dark,
        accentColor: Colors.blue,
        visualDensity: VisualDensity.standard,
      ),
      theme: FluentThemeData(
        brightness: Brightness.light,
        accentColor: SystemTheme.accentColor.accent.toAccentColor(),
        visualDensity: VisualDensity.standard,
      ),
      home: const AppShell(),
    );
  }
}
