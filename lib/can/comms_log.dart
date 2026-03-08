/// Communication log for recording all CAN-over-USB traffic.
///
/// A global singleton ([CommsLog.instance]) accumulates entries for every
/// packet sent to or received from a SPARK controller, plus error and info
/// events.  The UI Console tab watches the [stream] to display the log in
/// real time.
library;

import 'dart:async';
import 'dart:typed_data';

import 'spark_protocol.dart';

// ---------------------------------------------------------------------------
// Entry model
// ---------------------------------------------------------------------------

/// Direction / category of a log entry.
enum CommDirection {
  /// Outbound packet (host → controller).
  tx,

  /// Inbound packet (controller → host).
  rx,

  /// Error or timeout.
  error,

  /// Informational message (connect, disconnect, etc.).
  info,
}

/// A single entry in the communication log.
class CommsLogEntry {
  /// Wall-clock time this entry was recorded.
  final DateTime timestamp;

  /// Whether this is TX, RX, error, or info.
  final CommDirection direction;

  /// Name of the COM port this entry is associated with.
  final String port;

  /// 29-bit CAN arbitration ID (null for pure info/error entries).
  final int? arbId;

  /// 8-byte packet payload (null for pure info/error entries).
  final Uint8List? payload;

  /// Human-readable description of the command or event.
  final String description;

  CommsLogEntry({
    required this.timestamp,
    required this.direction,
    required this.port,
    this.arbId,
    this.payload,
    required this.description,
  });

  /// Formatted timestamp string (HH:mm:ss.mmm).
  String get timeString {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    final ms = timestamp.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  /// Arb ID formatted as 8-digit hex (or '—' if absent).
  String get arbIdHex =>
      arbId != null ? '0x${arbId!.toRadixString(16).padLeft(8, '0')}' : '—';

  /// Payload formatted as space-separated hex bytes (or '—' if absent).
  String get payloadHex => payload != null
      ? payload!.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')
      : '—';
}

// ---------------------------------------------------------------------------
// Logger
// ---------------------------------------------------------------------------

/// Global communication log.
///
/// Access via [CommsLog.instance].  Listeners watch [stream] for updates.
class CommsLog {
  CommsLog._();

  static final CommsLog instance = CommsLog._();

  /// Maximum number of entries kept in memory.
  static const int maxEntries = 2000;

  final List<CommsLogEntry> _entries = [];
  final _controller = StreamController<List<CommsLogEntry>>.broadcast();

  /// Snapshot of all current log entries (newest last).
  List<CommsLogEntry> get entries => List.unmodifiable(_entries);

  /// Fires whenever a new entry is appended or the log is cleared.
  Stream<List<CommsLogEntry>> get stream => _controller.stream;

  // -----------------------------------------------------------------------
  // Public logging API
  // -----------------------------------------------------------------------

  /// Log an outbound packet (TX).
  void logTx(String port, int arbId, Uint8List payload) {
    _add(CommsLogEntry(
      timestamp: DateTime.now(),
      direction: CommDirection.tx,
      port: port,
      arbId: arbId,
      payload: payload,
      description: _describeOutbound(arbId, payload),
    ));
  }

  /// Log an inbound response (RX).
  void logRx(String port, SparkResponse response) {
    _add(CommsLogEntry(
      timestamp: DateTime.now(),
      direction: CommDirection.rx,
      port: port,
      arbId: response.arbId,
      payload: response.payload,
      description: _describeResponse(response),
    ));
  }

  /// Log an error or timeout.
  void logError(String port, String message) {
    _add(CommsLogEntry(
      timestamp: DateTime.now(),
      direction: CommDirection.error,
      port: port,
      description: message,
    ));
  }

  /// Log a generic informational event (connect, disconnect, etc.).
  void logInfo(String port, String message) {
    _add(CommsLogEntry(
      timestamp: DateTime.now(),
      direction: CommDirection.info,
      port: port,
      description: message,
    ));
  }

  /// Remove all entries from the log.
  void clear() {
    _entries.clear();
    if (!_controller.isClosed) {
      _controller.add(const []);
    }
  }

  // -----------------------------------------------------------------------
  // Internal helpers
  // -----------------------------------------------------------------------

  void _add(CommsLogEntry entry) {
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    if (!_controller.isClosed) {
      _controller.add(List.unmodifiable(_entries));
    }
  }

  // -----------------------------------------------------------------------
  // Human-readable description helpers
  // -----------------------------------------------------------------------

