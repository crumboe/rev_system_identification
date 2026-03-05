/// PDF report generator for system identification results.
///
/// Produces a one-page summary with mechanism configuration, computed
/// feedforward and PID gains, test run statistics, and validation metrics.
/// Useful for FRC engineering notebooks.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../mechanisms/mechanism.dart';
import '../sysid/validation_runner.dart';
import 'test_data.dart';

/// Generates a PDF report summarising system identification results.
class ReportGenerator {
  /// Generate and save a PDF report.
  ///
  /// Returns the file path if saved successfully, or null if the user cancelled.
  static Future<String?> generate({
    required MechanismConfig config,
    required FeedforwardGains ff,
    PidResult? velocityPid,
    PidResult? positionPid,
    List<TestRun> testRuns = const [],
    ValidationResult? validationResult,
  }) async {
    final path = await _pickSavePath(config);
    if (path == null) return null;

    final pdf = pw.Document(
      title: 'SysID Report - ${config.type.displayName}',
      author: 'REV System Identification',
    );

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.letter,
        margin: const pw.EdgeInsets.all(40),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _buildHeader(config),
            pw.SizedBox(height: 16),
            _buildMechanismSection(config),
            pw.SizedBox(height: 14),
            _buildFeedforwardSection(ff, config),
            pw.SizedBox(height: 14),
            _buildPidSection(velocityPid, positionPid, config),
            if (testRuns.isNotEmpty) ...[
              pw.SizedBox(height: 14),
              _buildTestSummarySection(testRuns),
            ],
            if (validationResult != null) ...[
              pw.SizedBox(height: 14),
              _buildValidationSection(validationResult, config),
            ],
            pw.Spacer(),
            _buildFooter(),
          ],
        ),
      ),
    );

    final bytes = await pdf.save();
    await File(path).writeAsBytes(bytes);
    return path;
  }

  // ---------------------------------------------------------------------------
  // Section builders
  // ---------------------------------------------------------------------------

  static pw.Widget _buildHeader(MechanismConfig config) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'System Identification Report',
          style: pw.TextStyle(
            fontSize: 22,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 4),
        pw.Text(
          '${config.type.displayName} - '
          '${DateTime.now().toLocal().toString().split('.').first}',
          style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
        ),
        pw.Divider(thickness: 1.5),
      ],
    );
  }

  static pw.Widget _buildMechanismSection(MechanismConfig config) {
    return _section(
      'Mechanism Configuration',
      pw.Table(
        columnWidths: {
          0: const pw.FixedColumnWidth(180),
          1: const pw.FlexColumnWidth(),
        },
        children: [
          _tableRow('Mechanism Type', config.type.displayName),
          _tableRow('Gear Ratio', '${config.gearRatio}:1'),
          _tableRow('Position Conv. Factor',
              '${config.positionConversionFactor.toStringAsFixed(6)} '
              'rot -> ${config.positionUnit}'),
          _tableRow('Velocity Conv. Factor',
              '${config.velocityConversionFactor.toStringAsFixed(6)} '
              'RPM -> ${config.velocityUnit}'),
          _tableRow('Motor Type',
              config.isBrushless ? 'Brushless' : 'Brushed'),
          _tableRow('Motor Inverted', config.motorInverted ? 'Yes' : 'No'),
          _tableRow('Current Limit', '${config.currentLimitAmps} A'),
          if (config.forwardSoftLimit != null)
            _tableRow('Forward Soft Limit',
                '${config.forwardSoftLimit!.toStringAsFixed(2)} ${config.positionUnit}'),
          if (config.reverseSoftLimit != null)
            _tableRow('Reverse Soft Limit',
                '${config.reverseSoftLimit!.toStringAsFixed(2)} ${config.positionUnit}'),
        ],
      ),
    );
  }

  static pw.Widget _buildFeedforwardSection(
      FeedforwardGains ff, MechanismConfig config) {
    final velUnit = config.velocityUnit;
    final posUnit = config.positionUnit;

    final rows = <pw.TableRow>[
      _gainsHeaderRow(),
      _gainsRow('kS', ff.kS, 'V', 'Static friction voltage'),
      _gainsRow('kV', ff.kV, 'V*s/$velUnit', 'Velocity gain'),
      _gainsRow('kA', ff.kA, 'V*s^2/$velUnit', 'Acceleration gain'),
    ];

    if (config.type == MechanismType.arm) {
      rows.add(_gainsRow(
          'kG (cos)', ff.kG, 'V', 'Gravity compensation (arm)'));
    } else if (config.type == MechanismType.elevator) {
      rows.add(
          _gainsRow('kG', ff.kG, 'V', 'Gravity compensation (elevator)'));
    }

    rows.add(_gainsRow('R^2', ff.rSquared, '', 'Goodness of fit'));

    return _section(
      'Feedforward Constants',
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        columnWidths: {
          0: const pw.FixedColumnWidth(60),
          1: const pw.FixedColumnWidth(100),
          2: const pw.FixedColumnWidth(90),
          3: const pw.FlexColumnWidth(),
        },
        children: rows,
      ),
    );
  }

  static pw.Widget _buildPidSection(
      PidResult? velPid, PidResult? posPid, MechanismConfig config) {
    final children = <pw.Widget>[];

    if (velPid != null) {
      children.add(pw.Text('Velocity PID',
          style: pw.TextStyle(
              fontSize: 11, fontWeight: pw.FontWeight.bold)));
      children.add(pw.SizedBox(height: 4));
      children.add(pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        columnWidths: {
          0: const pw.FixedColumnWidth(60),
          1: const pw.FixedColumnWidth(120),
          2: const pw.FlexColumnWidth(),
        },
        children: [
          _pidHeaderRow(),
          _pidRow('kP', velPid.kP),
          _pidRow('kI', velPid.kI),
          _pidRow('kD', velPid.kD),
        ],
      ));
      if (velPid.velocityTimeConstantMs != null) {
        children.add(pw.SizedBox(height: 2));
        children.add(pw.Text(
          'Tuning: tau = ${velPid.velocityTimeConstantMs!.toStringAsFixed(0)} ms',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
        ));
      }
    }

    if (posPid != null) {
      if (velPid != null) children.add(pw.SizedBox(height: 8));
      children.add(pw.Text('Position PID',
          style: pw.TextStyle(
              fontSize: 11, fontWeight: pw.FontWeight.bold)));
      children.add(pw.SizedBox(height: 4));
      children.add(pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        columnWidths: {
          0: const pw.FixedColumnWidth(60),
          1: const pw.FixedColumnWidth(120),
          2: const pw.FlexColumnWidth(),
        },
        children: [
          _pidHeaderRow(),
          _pidRow('kP', posPid.kP),
          _pidRow('kI', posPid.kI),
          _pidRow('kD', posPid.kD),
        ],
      ));
      if (posPid.positionBandwidthHz != null) {
        children.add(pw.SizedBox(height: 2));
        children.add(pw.Text(
          'Tuning: w = ${posPid.positionBandwidthHz!.toStringAsFixed(1)} Hz',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
        ));
      }
    }

    if (children.isEmpty) {
      children.add(pw.Text('No PID gains computed.',
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600)));
    }

    return _section('PID Gains', pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: children,
    ));
  }

  static pw.Widget _buildTestSummarySection(List<TestRun> runs) {
    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey200),
        children: [
          _cell('Test Type', bold: true),
          _cell('Samples', bold: true),
          _cell('Duration (s)', bold: true),
          _cell('Sample Rate (Hz)', bold: true),
        ],
      ),
    ];

    for (final run in runs) {
      rows.add(pw.TableRow(children: [
        _cell(run.testType.displayName),
        _cell('${run.sampleCount}'),
        _cell(run.durationSeconds.toStringAsFixed(1)),
        _cell(run.sampleRate.toStringAsFixed(0)),
      ]));
    }

    return _section(
      'Test Runs',
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        columnWidths: {
          0: const pw.FlexColumnWidth(2),
          1: const pw.FixedColumnWidth(70),
          2: const pw.FixedColumnWidth(80),
          3: const pw.FixedColumnWidth(90),
        },
        children: rows,
      ),
    );
  }

  static pw.Widget _buildValidationSection(
      ValidationResult vr, MechanismConfig config) {
    final modeLabel = switch (vr.mode) {
      ValidationMode.velocity => 'Velocity Step',
      ValidationMode.position => 'Position Step',
      ValidationMode.maxMotionPosition => 'MAXMotion Position',
    };

    final rows = <pw.TableRow>[
      _tableRow('Mode', modeLabel),
      _tableRow('Completed', vr.completed ? 'Yes' : 'No'),
      _tableRow('Samples', '${vr.data.length}'),
      _tableRow('Duration', '${vr.durationSeconds.toStringAsFixed(1)} s'),
    ];

    if (vr.riseTime != null) {
      rows.add(_tableRow('Rise Time',
          '${(vr.riseTime! * 1000).toStringAsFixed(0)} ms'));
    }
    if (vr.overshootPercent != null) {
      rows.add(_tableRow(
          'Overshoot', '${vr.overshootPercent!.toStringAsFixed(1)}%'));
    }
    if (vr.steadyStateError != null) {
      rows.add(_tableRow(
          'Steady-State Error', vr.steadyStateError!.toStringAsFixed(4)));
    }
    if (vr.error != null) {
      rows.add(_tableRow('Error', vr.error!));
    }

    return _section(
      'Validation Results',
      pw.Table(
        columnWidths: {
          0: const pw.FixedColumnWidth(140),
          1: const pw.FlexColumnWidth(),
        },
        children: rows,
      ),
    );
  }

  static pw.Widget _buildFooter() {
    return pw.Column(
      children: [
        pw.Divider(thickness: 0.5),
        pw.SizedBox(height: 4),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'Generated by REV System Identification',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey500),
            ),
            pw.Text(
              DateTime.now().toLocal().toString().split('.').first,
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey500),
            ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static pw.Widget _section(String title, pw.Widget child) {
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          title,
          style: pw.TextStyle(
            fontSize: 14,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.blueGrey800,
          ),
        ),
        pw.SizedBox(height: 6),
        child,
      ],
    );
  }

  static pw.TableRow _tableRow(String label, String value) {
    return pw.TableRow(children: [
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        child: pw.Text(label,
            style: pw.TextStyle(
                fontSize: 10, fontWeight: pw.FontWeight.bold)),
      ),
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2, horizontal: 4),
        child: pw.Text(value, style: const pw.TextStyle(fontSize: 10)),
      ),
    ]);
  }

  static pw.TableRow _gainsHeaderRow() {
    return pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColors.grey200),
      children: [
        _cell('Gain', bold: true),
        _cell('Value', bold: true),
        _cell('Unit', bold: true),
        _cell('Description', bold: true),
      ],
    );
  }

  static pw.TableRow _gainsRow(
      String name, double value, String unit, String desc) {
    return pw.TableRow(children: [
      _cell(name, bold: true),
      _cell(value.toStringAsFixed(6), mono: true),
      _cell(unit),
      _cell(desc),
    ]);
  }

  static pw.TableRow _pidHeaderRow() {
    return pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColors.grey200),
      children: [
        _cell('Gain', bold: true),
        _cell('Value', bold: true),
        _cell('Description', bold: true),
      ],
    );
  }

  static pw.TableRow _pidRow(String name, double value) {
    final desc = switch (name) {
      'kP' => 'Proportional',
      'kI' => 'Integral',
      'kD' => 'Derivative',
      _ => '',
    };
    return pw.TableRow(children: [
      _cell(name, bold: true),
      _cell(value.toStringAsFixed(6), mono: true),
      _cell(desc),
    ]);
  }

  static pw.Widget _cell(String text,
      {bool bold = false, bool mono = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: 10,
          fontWeight: bold ? pw.FontWeight.bold : null,
          font: mono ? pw.Font.courier() : null,
        ),
      ),
    );
  }

  static Future<String?> _pickSavePath(MechanismConfig config) async {
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final name = 'sysid_report_${config.type.name}_$timestamp.pdf';

    return FilePicker.platform.saveFile(
      dialogTitle: 'Save PDF Report',
      fileName: name,
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
  }
}
