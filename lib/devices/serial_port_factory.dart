/// Platform-conditional export for serial port factory functions.
///
/// On native platforms (Windows, macOS, Linux), exports functions that use
/// `flutter_libserialport` for port scanning and connection creation.
///
/// On web, exports stubs that work with the Web Serial API flow
/// (user-gesture-triggered port selection).
library;

export 'serial_port_factory_native.dart'
    if (dart.library.js_interop) 'serial_port_factory_web.dart';
