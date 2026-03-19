library;

import 'package:flutter_test/flutter_test.dart';

import 'package:rev_system_identification/data/code_snippet_exporter.dart';
import 'package:rev_system_identification/data/test_data.dart';
import 'package:rev_system_identification/mechanisms/mechanism.dart';

void main() {
  group('CodeSnippetExporter', () {
    test('includes iZone and open-loop ramp rate in all languages', () {
      const config = MechanismConfig(
        type: MechanismType.flywheel,
        systemName: 'Shooter',
      );
      const ff = FeedforwardGains(kS: 0.2, kV: 0.01, kA: 0.001);
      const velocityPid = PidResult(
        kP: 0.1,
        kI: 0.01,
        kD: 0.0,
        iZone: 2.5,
        allowedClosedLoopError: 0.125,
      );
      const positionPid = PidResult(
        kP: 0.2,
        kI: 0.02,
        kD: 0.1,
        iZone: 1.25,
        allowedClosedLoopError: 0.075,
      );

      final snippets = CodeSnippetExporter.generate(
        config: config,
        ff: ff,
        velocityPid: velocityPid,
        positionPid: positionPid,
        openLoopRampRate: 0.75,
      );

      expect(snippets.java, contains('.iZone(2.500000)'));
      expect(snippets.java, contains('.iZone(1.250000)'));
      expect(snippets.java, contains('.allowedClosedLoopError(0.125000)'));
      expect(snippets.java, contains('.allowedClosedLoopError(0.075000)'));
      expect(snippets.java, contains('config.openLoopRampRate(0.750000);'));

      expect(snippets.python, contains('config.closedLoop.iZone(2.500000)'));
      expect(
        snippets.python,
        contains('config.closedLoop.allowedClosedLoopError(0.125000)'),
      );
      expect(
        snippets.python,
        contains('config.closedLoop.slot1.iZone(1.250000)'),
      );
      expect(
        snippets.python,
        contains('config.closedLoop.slot1.allowedClosedLoopError(0.075000)'),
      );
      expect(snippets.python, contains('config.openLoopRampRate(0.750000)'));

      expect(snippets.cpp, contains('.IZone(2.500000)'));
      expect(snippets.cpp, contains('.AllowedClosedLoopError(0.125000);'));
      expect(
        snippets.cpp,
        contains('config.closedLoop.slot1.IZone(1.250000);'),
      );
      expect(
        snippets.cpp,
        contains('config.closedLoop.slot1.AllowedClosedLoopError(0.075000);'),
      );
      expect(snippets.cpp, contains('config.OpenLoopRampRate(0.750000);'));
    });
  });
}
