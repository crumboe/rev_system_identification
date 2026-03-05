/// PDF report generator for system identification results.
///
/// Produces a one-page summary with mechanism configuration, computed
/// feedforward and PID gains, test run statistics, and validation metrics.
/// Useful for FRC engineering notebooks.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../mechanisms/mechanism.dart';
import '../sysid/validation_runner.dart';
import '../ui/widgets/bode_plot.dart';
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

    // ── Page 2: Diagnostic Plots ──────────────────────────────────────
    final qsRuns = testRuns.where((r) => r.testType.isQuasistatic).toList();
    final dynRuns = testRuns.where((r) => r.testType.isDynamic).toList();
    final hasPlotData = testRuns.isNotEmpty;
    final hasBode = ff.kA > 0 && ff.kV > 0;

    if (hasPlotData || hasBode) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(40),
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Diagnostic Plots',
                style: pw.TextStyle(
                    fontSize: 18, fontWeight: pw.FontWeight.bold),
              ),
              pw.Divider(thickness: 1),
              pw.SizedBox(height: 8),
              if (hasPlotData)
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Expanded(
                      child: _buildModelFitChart(
                        [...qsRuns, ...dynRuns],
                        ff,
                        config.type,
                      ),
                    ),
                    pw.SizedBox(width: 12),
                    pw.Expanded(
                      child: _buildStepResponseChart(dynRuns),
                    ),
                  ],
                ),
              if (hasPlotData) pw.SizedBox(height: 16),
              if (hasBode) ...[
                pw.Text(
                  'Frequency Response (Bode Plot)',
                  style: pw.TextStyle(
                      fontSize: 14,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.blueGrey800),
                ),
                pw.SizedBox(height: 6),
                // Velocity Bode
                if (velocityPid != null) ...[
                  pw.Text('Velocity Loop',
                      style: pw.TextStyle(
                          fontSize: 11, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 4),
                  _buildBodePdfPlot(ff, velocityPid, BodePlotMode.velocity),
                  pw.SizedBox(height: 10),
                ],
                // Position Bode
                if (positionPid != null) ...[
                  pw.Text('Position Loop',
                      style: pw.TextStyle(
                          fontSize: 11, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 4),
                  _buildBodePdfPlot(ff, positionPid, BodePlotMode.position),
                ],
              ],
              pw.Spacer(),
              _buildFooter(),
            ],
          ),
        ),
      );
    }

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

  // ---------------------------------------------------------------------------
  // Diagnostic plot builders (Page 2)
  // ---------------------------------------------------------------------------

  /// Draw a simplified model-fit scatter plot (predicted vs actual voltage).
  static pw.Widget _buildModelFitChart(
    List<TestRun> testRuns,
    FeedforwardGains ff,
    MechanismType mechanismType,
  ) {
    // Collect predicted vs actual voltage pairs
    final points = <_PdfPoint>[];
    for (final run in testRuns) {
      final data = run.data;
      for (var i = 0; i < data.length; i++) {
        final dp = data[i];
        if (dp.velocity.abs() < 1e-6) continue;
        final prev = i > 0 ? data[i - 1] : null;
        final signVel = dp.velocity > 0 ? 1.0 : -1.0;
        double accel = 0.0;
        if (prev != null) {
          final dt = dp.timestamp - prev.timestamp;
          if (dt > 0) accel = (dp.velocity - prev.velocity) / dt;
        }
        double gravity = 0.0;
        if (mechanismType == MechanismType.arm) {
          gravity = math.cos(dp.position * math.pi / 180.0);
        } else if (mechanismType == MechanismType.elevator) {
          gravity = 1.0;
        }
        final predicted = ff.kS * signVel +
            ff.kV * dp.velocity.abs() +
            ff.kA * accel +
            ff.kG * gravity;
        points.add(_PdfPoint(predicted, dp.voltage));
      }
    }

    if (points.isEmpty) {
      return pw.Text('No data for model fit chart.',
          style: const pw.TextStyle(fontSize: 9));
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('Predicted vs Actual Voltage',
            style: pw.TextStyle(
                fontSize: 11, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.SizedBox(
          height: 140,
          child: pw.CustomPaint(
            size: const PdfPoint(240, 140),
            painter: (canvas, size) =>
                _drawScatterPlot(canvas, size, points),
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          'R\u00b2 = ${ff.rSquared.toStringAsFixed(4)}  '
          '(${points.length} data points)',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
        ),
      ],
    );
  }

  /// Draw a simplified step response chart.
  static pw.Widget _buildStepResponseChart(List<TestRun> dynRuns) {
    if (dynRuns.isEmpty) {
      return pw.Text('No dynamic test data.',
          style: const pw.TextStyle(fontSize: 9));
    }

    final allPoints = <List<_PdfPoint>>[];
    for (final run in dynRuns) {
      final pts = run.data
          .map((dp) => _PdfPoint(dp.timestamp, dp.velocity))
          .toList();
      if (pts.isNotEmpty) allPoints.add(pts);
    }

    if (allPoints.isEmpty) {
      return pw.Text('No step response data.',
          style: const pw.TextStyle(fontSize: 9));
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('Step Response (Dynamic)',
            style: pw.TextStyle(
                fontSize: 11, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.SizedBox(
          height: 140,
          child: pw.CustomPaint(
            size: const PdfPoint(240, 140),
            painter: (canvas, size) =>
                _drawMultiLineChart(canvas, size, allPoints,
                    xLabel: 'Time (s)', yLabel: 'Velocity'),
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          '${dynRuns.length} dynamic run(s)',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
        ),
      ],
    );
  }

  /// Build the Bode plot section for PDF.
  static pw.Widget _buildBodePdfPlot(
    FeedforwardGains ff,
    PidResult pid,
    BodePlotMode mode,
  ) {
    final data = computeBodeData(
      ff: ff,
      pid: pid,
      mode: mode,
      numPoints: 200,
    );

    final m = data.margins;
    final gm = m.gainMarginDb.isInfinite
        ? '\u221e'
        : '${m.gainMarginDb.toStringAsFixed(1)} dB';
    final pm = m.phaseMarginDeg.isInfinite
        ? '\u221e'
        : '${m.phaseMarginDeg.toStringAsFixed(1)}\u00b0';
    final bw = m.bandwidthRadPerSec > 0
        ? '${(m.bandwidthRadPerSec / (2 * math.pi)).toStringAsFixed(1)} Hz'
        : '\u2014';

    // Convert frequency response to plottable points
    final plantMag = data.plant
        .map((d) => _PdfPoint(
            math.log(d.omegaRadPerSec / (2 * math.pi)) / math.ln10,
            d.magnitudeDb))
        .toList();
    final olMag = data.openLoop
        .map((d) => _PdfPoint(
            math.log(d.omegaRadPerSec / (2 * math.pi)) / math.ln10,
            d.magnitudeDb))
        .toList();
    final clMag = data.closedLoop
        .map((d) => _PdfPoint(
            math.log(d.omegaRadPerSec / (2 * math.pi)) / math.ln10,
            d.magnitudeDb))
        .toList();

    final plantPhase = data.plant
        .map((d) => _PdfPoint(
            math.log(d.omegaRadPerSec / (2 * math.pi)) / math.ln10,
            d.phaseDeg))
        .toList();
    final olPhase = data.openLoop
        .map((d) => _PdfPoint(
            math.log(d.omegaRadPerSec / (2 * math.pi)) / math.ln10,
            d.phaseDeg))
        .toList();

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('Magnitude (dB)',
                      style: const pw.TextStyle(fontSize: 9)),
                  pw.SizedBox(height: 2),
                  pw.SizedBox(
                    height: 110,
                    child: pw.CustomPaint(
                      size: const PdfPoint(230, 110),
                      painter: (canvas, size) => _drawBodeChart(
                        canvas,
                        size,
                        [plantMag, olMag, clMag],
                        [PdfColors.blue, PdfColors.orange, PdfColors.green],
                        zeroLine: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            pw.SizedBox(width: 12),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('Phase (\u00b0)',
                      style: const pw.TextStyle(fontSize: 9)),
                  pw.SizedBox(height: 2),
                  pw.SizedBox(
                    height: 110,
                    child: pw.CustomPaint(
                      size: const PdfPoint(230, 110),
                      painter: (canvas, size) => _drawBodeChart(
                        canvas,
                        size,
                        [plantPhase, olPhase],
                        [PdfColors.blue, PdfColors.orange],
                        zeroLine: -180,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        pw.SizedBox(height: 4),
        pw.Row(
          children: [
            _pdfLegendDot(PdfColors.blue, 'Plant G(s)'),
            pw.SizedBox(width: 12),
            _pdfLegendDot(PdfColors.orange, 'Open-Loop L(s)'),
            pw.SizedBox(width: 12),
            _pdfLegendDot(PdfColors.green, 'Closed-Loop T(s)'),
          ],
        ),
        pw.SizedBox(height: 4),
        pw.Container(
          padding: const pw.EdgeInsets.all(6),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(3)),
            color: PdfColors.grey100,
          ),
          child: pw.Text(
            'Gain Margin: $gm  \u2022  Phase Margin: $pm  \u2022  Bandwidth: $bw',
            style: const pw.TextStyle(fontSize: 9),
          ),
        ),
      ],
    );
  }

  static pw.Widget _pdfLegendDot(PdfColor color, String label) {
    return pw.Row(
      mainAxisSize: pw.MainAxisSize.min,
      children: [
        pw.Container(
          width: 8,
          height: 3,
          decoration: pw.BoxDecoration(color: color),
        ),
        pw.SizedBox(width: 3),
        pw.Text(label, style: const pw.TextStyle(fontSize: 8)),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Low-level PDF chart drawing helpers
  // ---------------------------------------------------------------------------

  static void _drawScatterPlot(
    PdfGraphics canvas,
    PdfPoint size,
    List<_PdfPoint> points,
  ) {
    const margin = 20.0;
    final plotW = size.x - margin * 2;
    final plotH = size.y - margin * 2;

    // Find data range
    final xVals = points.map((p) => p.x);
    final yVals = points.map((p) => p.y);
    var xMin = xVals.reduce(math.min);
    var xMax = xVals.reduce(math.max);
    var yMin = yVals.reduce(math.min);
    var yMax = yVals.reduce(math.max);
    if (xMax == xMin) xMax = xMin + 1;
    if (yMax == yMin) yMax = yMin + 1;

    // Draw axes
    canvas
      ..setStrokeColor(PdfColors.grey600)
      ..setLineWidth(0.5)
      ..drawLine(margin, margin, margin, size.y - margin)
      ..strokePath()
      ..drawLine(margin, margin, size.x - margin, margin)
      ..strokePath();

    // Draw y=x reference line (green)
    canvas
      ..setStrokeColor(PdfColors.green)
      ..setLineWidth(0.5);
    final lo = math.max(xMin, yMin);
    final hi = math.min(xMax, yMax);
    if (hi > lo) {
      final x1 = margin + (lo - xMin) / (xMax - xMin) * plotW;
      final y1 = margin + (lo - yMin) / (yMax - yMin) * plotH;
      final x2 = margin + (hi - xMin) / (xMax - xMin) * plotW;
      final y2 = margin + (hi - yMin) / (yMax - yMin) * plotH;
      canvas
        ..drawLine(x1, y1, x2, y2)
        ..strokePath();
    }

    // Draw scatter points (subsample if too many)
    canvas
      ..setColor(PdfColors.blue400)
      ..setStrokeColor(PdfColors.blue400)
      ..setLineWidth(0.3);
    final step = points.length > 500 ? (points.length / 500).ceil() : 1;
    for (var i = 0; i < points.length; i += step) {
      final p = points[i];
      final px = margin + (p.x - xMin) / (xMax - xMin) * plotW;
      final py = margin + (p.y - yMin) / (yMax - yMin) * plotH;
      canvas
        ..drawRect(px - 0.5, py - 0.5, 1, 1)
        ..strokePath();
    }
  }

  static void _drawMultiLineChart(
    PdfGraphics canvas,
    PdfPoint size,
    List<List<_PdfPoint>> series, {
    String xLabel = '',
    String yLabel = '',
  }) {
    const margin = 20.0;
    final plotW = size.x - margin * 2;
    final plotH = size.y - margin * 2;

    final allX = series.expand((s) => s.map((p) => p.x));
    final allY = series.expand((s) => s.map((p) => p.y));
    var xMin = allX.reduce(math.min);
    var xMax = allX.reduce(math.max);
    var yMin = allY.reduce(math.min);
    var yMax = allY.reduce(math.max);
    if (xMax == xMin) xMax = xMin + 1;
    if (yMax == yMin) yMax = yMin + 1;

    // Axes
    canvas
      ..setStrokeColor(PdfColors.grey600)
      ..setLineWidth(0.5)
      ..drawLine(margin, margin, margin, size.y - margin)
      ..strokePath()
      ..drawLine(margin, margin, size.x - margin, margin)
      ..strokePath();

    final colors = [PdfColors.orange, PdfColors.teal, PdfColors.purple];
    for (var si = 0; si < series.length; si++) {
      final pts = series[si];
      if (pts.length < 2) continue;
      canvas
        ..setStrokeColor(colors[si % colors.length])
        ..setLineWidth(0.8);
      final first = pts.first;
      canvas.moveTo(
        margin + (first.x - xMin) / (xMax - xMin) * plotW,
        margin + (first.y - yMin) / (yMax - yMin) * plotH,
      );
      for (var i = 1; i < pts.length; i++) {
        final p = pts[i];
        canvas.lineTo(
          margin + (p.x - xMin) / (xMax - xMin) * plotW,
          margin + (p.y - yMin) / (yMax - yMin) * plotH,
        );
      }
      canvas.strokePath();
    }
  }

  static void _drawBodeChart(
    PdfGraphics canvas,
    PdfPoint size,
    List<List<_PdfPoint>> series,
    List<PdfColor> colors, {
    double? zeroLine,
  }) {
    const margin = 20.0;
    final plotW = size.x - margin * 2;
    final plotH = size.y - margin * 2;

    final allX = series.expand((s) => s.map((p) => p.x));
    final allY = series.expand((s) => s.map((p) => p.y));
    var xMin = allX.reduce(math.min);
    var xMax = allX.reduce(math.max);
    var yMin = allY.reduce(math.min);
    var yMax = allY.reduce(math.max);
    if (xMax == xMin) xMax = xMin + 1;
    if (yMax == yMin) yMax = yMin + 1;
    // Add small padding
    final yPad = (yMax - yMin) * 0.05;
    yMin -= yPad;
    yMax += yPad;

    // Axes
    canvas
      ..setStrokeColor(PdfColors.grey600)
      ..setLineWidth(0.5)
      ..drawLine(margin, margin, margin, size.y - margin)
      ..strokePath()
      ..drawLine(margin, margin, size.x - margin, margin)
      ..strokePath();

    // Zero/reference line
    if (zeroLine != null && zeroLine >= yMin && zeroLine <= yMax) {
      final zy = margin + (zeroLine - yMin) / (yMax - yMin) * plotH;
      canvas
        ..setStrokeColor(PdfColors.grey400)
        ..setLineWidth(0.3)
        ..drawLine(margin, zy, size.x - margin, zy)
        ..strokePath();
    }

    // Draw grid: 3 horizontal lines
    canvas.setStrokeColor(PdfColors.grey200);
    canvas.setLineWidth(0.2);
    for (var i = 1; i <= 3; i++) {
      final fy = margin + plotH * i / 4;
      canvas
        ..drawLine(margin, fy, size.x - margin, fy)
        ..strokePath();
    }

    // Draw series
    for (var si = 0; si < series.length; si++) {
      final pts = series[si];
      if (pts.length < 2) continue;
      canvas
        ..setStrokeColor(colors[si % colors.length])
        ..setLineWidth(si == 0 ? 0.6 : 1.0);
      final first = pts.first;
      canvas.moveTo(
        margin + (first.x - xMin) / (xMax - xMin) * plotW,
        margin + (first.y - yMin) / (yMax - yMin) * plotH,
      );
      for (var i = 1; i < pts.length; i++) {
        final p = pts[i];
        canvas.lineTo(
          margin + (p.x - xMin) / (xMax - xMin) * plotW,
          margin + (p.y - yMin) / (yMax - yMin) * plotH,
        );
      }
      canvas.strokePath();
    }
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

/// Simple 2D point for PDF chart drawing.
class _PdfPoint {
  final double x, y;
  const _PdfPoint(this.x, this.y);
}
