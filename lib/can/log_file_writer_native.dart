/// Native (desktop) implementation of streaming log file writer using dart:io.
library;

import 'dart:io';

/// A streaming file writer that wraps [IOSink] for continuous log output.
class LogFileWriter {
  final IOSink _sink;

  LogFileWriter._(this._sink);

  /// Open [path] for writing (truncates any existing file).
  static Future<LogFileWriter> open(String path) async {
    final file = File(path);
    final sink = file.openWrite();
    return LogFileWriter._(sink);
  }

  /// Write a line to the log file.
  void writeln(String line) {
    _sink.writeln(line);
  }

  /// Flush and close the underlying file.
  Future<void> close() async {
    await _sink.flush();
    await _sink.close();
  }
}