  static String _describeOutbound(int arbId, Uint8List payload) {
    final apiClass = extractApiClass(arbId);
    final apiIndex = extractApiIndex(arbId);

    // Heartbeat
    if (arbId == kHeartbeatArbId) return 'Heartbeat';

    if (apiClass == kApiClassControl) {
      if (apiIndex == kControlIndexSetpoint) {
        if (payload.length >= 5) {
          final bd = ByteData.sublistView(payload);
          final value = bd.getFloat32(0, Endian.little);
          final ctrlType = payload[4];
          final typeName = _controlTypeName(ctrlType);
          return 'Set setpoint $typeName = ${value.toStringAsFixed(3)}';
        }
        return 'Set setpoint';
      }
    } else if (apiClass == kApiClassParameter) {
      if (apiIndex == kParamIndexGet) {
        final paramId = readUint16(payload, 0);
        return 'Get parameter ${_paramName(paramId)} (id=$paramId)';
      }
      if (apiIndex == kParamIndexSet) {
        if (payload.length >= 6) {
          final bd = ByteData.sublistView(payload);
          final value = bd.getFloat32(0, Endian.little);
          final paramId = bd.getUint16(4, Endian.little);
          return 'Set parameter ${_paramName(paramId)} (id=$paramId) = '
              '${value.toStringAsFixed(4)}';
        }
        return 'Set parameter';
      }
    } else if (apiClass == kApiClassSystem) {
      return 'System: ${_systemIndexName(apiIndex)}';
    } else if (apiClass == kApiClassFrameRate) {
      return 'Set frame rate (index=$apiIndex)';
    }

    return 'TX apiClass=0x${apiClass.toRadixString(16)} '
        'apiIndex=0x${apiIndex.toRadixString(16)}';
  }

  static String _describeResponse(SparkResponse response) {
    final apiClass = response.apiClass;
    final apiIndex = response.apiIndex;

    // Status frames — these arrive frequently; keep descriptions terse.
    if (apiClass == kApiClassStatus) {
      return 'Status frame $apiIndex (legacy)';
    }
    if (apiClass == kApiClassNewStatus) {
      return 'Status frame $apiIndex (new)';
    }

    final typeStr = response.isAck ? 'ACK' : 'DATA';
    switch (apiClass) {
      case kApiClassParameter:
        if (apiIndex == kParamIndexGet || apiIndex == kParamIndexSet) {
          if (response.payload.length >= 4) {
            final value = readFloat32(response.payload, 0);
            return '$typeStr param value = ${value.toStringAsFixed(4)}';
          }
        }
        return '$typeStr parameter';

      case kApiClassSystem:
        return '$typeStr system: ${_systemIndexName(apiIndex)}';
    }

    return '$typeStr apiClass=0x${apiClass.toRadixString(16)} '
        'apiIndex=0x${apiIndex.toRadixString(16)}';
  }

  static String _controlTypeName(int ct) {
    switch (ct) {
      case kControlTypeDutyCycle:
        return 'DutyCycle';
      case kControlTypeVelocity:
        return 'Velocity';
      case kControlTypeVoltage:
        return 'Voltage';
      case kControlTypePosition:
        return 'Position';
      case kControlTypeCurrent:
        return 'Current';
      case kControlTypeMAXMotionPosition:
        return 'MAXMotion/Position';
      case kControlTypeMAXMotionVelocity:
        return 'MAXMotion/Velocity';
      default:
        return 'type=$ct';
    }
  }

  static String _systemIndexName(int idx) {
    switch (idx) {
      case kSystemIndexIdentify:
        return 'Identify';
      case kSystemIndexClearFaults:
        return 'ClearFaults';
      case kSystemIndexBurnFlash:
        return 'BurnFlash';
      case kSystemIndexSetFollower:
        return 'SetFollower';
      case kSystemIndexFactoryReset:
        return 'FactoryReset';
      case kSystemIndexIdQuery:
        return 'IdQuery';
      case kSystemIndexIdAssign:
        return 'IdAssign';
      default:
        return 'index=$idx';
    }
  }

  static String _paramName(int id) {
    switch (id) {
      case kParamCanId:
        return 'CanId';
      case kParamMotorType:
        return 'MotorType';
      case kParamIdleMode:
        return 'IdleMode';
      case kParamOpenLoopRampRate:
        return 'OpenLoopRampRate';
      case kParamMotorInverted:
        return 'Inverted';
      case kParamPositionConvFactor:
        return 'PositionConvFactor';
      case kParamVelocityConvFactor:
        return 'VelocityConvFactor';
      case kParamSlot0P:
        return 'Slot0P';
      case kParamSlot0I:
        return 'Slot0I';
      case kParamSlot0D:
        return 'Slot0D';
      case kParamSlot0F:
        return 'Slot0F (kV)';
      case kParamSlot0IZone:
        return 'Slot0IZone';
      case kParamSlot0DFilter:
        return 'Slot0DFilter';
      case kParamSlot0MinOutput:
        return 'Slot0MinOutput';
      case kParamSlot0MaxOutput:
        return 'Slot0MaxOutput';
      case kParamSmartCurrentLimit:
        return 'SmartCurrentLimit';
      case kParamForwardSoftLimit:
        return 'ForwardSoftLimit';
      case kParamForwardSoftLimitEnabled:
        return 'ForwardSoftLimitEnabled';
      case kParamReverseSoftLimit:
        return 'ReverseSoftLimit';
      case kParamReverseSoftLimitEnabled:
        return 'ReverseSoftLimitEnabled';
      case kParamFollowerId:
        return 'FollowerId';
      case kParamFollowerConfig:
        return 'FollowerConfig';
      case kParamSlot0FfKs:
        return 'Slot0FfKs';
      case kParamSlot0FfKa:
        return 'Slot0FfKa';
      case kParamSlot0FfKg:
        return 'Slot0FfKg';
      case kParamSlot0FfKcos:
        return 'Slot0FfKcos';
      case kParamSlot0FfKcosRatio:
        return 'Slot0FfKcosRatio';
      default:
        return 'param$id';
    }
  }
}
