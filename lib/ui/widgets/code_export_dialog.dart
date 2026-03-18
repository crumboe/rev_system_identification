/// Reusable dialog that shows FRC code snippets in Java, Python, and C++ tabs.
///
/// Extracted from results_screen so it can be used by both the Results and
/// Deploy screens.
library;

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../data/code_snippet_exporter.dart';

// ---------------------------------------------------------------------------
// Code Export Dialog
// ---------------------------------------------------------------------------

/// Modal dialog that shows FRC code snippets in Java, Python, and C++ tabs.
class CodeExportDialog extends StatefulWidget {
  final CodeSnippets snippets;

  const CodeExportDialog({super.key, required this.snippets});

  @override
  State<CodeExportDialog> createState() => _CodeExportDialogState();
}

class _CodeExportDialogState extends State<CodeExportDialog> {
  int _tabIndex = 0;

  static const _tabs = ['Java', 'Python', 'C++'];

  String get _currentCode => switch (_tabIndex) {
        0 => widget.snippets.java,
        1 => widget.snippets.python,
        _ => widget.snippets.cpp,
      };

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);

    return ContentDialog(
      constraints: const BoxConstraints(maxWidth: 800, maxHeight: 660),
      title: const Row(
        children: [
          Icon(FluentIcons.code, size: 16),
          SizedBox(width: 8),
          Text('Export FRC Code Snippets'),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Copy the snippet for your preferred language into your robot project. '
            'Each snippet configures a SPARK MAX with your identified PID/feedforward gains, '
            'conversion factors, ramp rate, and inversion setting.',
            style: TextStyle(
              fontSize: 12,
              color: theme.typography.body?.color?.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 12),
          // Language selector row
          Row(
            children: [
              for (var i = 0; i < _tabs.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                LanguageTab(
                  label: _tabs[i],
                  selected: _tabIndex == i,
                  onPressed: () => setState(() => _tabIndex = i),
                ),
              ],
              const Spacer(),
              Button(
                onPressed: () => _copyToClipboard(context, _currentCode),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(FluentIcons.copy, size: 14),
                    SizedBox(width: 6),
                    Text('Copy to Clipboard'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Code display
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: theme.micaBackgroundColor.withValues(alpha: 0.5),
                border: Border.all(
                  color: theme.accentColor.withValues(alpha: 0.2),
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  _currentCode,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        Button(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  void _copyToClipboard(BuildContext context, String text) {
    Clipboard.setData(ClipboardData(text: text));
    displayInfoBar(context, builder: (ctx, close) {
      return InfoBar(
        title: Text('${_tabs[_tabIndex]} snippet copied'),
        content: const Text('Paste it into your robot project.'),
        severity: InfoBarSeverity.success,
        action: IconButton(
          icon: const Icon(FluentIcons.chrome_close),
          onPressed: close,
        ),
      );
    });
  }
}

/// A single language-selector tab button.
class LanguageTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  const LanguageTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (selected) {
      return FilledButton(onPressed: onPressed, child: Text(label));
    }
    return Button(onPressed: onPressed, child: Text(label));
  }
}
