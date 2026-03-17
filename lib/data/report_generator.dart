/// PDF report generator for system identification results.
///
/// Produces a one-page summary with mechanism configuration, computed
/// feedforward and PID gains, test run statistics, and validation metrics.
/// Useful for FRC engineering notebooks.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'file_saver.dart';

import 'package:file_picker/file_picker.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../mechanisms/mechanism.dart';
import '../state/app_state.dart';
import '../sysid/validation_runner.dart';
import '../ui/widgets/bode_plot.dart';
import '../ui/widgets/pole_zero_map.dart';
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
    PidTuningParams tuningParams = const PidTuningParams(),
  }) async {
    final path = await _pickSavePath(config);
    if (path == null) return null; // user cancelled (desktop only)

    final pdf = pw.Document(
      title: 'SysID Report - ${config.type.displayName}',
      author: "Crumboe's (unofficial) REV System Identification",
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
            _buildPidSection(velocityPid, positionPid, config, tuningParams),
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

    // Create a font for chart tick labels (base-14 Helvetica).
    final chartFont = PdfFont.helvetica(pdf.document);

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
                        chartFont,
                      ),
                    ),
                    pw.SizedBox(width: 12),
                    pw.Expanded(
                      child: _buildStepResponseChart(dynRuns, chartFont),
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
                  _buildBodePdfPlot(
                      ff, velocityPid, BodePlotMode.velocity, chartFont),
                  pw.SizedBox(height: 10),
                ],
                // Position Bode
                if (positionPid != null) ...[
                  pw.Text('Position Loop',
                      style: pw.TextStyle(
                          fontSize: 11, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 4),
                  _buildBodePdfPlot(
                      ff, positionPid, BodePlotMode.position, chartFont),
                ],
              ],
              pw.Spacer(),
              _buildFooter(),
            ],
          ),
        ),
      );
    }

    // ── Page 3: Pole-Zero Map ─────────────────────────────────────────
    if (hasBode && (velocityPid != null || positionPid != null)) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.letter,
          margin: const pw.EdgeInsets.all(40),
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Pole-Zero Map (s-Plane)',
                style: pw.TextStyle(
                    fontSize: 18, fontWeight: pw.FontWeight.bold),
              ),
              pw.Divider(thickness: 1),
              pw.SizedBox(height: 8),
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (velocityPid != null)
                    pw.Expanded(
                      child: _buildPoleZeroPdfPlot(
                          ff, velocityPid, PoleZeroMode.velocity, chartFont,
                          config.type),
                    ),
                  if (velocityPid != null && positionPid != null)
                    pw.SizedBox(width: 16),
                  if (positionPid != null)
                    pw.Expanded(
                      child: _buildPoleZeroPdfPlot(
                          ff, positionPid, PoleZeroMode.position, chartFont,
                          config.type),
                    ),
                ],
              ),
              pw.Spacer(),
              _buildFooter(),
            ],
          ),
        ),
      );
    }

    final bytes = await pdf.save();
    await writeFileBytes(path, bytes);
    return path;
  }

  // ---------------------------------------------------------------------------
  // Section builders
  // ---------------------------------------------------------------------------

  static pw.Widget _buildHeader(MechanismConfig config) {
    final title = config.systemName.isNotEmpty
        ? config.systemName
        : config.type.displayName;
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
          '$title - '
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
          if (config.systemName.isNotEmpty)
            _tableRow('System Name', config.systemName),
          _tableRow('Mechanism Type', config.type.displayName),
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
      PidResult? velPid, PidResult? posPid, MechanismConfig config,
      PidTuningParams tuningParams) {
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
      children.add(pw.SizedBox(height: 2));
      children.add(pw.Text(
        'Tuning: tau = ${tuningParams.velocityTimeConstantMs.toStringAsFixed(0)} ms',
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
      ));
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
      children.add(pw.SizedBox(height: 2));
      children.add(pw.Text(
        'Tuning: w = ${tuningParams.positionBandwidthHz.toStringAsFixed(1)} Hz, '
        'z = ${tuningParams.dampingRatio.toStringAsFixed(3)} '
        '(${_dampingLabel(tuningParams.dampingRatio)})',
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
      ));
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
              "Generated by Crumboe's (unofficial) REV System Identification",
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
    PdfFont chartFont,
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
          height: 160,
          child: pw.CustomPaint(
            size: const PdfPoint(240, 160),
            painter: (canvas, size) =>
                _drawScatterPlot(canvas, size, points, chartFont),
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          'R2 = ${ff.rSquared.toStringAsFixed(4)}  '
          '(${points.length} data points)',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600),
        ),
      ],
    );
  }

  /// Draw a simplified step response chart.
  static pw.Widget _buildStepResponseChart(
      List<TestRun> dynRuns, PdfFont chartFont) {
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
          height: 160,
          child: pw.CustomPaint(
            size: const PdfPoint(240, 160),
            painter: (canvas, size) =>
                _drawMultiLineChart(canvas, size, allPoints, chartFont,
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
    PdfFont chartFont,
  ) {
    final data = computeBodeData(
      ff: ff,
      pid: pid,
      mode: mode,
      numPoints: 200,
    );

    final m = data.margins;
    final gm = m.gainMarginDb.isInfinite
        ? 'Inf'
        : '${m.gainMarginDb.toStringAsFixed(1)} dB';
    final pm = m.phaseMarginDeg.isInfinite
        ? 'Inf'
        : '${m.phaseMarginDeg.toStringAsFixed(1)} deg';
    final bw = m.bandwidthRadPerSec > 0
        ? '${(m.bandwidthRadPerSec / (2 * math.pi)).toStringAsFixed(1)} Hz'
        : 'N/A';

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
                        chartFont,
                        yAxisLabel: 'dB',
                        zeroLine: 0,
                      ),
                    ),
                  ),
                  pw.Center(
                    child: pw.Text('Frequency (Hz)',
                        style: const pw.TextStyle(
                            fontSize: 7, color: PdfColors.grey600)),
                  ),
                ],
              ),
            ),
            pw.SizedBox(width: 12),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('Phase (deg)',
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
                        chartFont,
                        yAxisLabel: 'deg',
                        zeroLine: -180,
                      ),
                    ),
                  ),
                  pw.Center(
                    child: pw.Text('Frequency (Hz)',
                        style: const pw.TextStyle(
                            fontSize: 7, color: PdfColors.grey600)),
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
            'Gain Margin: $gm  |  Phase Margin: $pm  |  Bandwidth: $bw',
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

  /// Human-readable label for a damping ratio value.
  static String _dampingLabel(double zeta) {
    if ((zeta - 1.5).abs() < 0.01) return 'Overdamped';
    if ((zeta - 1.0).abs() < 0.01) return 'Critically Damped';
    if ((zeta - 0.707).abs() < 0.01) return 'Butterworth';
    if ((zeta - 0.5).abs() < 0.01) return 'Underdamped';
    if (zeta > 1.0) return 'Overdamped';
    if (zeta > 0.707) return 'Slightly Underdamped';
    return 'Underdamped';
  }

  /// Format a number for tick labels — short and readable.
  static String _tickLabel(double v) {
    if (v.abs() >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
    if (v.abs() >= 100) return v.toStringAsFixed(0);
    if (v.abs() >= 1) return v.toStringAsFixed(1);
    if (v == 0) return '0';
    return v.toStringAsFixed(2);
  }

  /// Draw tick marks + labels at min, mid, max along an axis.
  static void _drawAxisTicks(
    PdfGraphics canvas,
    PdfFont font,
    double min,
    double max, {
    required double plotOriginX,
    required double plotOriginY,
    required double plotW,
    required double plotH,
    required bool isXAxis,
    bool isLogX = false,
  }) {
    canvas.setColor(PdfColors.grey600);
    final mid = (min + max) / 2;
    final values = [min, mid, max];
    for (final v in values) {
      final frac = (v - min) / (max - min);
      if (isXAxis) {
        final px = plotOriginX + frac * plotW;
        // Tick mark
        canvas
          ..setStrokeColor(PdfColors.grey400)
          ..setLineWidth(0.3)
          ..drawLine(px, plotOriginY, px, plotOriginY - 3)
          ..strokePath();
        // Label
        final label =
            isLogX ? '${math.pow(10, v).toStringAsFixed(0)}' : _tickLabel(v);
        canvas.drawString(font, 6, label, px - 6, plotOriginY - 12);
      } else {
        final py = plotOriginY + frac * plotH;
        canvas
          ..setStrokeColor(PdfColors.grey400)
          ..setLineWidth(0.3)
          ..drawLine(plotOriginX, py, plotOriginX - 3, py)
          ..strokePath();
        canvas.drawString(font, 6, _tickLabel(v), plotOriginX - 28, py - 2);
      }
    }
  }

  static void _drawScatterPlot(
    PdfGraphics canvas,
    PdfPoint size,
    List<_PdfPoint> points,
    PdfFont font,
  ) {
    const left = 42.0;
    const bottom = 28.0;
    const top = 6.0;
    const right = 6.0;
    final plotW = size.x - left - right;
    final plotH = size.y - bottom - top;

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
      ..drawLine(left, bottom, left, size.y - top)
      ..strokePath()
      ..drawLine(left, bottom, size.x - right, bottom)
      ..strokePath();

    // Tick labels
    _drawAxisTicks(canvas, font, xMin, xMax,
        plotOriginX: left, plotOriginY: bottom, plotW: plotW, plotH: plotH,
        isXAxis: true);
    _drawAxisTicks(canvas, font, yMin, yMax,
        plotOriginX: left, plotOriginY: bottom, plotW: plotW, plotH: plotH,
        isXAxis: false);

    // Axis name labels
    canvas
      ..setColor(PdfColors.grey700);
    canvas.drawString(
        font, 7, 'Predicted Voltage (V)', left + plotW / 2 - 35, 2);
    canvas.drawString(font, 6, 'Actual (V)', 0, bottom + plotH - 6);

    // Draw y=x reference line (green)
    canvas
      ..setStrokeColor(PdfColors.green)
      ..setLineWidth(0.5);
    final lo = math.max(xMin, yMin);
    final hi = math.min(xMax, yMax);
    if (hi > lo) {
      final x1 = left + (lo - xMin) / (xMax - xMin) * plotW;
      final y1 = bottom + (lo - yMin) / (yMax - yMin) * plotH;
      final x2 = left + (hi - xMin) / (xMax - xMin) * plotW;
      final y2 = bottom + (hi - yMin) / (yMax - yMin) * plotH;
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
      final px = left + (p.x - xMin) / (xMax - xMin) * plotW;
      final py = bottom + (p.y - yMin) / (yMax - yMin) * plotH;
      canvas
        ..drawRect(px - 0.5, py - 0.5, 1, 1)
        ..strokePath();
    }
  }

  static void _drawMultiLineChart(
    PdfGraphics canvas,
    PdfPoint size,
    List<List<_PdfPoint>> series,
    PdfFont font, {
    String xLabel = '',
    String yLabel = '',
  }) {
    const left = 42.0;
    const bottom = 28.0;
    const top = 6.0;
    const right = 6.0;
    final plotW = size.x - left - right;
    final plotH = size.y - bottom - top;

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
      ..drawLine(left, bottom, left, size.y - top)
      ..strokePath()
      ..drawLine(left, bottom, size.x - right, bottom)
      ..strokePath();

    // Tick labels
    _drawAxisTicks(canvas, font, xMin, xMax,
        plotOriginX: left, plotOriginY: bottom, plotW: plotW, plotH: plotH,
        isXAxis: true);
    _drawAxisTicks(canvas, font, yMin, yMax,
        plotOriginX: left, plotOriginY: bottom, plotW: plotW, plotH: plotH,
        isXAxis: false);

    // Axis name labels
    canvas.setColor(PdfColors.grey700);
    if (xLabel.isNotEmpty) {
      canvas.drawString(
          font, 7, xLabel, left + plotW / 2 - 15, 2);
    }
    if (yLabel.isNotEmpty) {
      canvas.drawString(font, 6, yLabel, 0, bottom + plotH - 6);
    }

    final colors = [PdfColors.orange, PdfColors.teal, PdfColors.purple];
    for (var si = 0; si < series.length; si++) {
      final pts = series[si];
      if (pts.length < 2) continue;
      canvas
        ..setStrokeColor(colors[si % colors.length])
        ..setLineWidth(0.8);
      final first = pts.first;
      canvas.moveTo(
        left + (first.x - xMin) / (xMax - xMin) * plotW,
        bottom + (first.y - yMin) / (yMax - yMin) * plotH,
      );
      for (var i = 1; i < pts.length; i++) {
        final p = pts[i];
        canvas.lineTo(
          left + (p.x - xMin) / (xMax - xMin) * plotW,
          bottom + (p.y - yMin) / (yMax - yMin) * plotH,
        );
      }
      canvas.strokePath();
    }
  }

  static void _drawBodeChart(
    PdfGraphics canvas,
    PdfPoint size,
    List<List<_PdfPoint>> series,
    List<PdfColor> colors,
    PdfFont font, {
    String yAxisLabel = '',
    double? zeroLine,
  }) {
    const left = 42.0;
    const bottom = 14.0;
    const top = 6.0;
    const right = 6.0;
    final plotW = size.x - left - right;
    final plotH = size.y - bottom - top;

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
      ..drawLine(left, bottom, left, size.y - top)
      ..strokePath()
      ..drawLine(left, bottom, size.x - right, bottom)
      ..strokePath();

    // Tick labels: X-axis (log frequency → Hz)
    _drawAxisTicks(canvas, font, xMin, xMax,
        plotOriginX: left, plotOriginY: bottom, plotW: plotW, plotH: plotH,
        isXAxis: true, isLogX: true);
    // Y-axis ticks
    _drawAxisTicks(canvas, font, yMin, yMax,
        plotOriginX: left, plotOriginY: bottom, plotW: plotW, plotH: plotH,
        isXAxis: false);

    // Y-axis unit label
    if (yAxisLabel.isNotEmpty) {
      canvas.setColor(PdfColors.grey700);
      canvas.drawString(font, 6, yAxisLabel, 0, bottom + plotH - 6);
    }

    // Zero/reference line
    if (zeroLine != null && zeroLine >= yMin && zeroLine <= yMax) {
      final zy = bottom + (zeroLine - yMin) / (yMax - yMin) * plotH;
      canvas
        ..setStrokeColor(PdfColors.grey400)
        ..setLineWidth(0.3)
        ..drawLine(left, zy, size.x - right, zy)
        ..strokePath();
    }

    // Draw grid: 3 horizontal lines
    canvas.setStrokeColor(PdfColors.grey200);
    canvas.setLineWidth(0.2);
    for (var i = 1; i <= 3; i++) {
      final fy = bottom + plotH * i / 4;
      canvas
        ..drawLine(left, fy, size.x - right, fy)
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
        left + (first.x - xMin) / (xMax - xMin) * plotW,
        bottom + (first.y - yMin) / (yMax - yMin) * plotH,
      );
      for (var i = 1; i < pts.length; i++) {
        final p = pts[i];
        canvas.lineTo(
          left + (p.x - xMin) / (xMax - xMin) * plotW,
          bottom + (p.y - yMin) / (yMax - yMin) * plotH,
        );
      }
      canvas.strokePath();
    }
  }

  // ---------------------------------------------------------------------------
  // Pole-Zero Plot for PDF
  // ---------------------------------------------------------------------------

  /// Build a pole-zero map section for a single loop mode.
  static pw.Widget _buildPoleZeroPdfPlot(
    FeedforwardGains ff,
    PidResult pid,
    PoleZeroMode mode,
    PdfFont chartFont,
    MechanismType mechanismType,
  ) {
    final poles = computeClosedLoopPoles(ff, pid, mode, mechanismType);
    final olPoles = computeOpenLoopPoles(ff, pid, mode);
    final modeLabel =
        mode == PoleZeroMode.velocity ? 'Velocity Loop' : 'Position Loop';

    // Summarise poles
    final allStable = poles.every((p) => p.isStable);
    final complexPoles = poles.where((p) => p.im.abs() > 1e-6).toList();
    String poleInfo = allStable ? 'Stable' : 'UNSTABLE';
    if (complexPoles.isNotEmpty) {
      final p = complexPoles.first;
      poleInfo +=
          '  |  wn=${p.wn.toStringAsFixed(1)} rad/s'
          '  |  zeta=${p.zeta.toStringAsFixed(3)}';
    }

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(modeLabel,
            style: pw.TextStyle(
                fontSize: 12, fontWeight: pw.FontWeight.bold)),
        pw.SizedBox(height: 4),
        pw.SizedBox(
          height: 260,
          child: pw.CustomPaint(
            size: const PdfPoint(260, 260),
            painter: (canvas, size) =>
                _drawPoleZeroChart(canvas, size, poles, olPoles, chartFont),
          ),
        ),
        pw.SizedBox(height: 4),
        // Pole list
        for (final p in poles)
          pw.Text(
            '  ${p.isStable ? "X" : "!"} ${p.toString()}'
            '${p.im.abs() > 1e-6 ? "  (wn=${p.wn.toStringAsFixed(1)}, z=${p.zeta.toStringAsFixed(2)})" : ""}',
            style: pw.TextStyle(
              fontSize: 8,
              color: p.isStable ? PdfColors.green800 : PdfColors.red800,
              font: pw.Font.courier(),
            ),
          ),
        pw.SizedBox(height: 4),
        pw.Container(
          padding: const pw.EdgeInsets.all(4),
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey400, width: 0.5),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(3)),
            color: PdfColors.grey100,
          ),
          child: pw.Text(poleInfo, style: const pw.TextStyle(fontSize: 8)),
        ),
      ],
    );
  }

  /// Draw the s-plane pole-zero chart with stability regions and damping lines.
  static void _drawPoleZeroChart(
    PdfGraphics canvas,
    PdfPoint size,
    List<PolePlotData> poles,
    List<PolePlotData> openLoopPoles,
    PdfFont font,
  ) {
    const left = 36.0;
    const bottom = 24.0;
    const top = 6.0;
    const right = 6.0;
    final plotW = size.x - left - right;
    final plotH = size.y - bottom - top;

    // Determine axis range from pole locations
    double maxAbs = 50.0;
    for (final p in poles) {
      final extent = math.max(p.re.abs(), p.im.abs());
      if (extent > maxAbs) maxAbs = extent * 1.3;
    }
    maxAbs = (maxAbs * 1.2).ceilToDouble();

    double toX(double re) => left + (re + maxAbs) / (2 * maxAbs) * plotW;
    double toY(double im) => bottom + (im + maxAbs) / (2 * maxAbs) * plotH;

    final originX = toX(0);
    final originY = toY(0);

    // ── Stability regions ─────────────────────────────────────────────
    // LHP (stable) — very faint green tint
    canvas
      ..setColor(const PdfColor(0.27, 0.67, 0.27, 0.04))
      ..drawRect(left, bottom, originX - left, plotH)
      ..fillPath();
    // RHP (unstable) — very faint red tint
    canvas
      ..setColor(const PdfColor(0.67, 0.27, 0.27, 0.04))
      ..drawRect(originX, bottom, left + plotW - originX, plotH)
      ..fillPath();

    // ── Grid lines ────────────────────────────────────────────────────
    canvas
      ..setStrokeColor(PdfColors.grey300)
      ..setLineWidth(0.2);
    final step = _pzGridStep(maxAbs);
    for (double v = -maxAbs; v <= maxAbs + step * 0.1; v += step) {
      if (v.abs() < step * 0.1) continue;
      final px = toX(v);
      final py = toY(v);
      canvas
        ..drawLine(px, bottom, px, bottom + plotH)
        ..strokePath()
        ..drawLine(left, py, left + plotW, py)
        ..strokePath();
    }

    // ── Axes (imaginary axis = stability boundary) ────────────────────
    canvas
      ..setStrokeColor(PdfColors.grey600)
      ..setLineWidth(0.8)
      ..drawLine(originX, bottom, originX, bottom + plotH)
      ..strokePath()
      ..drawLine(left, originY, left + plotW, originY)
      ..strokePath();

    // Axis tick labels
    canvas.setColor(PdfColors.grey600);
    for (double v = -maxAbs; v <= maxAbs + step * 0.1; v += step) {
      if (v.abs() < step * 0.1) continue;
      canvas.drawString(
          font, 6, v.toStringAsFixed(0), toX(v) - 4, bottom - 10);
      canvas.drawString(
          font, 6, v.toStringAsFixed(0), left - 26, toY(v) - 2);
    }

    // Axis name labels
    canvas
      ..setColor(PdfColors.grey700);
    canvas.drawString(font, 7, 'Re (1/s)', left + plotW - 28, originY + 3);
    canvas.drawString(font, 7, 'Im (rad/s)', originX + 3, bottom + plotH - 3);

    // ── Damping ratio lines ──────────────────────────────────────────
    canvas
      ..setStrokeColor(const PdfColor(0.5, 0.5, 0.5, 0.3))
      ..setLineWidth(0.5);
    for (final zeta in [0.3, 0.5, 0.707, 0.9]) {
      final theta = math.acos(zeta);
      final lineLen = maxAbs * 1.1;
      final reEnd = -lineLen * math.cos(theta);
      final imEnd = lineLen * math.sin(theta);
      // Upper + lower half
      canvas
        ..drawLine(originX, originY, toX(reEnd), toY(imEnd))
        ..strokePath()
        ..drawLine(originX, originY, toX(reEnd), toY(-imEnd))
        ..strokePath();
      // Label (upper only)
      final labelRe = reEnd * 0.65;
      final labelIm = imEnd * 0.65;
      canvas.setColor(const PdfColor(0.5, 0.5, 0.5, 0.5));
      final zetaStr = zeta == 0.707 ? '.707' : zeta.toString();
      canvas.drawString(font, 5, 'z=$zetaStr', toX(labelRe), toY(labelIm));
    }

    // ── Natural frequency arcs (LHP semicircles) ─────────────────────
    // Approximate semicircle with line segments
    final wnStep = _pzGridStep(maxAbs);
    canvas
      ..setStrokeColor(const PdfColor(0.4, 0.4, 0.4, 0.15))
      ..setLineWidth(0.4);
    for (double wn = wnStep; wn < maxAbs; wn += wnStep) {
      const segments = 40;
      for (var i = 0; i < segments; i++) {
        final a1 = math.pi / 2 + math.pi * i / segments;
        final a2 = math.pi / 2 + math.pi * (i + 1) / segments;
        canvas
          ..drawLine(
            toX(wn * math.cos(a1)),
            toY(wn * math.sin(a1)),
            toX(wn * math.cos(a2)),
            toY(wn * math.sin(a2)),
          )
          ..strokePath();
      }
    }

    // ── Open-loop poles (O markers) ───────────────────────────────────
    const olColor = PdfColor(0.4, 0.53, 0.8);
    // Detect multiplicity so overlapping OL poles get a label.
    final olDrawn = <int>{};
    for (int i = 0; i < openLoopPoles.length; i++) {
      if (olDrawn.contains(i)) continue;
      final olp = openLoopPoles[i];
      int mult = 1;
      for (int j = i + 1; j < openLoopPoles.length; j++) {
        if (!olDrawn.contains(j) &&
            (olp.re - openLoopPoles[j].re).abs() < 1e-3 &&
            (olp.im - openLoopPoles[j].im).abs() < 1e-3) {
          mult++;
          olDrawn.add(j);
        }
      }
      olDrawn.add(i);
      final px = toX(olp.re);
      final py = toY(olp.im);
      // Draw circle marker
      canvas
        ..setStrokeColor(olColor)
        ..setLineWidth(1.5);
      // Approximate circle with 12-segment polygon
      const r = 5.0;
      for (var seg = 0; seg < 12; seg++) {
        final a1 = 2 * math.pi * seg / 12;
        final a2 = 2 * math.pi * (seg + 1) / 12;
        canvas
          ..drawLine(
            px + r * math.cos(a1), py + r * math.sin(a1),
            px + r * math.cos(a2), py + r * math.sin(a2),
          )
          ..strokePath();
      }
      if (mult > 1) {
        canvas.setColor(olColor);
        canvas.drawString(font, 6, 'x$mult', px + 7, py - 2);
      }
    }

    // ── Closed-loop poles (X markers) ─────────────────────────────────
    for (final pole in poles) {
      final px = toX(pole.re);
      final py = toY(pole.im);
      final color = pole.isStable
          ? const PdfColor(0.13, 0.73, 0.13)
          : const PdfColor(0.87, 0.2, 0.2);
      // Draw X marker
      canvas
        ..setStrokeColor(color)
        ..setLineWidth(2.0)
        ..drawLine(px - 5, py - 5, px + 5, py + 5)
        ..strokePath()
        ..drawLine(px + 5, py - 5, px - 5, py + 5)
        ..strokePath();
    }
  }

  /// Choose a nice round grid step for the pole-zero chart.
  static double _pzGridStep(double maxAbs) {
    if (maxAbs <= 5) return 1;
    if (maxAbs <= 20) return 5;
    if (maxAbs <= 100) return 25;
    if (maxAbs <= 500) return 100;
    return (maxAbs / 4).roundToDouble();
  }

  static Future<String?> _pickSavePath(MechanismConfig config) async {
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final slug = config.systemName.isNotEmpty
        ? config.systemName
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
            .replaceAll(RegExp(r'^_+|_+$'), '')
        : config.type.name;
    final name = 'sysid_report_${slug}_$timestamp.pdf';

    if (kIsWeb) return name;

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
