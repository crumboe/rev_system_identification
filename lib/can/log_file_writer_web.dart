/// Web stub for streaming log file writer (no-op on web).
library;

/// A no-op log file writer for web where file system streaming is unavailable.
class LogFileWriter {
  LogFileWriter._();

  /// On web, this is a no-op — returns a writer that silently discards output.
  static Future<LogFileWriter> open(String path) async {
    return LogFileWriter._();
  }

  /// No-op on web.
  void writeln(String line) {}

  /// No-op on web.
  Future<void> close() async {}
}
