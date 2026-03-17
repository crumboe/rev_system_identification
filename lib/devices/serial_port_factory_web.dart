/// Web serial port scanning and connection factory.
///
/// Uses the Web Serial API (Chromium-only) for USB-CDC communication.
/// This file is only compiled on web targets via the conditional export
/// in `serial_port_factory.dart`.
library;

import '../can/interfaces.dart';
import '../can/web_spark_connection.dart';

/// Information about a discovered serial port that may be a SPARK controller.
///
/// On web, port enumeration is limited — the browser only exposes ports
/// that the user has previously granted access to.
class PortInfo {
  final String name;
  final String description;
  final String? manufacturer;
  final int? vendorId;
  final int? productId;

  const PortInfo({
    required this.name,
    required this.description,
    this.manufacturer,
    this.vendorId,
    this.productId,
  });

  /// Whether this port is likely a REV SPARK controller.
  bool get isLikelySpark => true; // All web ports were filtered at request time

  @override
  String toString() => '$name ($description)';
}

/// Scan for available serial ports.
///
/// On web, this returns only previously-granted ports (no user gesture needed).
/// To discover new ports, use `WebSparkConnection.requestPort()` which
/// requires a user click.
List<PortInfo> scanSerialPorts() {
  // Web Serial API's getPorts() is async, but our interface is sync.
  // Return empty — the UI uses a "Connect Device" button flow on web.
  return [];
}

/// Create a connection for the given port name.
///
/// On web this is not used directly — connections are created via
/// `WebSparkConnection.requestPort()` triggered by a user gesture.
ISparkConnection createSerialConnection(String portName) {
  throw UnsupportedError(
    'Direct serial connection by name is not supported on web. '
    'Use WebSparkConnection.requestPort() instead.',
  );
}

/// Whether the platform supports background port scanning.
bool get supportsBackgroundScan => false;

/// Whether the platform requires a user gesture to connect.
bool get requiresUserGesture => true;

/// Whether the Web Serial API is available in this browser.
bool get isWebSerialAvailable => WebSparkConnection.isAvailable;

/// Request the user to select a serial port (requires user gesture).
///
/// Shows the browser's native serial port chooser filtered for SPARK MAX.
/// Returns an [ISparkConnection] wrapping the granted port.
Future<ISparkConnection> requestWebSerialPort() {
  return WebSparkConnection.requestPort();
}

/// Get previously-granted Web Serial ports (no user gesture needed).
Future<List<ISparkConnection>> getGrantedWebSerialPorts() async {
  return WebSparkConnection.getGrantedPorts();
}
