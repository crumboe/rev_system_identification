/// CSV export for test data, compatible with WPILib SysId tool format.
library;

import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'file_saver.dart';
import 'package:file_picker/file_picker.dart';

import 'test_data.dart';

/// Exports test run data to CSV files.
class CsvExporter {
  /// Export a single [TestRun] to a CSV file.
  ///
  /// If [filePath] is null, a save dialog is shown.
  /// Returns the path of the saved file, or null if cancelled.
  static Future<String?> exportTestRun(
    TestRun run, {
    String? filePath,
  }) async {
    final path = filePath ?? await _pickSavePath(run);
    if (path == null) return null;

    final rows = <List<dynamic>>[
      // Header
      ['timestamp', 'voltage', 'velocity', 'position', 'current'],
      // Data rows
      for (final dp in run.data)
        [dp.timestamp, dp.voltage, dp.velocity, dp.position, dp.current],
    ];

    final csv = const ListToCsvConverter().convert(rows);
    await writeFileString(path, csv);
    return path;
  }

  /// Export multiple test runs to a single CSV file with a test-type column.
  ///
  /// This format is compatible with WPILib SysId import.
  static Future<String?> exportAllRuns(
    List<TestRun> runs, {
    String? filePath,
  }) async {
    final path = filePath ??
        await _pickSavePath(null, defaultName: 'sysid_data.csv');
    if (path == null) return null;

    final rows = <List<dynamic>>[
      ['test', 'timestamp', 'voltage', 'velocity', 'position', 'current'],
      for (final run in runs)
        for (final dp in run.data)
          [
            run.testType.name,
            dp.timestamp,
            dp.voltage,
            dp.velocity,
            dp.position,
            dp.current,
          ],
    ];

    final csv = const ListToCsvConverter().convert(rows);
    await writeFileString(path, csv);
    return path;
  }

  /// Export in WPILib SysId JSON format.
  static Future<String?> exportWpiLibFormat(
    List<TestRun> runs, {
    String? filePath,
  }) async {
    final path = filePath ??
        await _pickSavePath(null, defaultName: 'sysid_data.json');
    if (path == null) return null;

    // WPILib SysId expects a JSON object with test type keys,
    // each containing arrays of [timestamp, voltage, position, velocity].
    final Map<String, List<List<double>>> data = {};

    for (final run in runs) {
      final key = switch (run.testType) {
        TestType.quasistaticForward => 'slow-forward',
        TestType.quasistaticReverse => 'slow-backward',
        TestType.dynamicForward => 'fast-forward',
        TestType.dynamicReverse => 'fast-backward',
      };

      data[key] = [
        for (final dp in run.data)
          [dp.timestamp, dp.voltage, dp.position, dp.velocity],
      ];
    }

    // Build JSON string manually for clean formatting.
    final sb = StringBuffer('{\n');
    final entries = data.entries.toList();
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      sb.write('  "${entry.key}": [\n');
      for (var j = 0; j < entry.value.length; j++) {
        final row = entry.value[j];
        sb.write('    [${row.join(', ')}]');
        if (j < entry.value.length - 1) sb.write(',');
        sb.writeln();
      }
      sb.write('  ]');
      if (i < entries.length - 1) sb.write(',');
      sb.writeln();
    }
    sb.write('}\n');

    await writeFileString(path, sb.toString());
    return path;
  }

  /// Show a save-file dialog and return the chosen path.
  static Future<String?> _pickSavePath(
    TestRun? run, {
    String? defaultName,
  }) async {
    final name = defaultName ??
        'sysid_${run!.mechanismType.name}_${run.testType.name}_'
            '${run.startTime.toIso8601String().replaceAll(':', '-')}.csv';

    if (kIsWeb) return name;

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Test Data',
      fileName: name,
      type: FileType.custom,
      allowedExtensions: ['csv', 'json'],
    );
    return result;
  }
}
