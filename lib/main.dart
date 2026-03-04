import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:system_theme/system_theme.dart';

import 'ui/app_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemTheme.accentColor.load();
  runApp(const ProviderScope(child: RevSysIdApp()));
}

class RevSysIdApp extends StatelessWidget {
  const RevSysIdApp({super.key});

  @override
  Widget build(BuildContext context) {
    return FluentApp(
      title: 'REV System Identification Tool',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
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
