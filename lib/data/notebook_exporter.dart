/// Engineering notebook markdown exporter.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../mechanisms/mechanism.dart';
import '../sysid/validation_runner.dart';
import 'test_data.dart';

class NotebookExporter {
  static Future<String?> export({
    required MechanismConfig config,
    required FeedforwardGains ff,
    PidResult? velocityPid,
    PidResult? positionPid,
    List<TestRun> testRuns = const [],
    ValidationResult? validationResult,
  }) async {
    final content = _buildMarkdown(
      config: config,
      ff: ff,
      velocityPid: velocityPid,
      positionPid: positionPid,
      testRuns: testRuns,
      validationResult: validationResult,
    );

    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Engineering Notebook Entry',
      fileName:
          'sysid_notebook_${config.type.displayName.toLowerCase().replaceAll(' ', '_')}.md',
      type: FileType.custom,
      allowedExtensions: ['md'],
    );
    if (path == null) return null;

    final file = File(path);
    await file.writeAsString(content);
    return path;
  }

  static String _buildMarkdown({
    required MechanismConfig config,
    required FeedforwardGains ff,
    PidResult? velocityPid,
    PidResult? positionPid,
    required List<TestRun> testRuns,
    ValidationResult? validationResult,
  }) {
    final now = DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final buf = StringBuffer();

    buf.writeln('# System Identification Engineering Notebook Entry');
    buf.writeln();
    buf.writeln('**Date:** $dateStr');
    buf.writeln();

    // Mechanism configuration
    buf.writeln('## Mechanism Configuration');
    buf.writeln();
    buf.writeln('| Parameter | Value |');
    buf.writeln('|-----------|-------|');
    buf.writeln('| Mechanism Type | ${config.type.displayName} |');
    buf.writeln(
        '| Position Unit | ${config.positionUnit} |');
    buf.writeln(
        '| Velocity Unit | ${config.velocityUnit} |');
    buf.writeln(
        '| Motor Type | ${config.isBrushless ? "Brushless" : "Brushed"} |');
    buf.writeln(
        '| Motor Inverted | ${config.motorInverted} |');
    buf.writeln(
        '| Imperial Units | ${config.useImperialUnits} |');
    buf.writeln();

    // Test methodology
    buf.writeln('## Test Methodology');
    buf.writeln();
    final qsRuns = testRuns.where((r) => r.testType.isQuasistatic).toList();
    final dynRuns = testRuns.where((r) => r.testType.isDynamic).toList();
    buf.writeln(
        'System identification was performed using ${testRuns.length} test run(s): '
        '${qsRuns.length} quasistatic and ${dynRuns.length} dynamic.');
    buf.writeln();
    if (qsRuns.isNotEmpty) {
      buf.writeln(
          '**Quasistatic tests** apply a slow voltage ramp (acceleration ≈ 0) '
          'to isolate kS and kV from the steady-state relationship '
          '`V ≈ kS·sign(ω) + kV·ω`.');
    }
    if (dynRuns.isNotEmpty) {
      buf.writeln(
          '**Dynamic tests** apply a sudden voltage step to generate '
          'significant acceleration, enabling kA identification from '
          '`V ≈ kS·sign(ω) + kV·ω + kA·α`.');
    }
    buf.writeln();
    if (testRuns.isNotEmpty) {
      final totalSamples =
          testRuns.fold<int>(0, (s, r) => s + r.sampleCount);
      buf.writeln('| Run | Type | Samples | Duration (s) |');
      buf.writeln('|-----|------|---------|--------------|');
      for (final run in testRuns) {
        buf.writeln(
            '| ${run.startTime.toIso8601String().substring(0, 19)} '
            '| ${run.testType.displayName} '
            '| ${run.sampleCount} '
            '| ${run.durationSeconds.toStringAsFixed(2)} |');
      }
      buf.writeln();
      buf.writeln('**Total samples collected:** $totalSamples');
    }
    buf.writeln();

    // Feedforward parameters
    buf.writeln('## Identified Parameters');
    buf.writeln();
    buf.writeln('### Feedforward Constants');
    buf.writeln();
    buf.writeln('| Constant | Value | Units |');
    buf.writeln('|----------|-------|-------|');
    buf.writeln('| kS | ${ff.kS.toStringAsFixed(6)} | V |');
    buf.writeln(
        '| kV | ${ff.kV.toStringAsFixed(6)} | V·s/${config.positionUnit} |');
    buf.writeln(
        '| kA | ${ff.kA.toStringAsFixed(6)} | V·s²/${config.positionUnit} |');
    if (config.type.hasGravity) {
      buf.writeln('| kG | ${ff.kG.toStringAsFixed(6)} | V |');
    }
    buf.writeln();

    // PID design
    buf.writeln('## PID Controller Design');
    buf.writeln();
    if (velocityPid != null) {
      buf.writeln('### Velocity PID');
      buf.writeln();
      buf.writeln('| Gain | Value |');
      buf.writeln('|------|-------|');
      buf.writeln('| kP | ${velocityPid.kP.toStringAsFixed(8)} |');
      buf.writeln('| kI | ${velocityPid.kI.toStringAsFixed(8)} |');
      buf.writeln('| kD | ${velocityPid.kD.toStringAsFixed(8)} |');
      buf.writeln();
    }
    if (positionPid != null) {
      buf.writeln('### Position PID');
      buf.writeln();
      buf.writeln('| Gain | Value |');
      buf.writeln('|------|-------|');
      buf.writeln('| kP | ${positionPid.kP.toStringAsFixed(8)} |');
      buf.writeln('| kI | ${positionPid.kI.toStringAsFixed(8)} |');
      buf.writeln('| kD | ${positionPid.kD.toStringAsFixed(8)} |');
      buf.writeln();
    }
    if (velocityPid == null && positionPid == null) {
      buf.writeln('PID gains were not computed.');
      buf.writeln();
    }

    // Analysis section
    buf.writeln('## Analysis');
    buf.writeln();
    final equation = _modelEquation(config.type);
    buf.writeln('**Plant model:** `$equation`');
    buf.writeln();
    buf.writeln('**R² (goodness of fit):** ${ff.rSquared.toStringAsFixed(4)}');
    buf.writeln();
    if (ff.rSquared >= 0.95) {
      buf.writeln('> R² > 0.95 — Excellent fit. The model closely follows the data.');
    } else if (ff.rSquared >= 0.90) {
      buf.writeln('> R² > 0.90 — Good fit. Minor discrepancies may exist.');
    } else {
      buf.writeln('> R² < 0.90 — Review configuration; check gear ratio and conversion factors.');
    }
    buf.writeln();

    // Validation
    buf.writeln('## Validation Results');
    buf.writeln();
    if (validationResult != null && validationResult.completed) {
      final rt = validationResult.riseTime;
      final os = validationResult.overshootPercent;
      final sse = validationResult.steadyStateError;
      buf.writeln('| Metric | Value |');
      buf.writeln('|--------|-------|');
      buf.writeln(
          '| Mode | ${validationResult.mode.name} |');
      buf.writeln(
          '| Rise Time | ${rt != null ? "${rt.toStringAsFixed(3)} s" : "N/A"} |');
      buf.writeln(
          '| Overshoot | ${os != null ? "${os.toStringAsFixed(1)} %" : "N/A"} |');
      buf.writeln(
          '| Steady-State Error | ${sse != null ? sse.toStringAsFixed(4) : "N/A"} |');
      buf.writeln(
          '| Duration | ${validationResult.durationSeconds.toStringAsFixed(2)} s |');
    } else {
      buf.writeln('No validation test was performed or the test did not complete.');
    }
    buf.writeln();

    // Conclusions
    buf.writeln('## Conclusions');
    buf.writeln();
    buf.writeln(
        'The system identification procedure identified the feedforward model '
        'for a **${config.type.displayName}** mechanism with '
        'kS = ${ff.kS.toStringAsFixed(4)} V, '
        'kV = ${ff.kV.toStringAsFixed(4)} V·s/${config.positionUnit}, '
        'and kA = ${ff.kA.toStringAsFixed(4)} V·s²/${config.positionUnit}.');
    buf.writeln();
    buf.writeln(
        '- **kS = ${ff.kS.toStringAsFixed(4)} V** — static friction overcome at this voltage.');
    buf.writeln(
        '- **kV = ${ff.kV.toStringAsFixed(4)} V·s/${config.positionUnit}** — '
        'voltage per unit velocity; higher values indicate more back-EMF resistance.');
    buf.writeln(
        '- **kA = ${ff.kA.toStringAsFixed(4)} V·s²/${config.positionUnit}** — '
        'voltage per unit acceleration; reflects rotational inertia.');
    if (config.type.hasGravity) {
      buf.writeln(
          '- **kG = ${ff.kG.toStringAsFixed(4)} V** — gravity compensation voltage.');
    }
    buf.writeln();
    buf.writeln(
        "*Generated by Crumboe's (unofficial) REV System Identification tool.*");

    return buf.toString();
  }

  static String _modelEquation(MechanismType type) {
    switch (type) {
      case MechanismType.arm:
        return 'V = kS·sign(ω) + kV·ω + kA·α + kG·cos(θ)';
      case MechanismType.elevator:
        return 'V = kS·sign(ω) + kV·ω + kA·α + kG';
      default:
        return 'V = kS·sign(ω) + kV·ω + kA·α';
    }
  }
}
