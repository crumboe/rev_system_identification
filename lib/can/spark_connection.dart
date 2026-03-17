/// Platform-conditional export for the SPARK serial connection.
///
/// On native platforms (Windows, macOS, Linux), exports [SparkConnection]
/// which uses `flutter_libserialport` (FFI) for USB-serial communication.
///
/// On web, exports [WebSparkConnection] which uses the browser's Web
/// Serial API (Chromium-only).
library;

export 'spark_connection_native.dart'
    if (dart.library.js_interop) 'web_spark_connection.dart';
