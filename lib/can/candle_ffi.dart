/// Dart FFI bindings for the Candle (gs_usb) API in REV's CANBridge.dll.
///
/// The Candle API is a thin wrapper around the WinUSB interface that gives
/// access to the SPARK MAX MI_00 CAN endpoint.  This is the same API used
/// by the REV Hardware Client for bidirectional CAN communication.
///
/// The DLL lives inside the REV Hardware Client installation:
///   C:\Program Files (x86)\REV Robotics\REV Hardware Client\resources\
///     app.asar.unpacked\node_modules\@rev-robotics\can-bridge\prebuilds\
///     node_canbridge-win32-x64\CANBridge.dll
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// gs_host_frame struct — mirrors the C layout (20 bytes, packed)
// ---------------------------------------------------------------------------

/// The CAN frame structure used by the Candle/gs_usb protocol.
///
/// Layout (20 bytes total):
/// ```
/// uint32_t echo_id;   // 0–3:  echo/correlation ID
/// uint32_t can_id;    // 4–7:  CAN ID (bit 31 = EFF flag for extended)
/// uint8_t  can_dlc;   // 8:    data length code (0–8)
/// uint8_t  channel;   // 9:    CAN channel (0 for SPARK MAX)
/// uint8_t  flags;     // 10:   flags
/// uint8_t  reserved;  // 11:   padding
/// uint8_t  data[8];   // 12–19: CAN payload
/// ```
final class GsHostFrame extends Struct {
  @Uint32()
  external int echoId;

  @Uint32()
  external int canId;

  @Uint8()
  external int canDlc;

  @Uint8()
  external int channel;

  @Uint8()
  external int flags;

  @Uint8()
  external int reserved;

  @Array(8)
  external Array<Uint8> data;
}

/// Extended frame format flag — set bit 31 of can_id for 29-bit CAN IDs.
const int gsCanFlagEff = 0x80000000;

/// Size of a [GsHostFrame] in bytes.
const int gsHostFrameSize = 20;

// ---------------------------------------------------------------------------
// Candle API function typedefs
// ---------------------------------------------------------------------------

// candle_list_scan(candle_list_t** list) → bool
typedef _CandleListScanC = Bool Function(Pointer<Pointer<Void>>);
typedef CandleListScanDart = bool Function(Pointer<Pointer<Void>>);

// candle_list_length(candle_list_t* list) → uint8
typedef _CandleListLengthC = Uint8 Function(Pointer<Void>);
typedef CandleListLengthDart = int Function(Pointer<Void>);

// candle_dev_get(candle_list_t* list, uint8 index, candle_handle_t* hdev) → bool
typedef _CandleDevGetC = Bool Function(
    Pointer<Void>, Uint8, Pointer<Pointer<Void>>);
typedef CandleDevGetDart = bool Function(
    Pointer<Void>, int, Pointer<Pointer<Void>>);

// candle_dev_open(candle_handle_t hdev) → bool
typedef _CandleDevOpenC = Bool Function(Pointer<Void>);
typedef CandleDevOpenDart = bool Function(Pointer<Void>);

// candle_dev_close(candle_handle_t hdev) → void
typedef _CandleDevCloseC = Void Function(Pointer<Void>);
typedef CandleDevCloseDart = void Function(Pointer<Void>);

// candle_channel_start(candle_handle_t hdev, uint8 ch, uint32 flags) → bool
typedef _CandleChannelStartC = Bool Function(Pointer<Void>, Uint8, Uint32);
typedef CandleChannelStartDart = bool Function(Pointer<Void>, int, int);

// candle_channel_stop(candle_handle_t hdev, uint8 ch) → bool
typedef _CandleChannelStopC = Bool Function(Pointer<Void>, Uint8);
typedef CandleChannelStopDart = bool Function(Pointer<Void>, int);

// candle_frame_send(candle_handle_t hdev, uint8 ch, candle_frame_t* frame, uint32 timeout) → bool
typedef _CandleFrameSendC = Bool Function(
    Pointer<Void>, Uint8, Pointer<GsHostFrame>, Uint32);
typedef CandleFrameSendDart = bool Function(
    Pointer<Void>, int, Pointer<GsHostFrame>, int);

// candle_frame_read(candle_handle_t hdev, candle_frame_t* frame, uint32 timeout) → bool
typedef _CandleFrameReadC = Bool Function(
    Pointer<Void>, Pointer<GsHostFrame>, Uint32);
typedef CandleFrameReadDart = bool Function(
    Pointer<Void>, Pointer<GsHostFrame>, int);

// candle_list_free(candle_list_t* list) → void
typedef _CandleListFreeC = Void Function(Pointer<Void>);
typedef CandleListFreeDart = void Function(Pointer<Void>);

// candle_dev_get_path(candle_handle_t hdev) → wchar_t*
typedef _CandleDevGetPathC = Pointer<Utf16> Function(Pointer<Void>);
typedef CandleDevGetPathDart = Pointer<Utf16> Function(Pointer<Void>);

