/// Native (desktop) implementations of file save/load helpers using dart:io.
library;

import 'dart:io';

/// Write binary data to [path].
Future<void> writeFileBytes(String path, List<int> bytes) async {
  await File(path).writeAsBytes(bytes);
}

/// Write a string to [path], optionally flushing immediately.
Future<void> writeFileString(String path, String content,
    {bool flush = false}) async {
  await File(path).writeAsString(content, flush: flush);
}

/// Read the entire file at [path] as a UTF-8 string.
Future<String> readFileString(String path) async {
  return File(path).readAsString();
}
