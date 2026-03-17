/// Save and load complete system identification projects as JSON files.
///
/// A project file (.revsysid) contains:
///   - Mechanism configuration
///   - Test parameters
///   - Test run data (if available)
///   - Computed feedforward & PID gains (if available)
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'file_saver.dart';

import '../mechanisms/mechanism.dart';
import 'test_data.dart';

/// File format version for forward compatibility.
const int _formatVersion = 1;

/// Extension used for project files.
const String projectFileExtension = 'revsysid';

/// In-memory representation of a saved project.
class ProjectData {
  final MechanismConfig config;
  final SysIdTestParams testParams;
  final List<TestRun> testRuns;
  final FeedforwardGains? feedforward;
  final PidResult? velocityPid;
  final PidResult? positionPid;

  const ProjectData({
    required this.config,
    required this.testParams,
    this.testRuns = const [],
    this.feedforward,
    this.velocityPid,
    this.positionPid,
  });

  Map<String, dynamic> toJson() => {
        'formatVersion': _formatVersion,
        'config': config.toJson(),
        'testParams': testParams.toJson(),
        'testRuns': testRuns.map((r) => r.toJson()).toList(),
        if (feedforward != null) 'feedforward': feedforward!.toJson(),
        if (velocityPid != null) 'velocityPid': velocityPid!.toJson(),
        if (positionPid != null) 'positionPid': positionPid!.toJson(),
      };

  factory ProjectData.fromJson(Map<String, dynamic> json) {
    // formatVersion can be used for migration in the future.
    return ProjectData(
      config:
          MechanismConfig.fromJson(json['config'] as Map<String, dynamic>),
      testParams: SysIdTestParams.fromJson(
          json['testParams'] as Map<String, dynamic>),
      testRuns: (json['testRuns'] as List?)
              ?.map((r) => TestRun.fromJson(r as Map<String, dynamic>))
              .toList() ??
          const [],
      feedforward: json['feedforward'] != null
          ? FeedforwardGains.fromJson(
              json['feedforward'] as Map<String, dynamic>)
          : null,
      velocityPid: json['velocityPid'] != null
          ? PidResult.fromJson(json['velocityPid'] as Map<String, dynamic>)
          : null,
      positionPid: json['positionPid'] != null
          ? PidResult.fromJson(json['positionPid'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// Save [project] to a user-chosen file.
///
/// Returns the chosen path on success, or `null` if the user cancelled.
Future<String?> saveProject(ProjectData project) async {
  final name = project.config.systemName.isNotEmpty
      ? project.config.systemName
      : 'untitled';

  final fileName = '$name.$projectFileExtension';

  final String result;
  if (kIsWeb) {
    result = fileName;
  } else {
    final picked = await FilePicker.platform.saveFile(
      dialogTitle: 'Save System Identification Project',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: [projectFileExtension],
    );
    if (picked == null) return null;
    result = picked;
  }

  final jsonString =
      const JsonEncoder.withIndent('  ').convert(project.toJson());
  await writeFileString(result, jsonString, flush: true);
  return result;
}

/// Load a project from a user-chosen file.
///
/// Returns the loaded [ProjectData] on success, or `null` if the user
/// cancelled or the file was invalid.
Future<ProjectData?> loadProject() async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Open System Identification Project',
    type: FileType.custom,
    allowedExtensions: [projectFileExtension],
  );

  if (result == null || result.files.isEmpty) return null;

  final file = result.files.single;
  final String jsonString;
  if (kIsWeb) {
    final bytes = file.bytes;
    if (bytes == null) return null;
    jsonString = utf8.decode(bytes);
  } else {
    final path = file.path;
    if (path == null) return null;
    jsonString = await readFileString(path);
  }

  final json = jsonDecode(jsonString) as Map<String, dynamic>;
  return ProjectData.fromJson(json);
}
