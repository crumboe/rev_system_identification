/// Native (Windows/macOS/Linux) serial port scanning and connection factory.
///
/// Uses `flutter_libserialport` (FFI) for USB-CDC serial communication.
/// This file is only compiled on native targets via the conditional export
/// in `serial_port_factory.dart`.
library;

import 'package:flutter_libserialport/flutter_libserialport.dart';

import '../can/interfaces.dart';
import '../can/spark_connection.dart';

/// Information about a discovered serial port that may be a SPARK controller.
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
  bool get isLikelySpark {
    final mfr = manufacturer?.toLowerCase() ?? '';
    final desc = description.toLowerCase();
    return mfr.contains('rev') ||
        desc.contains('spark') ||
        desc.contains('rev') ||
        desc.contains('usb serial');
  }

  @override
  String toString() => '$name ($description)';
}

/// Scan for available serial ports and return info about each.
List<PortInfo> scanSerialPorts() {
  final portNames = SerialPort.availablePorts;
  return portNames.map((name) {
    final port = SerialPort(name);
    final info = PortInfo(
      name: name,
      description: port.description ?? name,
      manufacturer: port.manufacturer,
      vendorId: port.vendorId,
      productId: port.productId,
    );
    port.dispose();
    return info;
  }).toList();
}

/// Create a native [SparkConnection] for the given COM port name.
ISparkConnection createSerialConnection(String portName) {
  return SparkConnection.fromPortName(portName);
}

/// Whether the platform supports background port scanning.
///
/// Native platforms can enumerate COM/tty ports in the background.
/// Web requires a user gesture to request a port.
bool get supportsBackgroundScan => true;

/// Whether the platform requires a user gesture to connect.
bool get requiresUserGesture => false;

/// Whether the Web Serial API is available (always false on native).
bool get isWebSerialAvailable => false;

/// Request a serial port via user gesture (not supported on native).
Future<ISparkConnection> requestWebSerialPort() async {
  throw UnsupportedError('Web Serial is not available on native platforms.');
}

/// Get previously-granted Web Serial ports (not supported on native).
Future<List<ISparkConnection>> getGrantedWebSerialPorts() async => [];