// candle_dev_get_name(candle_handle_t hdev) → wchar_t*
typedef _CandleDevGetNameC = Pointer<Utf16> Function(Pointer<Void>);
typedef CandleDevGetNameDart = Pointer<Utf16> Function(Pointer<Void>);

// candle_dev_last_error(candle_handle_t hdev) → int
typedef _CandleDevLastErrorC = Int32 Function(Pointer<Void>);
typedef CandleDevLastErrorDart = int Function(Pointer<Void>);

// candle_error_text(int error_code) → wchar_t*
typedef _CandleErrorTextC = Pointer<Utf16> Function(Int32);
typedef CandleErrorTextDart = Pointer<Utf16> Function(int);

// ---------------------------------------------------------------------------
// CandleApi — resolved function pointers from CANBridge.dll
// ---------------------------------------------------------------------------

/// Resolved Candle API bindings from CANBridge.dll.
///
/// Create via [CandleApi.load]. Returns `null` if the DLL cannot be found
/// or the REV Hardware Client is not installed.
class CandleApi {
  final DynamicLibrary _lib;

  late final CandleListScanDart listScan;
  late final CandleListLengthDart listLength;
  late final CandleDevGetDart devGet;
  late final CandleDevOpenDart devOpen;
  late final CandleDevCloseDart devClose;
  late final CandleChannelStartDart channelStart;
  late final CandleChannelStopDart channelStop;
  late final CandleFrameSendDart frameSend;
  late final CandleFrameReadDart frameRead;
  late final CandleListFreeDart listFree;
  late final CandleDevGetPathDart devGetPath;
  late final CandleDevGetNameDart devGetName;
  late final CandleDevLastErrorDart devLastError;
  late final CandleErrorTextDart errorText;

  CandleApi._(this._lib) {
    listScan = _lib
        .lookupFunction<_CandleListScanC, CandleListScanDart>(
            'candle_list_scan');
    listLength = _lib
        .lookupFunction<_CandleListLengthC, CandleListLengthDart>(
            'candle_list_length');
    devGet = _lib
        .lookupFunction<_CandleDevGetC, CandleDevGetDart>('candle_dev_get');
    devOpen = _lib
        .lookupFunction<_CandleDevOpenC, CandleDevOpenDart>('candle_dev_open');
    devClose = _lib
        .lookupFunction<_CandleDevCloseC, CandleDevCloseDart>(
            'candle_dev_close');
    channelStart = _lib
        .lookupFunction<_CandleChannelStartC, CandleChannelStartDart>(
            'candle_channel_start');
    channelStop = _lib
        .lookupFunction<_CandleChannelStopC, CandleChannelStopDart>(
            'candle_channel_stop');
    frameSend = _lib
        .lookupFunction<_CandleFrameSendC, CandleFrameSendDart>(
            'candle_frame_send');
    frameRead = _lib
        .lookupFunction<_CandleFrameReadC, CandleFrameReadDart>(
            'candle_frame_read');
    listFree = _lib
        .lookupFunction<_CandleListFreeC, CandleListFreeDart>(
            'candle_list_free');
    devGetPath = _lib
        .lookupFunction<_CandleDevGetPathC, CandleDevGetPathDart>(
            'candle_dev_get_path');
    devGetName = _lib
        .lookupFunction<_CandleDevGetNameC, CandleDevGetNameDart>(
            'candle_dev_get_name');
    devLastError = _lib
        .lookupFunction<_CandleDevLastErrorC, CandleDevLastErrorDart>(
            'candle_dev_last_error');
    errorText = _lib
        .lookupFunction<_CandleErrorTextC, CandleErrorTextDart>(
            'candle_error_text');
  }

  /// Known locations for CANBridge.dll within the REV Hardware Client.
  static const List<String> _knownPaths = [
    r'C:\Program Files (x86)\REV Robotics\REV Hardware Client\resources'
        r'\app.asar.unpacked\node_modules\@rev-robotics\can-bridge\prebuilds'
        r'\node_canbridge-win32-x64\CANBridge.dll',
    r'C:\Program Files\REV Robotics\REV Hardware Client\resources'
        r'\app.asar.unpacked\node_modules\@rev-robotics\can-bridge\prebuilds'
        r'\node_canbridge-win32-x64\CANBridge.dll',
  ];

  /// The directory containing the loaded DLL (needed for dependent DLLs).
  static String? _loadedDllDir;

  /// Try to load CANBridge.dll from known install locations.
  ///
  /// Returns a resolved [CandleApi] or `null` if the DLL was not found
  /// (REV Hardware Client not installed).
  static CandleApi? load() {
    for (final path in _knownPaths) {
      final file = File(path);
      if (file.existsSync()) {
        final dir = file.parent.path;
        _loadedDllDir = dir;
        try {
          final lib = DynamicLibrary.open(path);
          return CandleApi._(lib);
        } catch (_) {
          // DLL found but failed to load — try next path.
        }
      }
    }
    return null;
  }

  /// Whether CANBridge.dll is available on this system.
  static bool get isAvailable {
    for (final path in _knownPaths) {
      if (File(path).existsSync()) return true;
    }
    return false;
  }
}
