/// Shared page header with the Crumboe's logo centered above the title.
library;

import 'package:fluent_ui/fluent_ui.dart';

/// A full-width header that places the logo centered across the entire page
/// width, then renders a standard [PageHeader] below it with the title
/// left-aligned and an optional [commandBar].
class LogoPageHeader extends StatelessWidget {
  final String title;
  final Widget? commandBar;

  const LogoPageHeader({super.key, required this.title, this.commandBar});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Image.asset(
              'assets/images/logo.png',
              height: 40,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
        PageHeader(
          title: Text(title),
          commandBar: commandBar,
        ),
      ],
    );
  }
}
