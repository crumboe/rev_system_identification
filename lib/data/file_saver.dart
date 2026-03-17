/// Platform-conditional file save/load helpers.
///
/// On native (desktop), delegates to dart:io File operations.
/// On web, triggers browser downloads via Blob + anchor.
library;

export 'file_saver_native.dart'
    if (dart.library.js_interop) 'file_saver_web.dart';
