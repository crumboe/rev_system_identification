/// Web implementations of file save/load helpers using Blob + anchor download.
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Write binary data — triggers a browser download with the filename from [path].
Future<void> writeFileBytes(String path, List<int> bytes) async {
  final fileName = _fileNameFromPath(path);
  final uint8 = Uint8List.fromList(bytes);
  final blob = web.Blob(
    [uint8.toJS].toJS,
    web.BlobPropertyBag(type: 'application/octet-stream'),
  );
  _downloadBlob(blob, fileName);
}

/// Write a string — triggers a browser download with the filename from [path].
Future<void> writeFileString(String path, String content,
    {bool flush = false}) async {
  final fileName = _fileNameFromPath(path);
  final blob = web.Blob(
    [content.toJS].toJS,
    web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
  );
  _downloadBlob(blob, fileName);
}

/// Read a file from [path].
///
/// On web, use `FilePicker.pickFiles()` and read `bytes` directly instead.
Future<String> readFileString(String path) async {
  // On web, file paths are meaningless. The FilePicker returns bytes directly
  // via PlatformFile.bytes. Callers should check for web and use bytes.
  throw UnsupportedError(
    'readFileString is not supported on web. '
    'Use FilePicker.pickFiles() and read PlatformFile.bytes instead.',
  );
}

void _downloadBlob(web.Blob blob, String fileName) {
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor.href = url;
  anchor.download = fileName;
  anchor.style.display = 'none';
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}

String _fileNameFromPath(String path) {
  // Extract just the filename from a path (handles both / and \).
  final lastSep = path.lastIndexOf(RegExp(r'[/\\]'));
  return lastSep >= 0 ? path.substring(lastSep + 1) : path;
}
