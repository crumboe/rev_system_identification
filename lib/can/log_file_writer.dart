/// Platform-conditional streaming log file writer.
///
/// On native (desktop), wraps dart:io IOSink for continuous CSV log output.
/// On web, provides a silent no-op (file system streaming is unavailable).
library;

export 'log_file_writer_native.dart'
    if (dart.library.js_interop) 'log_file_writer_web.dart';
