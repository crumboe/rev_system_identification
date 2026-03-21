/// Central registry of [GlobalKey]s for tutorial spotlight targets.
///
/// Screens attach these keys to specific widgets so the tutorial overlay
/// can locate and highlight them. This keeps tutorial concerns centralized
/// rather than scattered across screen files.
///
/// Usage in a screen:
/// ```dart
/// FilledButton(
///   key: TutorialKeys.deviceConnectButton,
///   onPressed: _connect,
///   child: const Text('Connect'),
/// )
/// ```
library;

import 'package:fluent_ui/fluent_ui.dart';

abstract final class TutorialKeys {
  // -------------------------------------------------------------------------
  // Device Screen
  // -------------------------------------------------------------------------
  static final devicePortDropdown =
      GlobalKey(debugLabel: 'tutorial:devicePortDropdown');
  static final deviceConnectButton =
      GlobalKey(debugLabel: 'tutorial:deviceConnectButton');
  static final deviceCanIdField =
      GlobalKey(debugLabel: 'tutorial:deviceCanIdField');

  // -------------------------------------------------------------------------
  // Device Config Screen
  // -------------------------------------------------------------------------
  static final motorTypeSelector =
      GlobalKey(debugLabel: 'tutorial:motorTypeSelector');
  static final motorInversionToggle =
      GlobalKey(debugLabel: 'tutorial:motorInversionToggle');
  static final currentLimitField =
      GlobalKey(debugLabel: 'tutorial:currentLimitField');

  // -------------------------------------------------------------------------
  // Config Screen
  // -------------------------------------------------------------------------
  static final mechanismTypeSelector =
      GlobalKey(debugLabel: 'tutorial:mechanismTypeSelector');
  static final encoderConfigSection =
      GlobalKey(debugLabel: 'tutorial:encoderConfigSection');
  static final softLimitsSection =
      GlobalKey(debugLabel: 'tutorial:softLimitsSection');
  static final conversionFactorField =
      GlobalKey(debugLabel: 'tutorial:conversionFactorField');
  static final jogControls =
      GlobalKey(debugLabel: 'tutorial:jogControls');

  // -------------------------------------------------------------------------
  // Test Screen
  // -------------------------------------------------------------------------
  static final testTypeSelector =
      GlobalKey(debugLabel: 'tutorial:testTypeSelector');
  static final startTestButton =
      GlobalKey(debugLabel: 'tutorial:startTestButton');
  static final testChart =
      GlobalKey(debugLabel: 'tutorial:testChart');
  static final testParamsSection =
      GlobalKey(debugLabel: 'tutorial:testParamsSection');

  // -------------------------------------------------------------------------
  // Results Screen
  // -------------------------------------------------------------------------
  static final feedforwardGainsCard =
      GlobalKey(debugLabel: 'tutorial:feedforwardGainsCard');
  static final pidGainsCard =
      GlobalKey(debugLabel: 'tutorial:pidGainsCard');
  static final rSquaredIndicator =
      GlobalKey(debugLabel: 'tutorial:rSquaredIndicator');
  static final exportButton =
      GlobalKey(debugLabel: 'tutorial:exportButton');

  // -------------------------------------------------------------------------
  // Validation Screen
  // -------------------------------------------------------------------------
  static final validationTestSelector =
      GlobalKey(debugLabel: 'tutorial:validationTestSelector');
  static final validationChart =
      GlobalKey(debugLabel: 'tutorial:validationChart');

  // -------------------------------------------------------------------------
  // Deploy Screen
  // -------------------------------------------------------------------------
  static final burnFlashButton =
      GlobalKey(debugLabel: 'tutorial:burnFlashButton');
  static final codeSnippetArea =
      GlobalKey(debugLabel: 'tutorial:codeSnippetArea');
}
