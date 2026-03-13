"""
SPARK MAX Candle Cold-Boot Test — No HC2 Required
====================================================
Tests the full Candle/gs_usb WinUSB initialization sequence using
CANBridge.dll directly, WITHOUT relying on REV Hardware Client 2.

This replicates the exact sequence used in our Flutter/Dart app:
  1. candle_list_scan()
  2. candle_list_length()
  3. candle_dev_get() + candle_dev_get_path() + candle_dev_get_name()
  4. candle_dev_open()
  5. candle_channel_set_bitrate(1 Mbps)
  6. candle_channel_start()
  7. Send secondary heartbeat (Class=11, Index=2) — 80ms timer
  8. Read CAN ID via parameter read (Class=7, Index=1)
  9. candle_frame_read() poll loop

Instructions:
  - Close REV Hardware Client 2 if running
  - Power cycle the SPARK MAX (unplug USB, wait 3s, replug)
  - Wait 3s for USB enumeration
  - Run: python candle_cold_boot_test.py

Requirements: CANBridge.dll from REV Hardware Client (v1 or v2)
"""

import ctypes
import ctypes.wintypes
import struct
import time
import os
import sys

# ---------------------------------------------------------------------------
# DLL paths — same as our Flutter app candle_ffi.dart
# ---------------------------------------------------------------------------
DLL_PATHS = [
    r"C:\Program Files (x86)\REV Robotics\REV Hardware Client\resources"
    r"\app.asar.unpacked\node_modules\@rev-robotics\can-bridge"
    r"\prebuilds\node_canbridge-win32-x64\CANBridge.dll",
    r"C:\Program Files\REV Robotics\REV Hardware Client\resources"
    r"\app.asar.unpacked\node_modules\@rev-robotics\can-bridge"
    r"\prebuilds\node_canbridge-win32-x64\CANBridge.dll",
]

DEVICE_TYPE  = 0x02
MANUFACTURER = 0x05
GS_CAN_FLAG_EFF = 0x80000000  # 29-bit extended frame


# ---------------------------------------------------------------------------
# gs_host_frame structure — matches GsHostFrame in candle_ffi.dart
# ---------------------------------------------------------------------------
class GsHostFrame(ctypes.Structure):
    _pack_ = 1
    _fields_ = [
        ("echo_id",  ctypes.c_uint32),
        ("can_id",   ctypes.c_uint32),
        ("can_dlc",  ctypes.c_uint8),
        ("channel",  ctypes.c_uint8),
        ("flags",    ctypes.c_uint8),
        ("reserved", ctypes.c_uint8),
        ("data",     ctypes.c_uint8 * 8),
    ]


def load_canbridge():
    """Load CANBridge.dll, adding its directory to PATH for wpiHal.dll etc."""
    for path in DLL_PATHS:
        if os.path.isfile(path):
            dll_dir = os.path.dirname(path)
            os.environ["PATH"] = dll_dir + ";" + os.environ.get("PATH", "")
            try:
                dll = ctypes.CDLL(path)
                print(f"[OK] Loaded CANBridge.dll from: {path}")
                return dll
            except OSError as e:
                print(f"[WARN] Found DLL but cannot load: {e}")
    print("[FAIL] CANBridge.dll not found in any known path")
    sys.exit(1)


def make_arb_id(api_class, api_index, device_id):
    return (
        (DEVICE_TYPE  & 0x1F) << 24 |
        (MANUFACTURER & 0xFF) << 16 |
        (api_class    & 0x3F) << 10 |
        (api_index    & 0x0F) << 6  |
        (device_id    & 0x3F)
    )


def decode_arb_id(arb_id):
    return {
        "dev_type":  (arb_id >> 24) & 0x1F,
        "mfr":       (arb_id >> 16) & 0xFF,
        "api_class": (arb_id >> 10) & 0x3F,
        "api_index": (arb_id >>  6) & 0x0F,
        "device_id":  arb_id        & 0x3F,
    }


def build_heartbeat_payload(device_id):
    """Build secondary heartbeat 8-byte payload — bit N enables SPARK N."""
    bitfield = 1 << device_id if device_id < 64 else 0
    return struct.pack("<Q", bitfield)


def main():
    dll = load_canbridge()

    # -----------------------------------------------------------------------
    # Step 1: candle_list_scan
    # -----------------------------------------------------------------------
    print("\n=== Step 1: candle_list_scan ===")
    list_ptr = ctypes.c_void_p()
    dll.candle_list_scan.restype = ctypes.c_bool
    dll.candle_list_scan.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    ok = dll.candle_list_scan(ctypes.byref(list_ptr))
    if not ok or not list_ptr.value:
        print("[FAIL] candle_list_scan returned False or null")
        sys.exit(1)
    print(f"[OK] candle_list_scan succeeded, list_ptr=0x{list_ptr.value:X}")

    # -----------------------------------------------------------------------
    # Step 2: candle_list_length
    # -----------------------------------------------------------------------
    print("\n=== Step 2: candle_list_length ===")
    count = ctypes.c_uint8()
    dll.candle_list_length.restype = ctypes.c_bool
    dll.candle_list_length.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8)]
    ok = dll.candle_list_length(list_ptr, ctypes.byref(count))
    if not ok:
        print("[FAIL] candle_list_length returned False")
        sys.exit(1)
    print(f"[OK] Found {count.value} device(s)")
    if count.value == 0:
        print("[FAIL] No devices found! Is the SPARK MAX connected and powered?")
        dll.candle_list_free(list_ptr)
        sys.exit(1)

    # -----------------------------------------------------------------------
    # Step 3: candle_dev_get + get_path + get_name
    # -----------------------------------------------------------------------
    print("\n=== Step 3: candle_dev_get + path/name ===")
    dll.candle_dev_get.restype = ctypes.c_bool
    dll.candle_dev_get.argtypes = [ctypes.c_void_p, ctypes.c_uint8, ctypes.POINTER(ctypes.c_void_p)]
    dll.candle_dev_get_path.restype = ctypes.c_wchar_p
    dll.candle_dev_get_path.argtypes = [ctypes.c_void_p]
    dll.candle_dev_get_name.restype = ctypes.c_wchar_p
    dll.candle_dev_get_name.argtypes = [ctypes.c_void_p]

    dev_handle = ctypes.c_void_p()
    for i in range(count.value):
        ok = dll.candle_dev_get(list_ptr, i, ctypes.byref(dev_handle))
        if ok and dev_handle.value:
            path = dll.candle_dev_get_path(dev_handle) or "(null)"
            name = dll.candle_dev_get_name(dev_handle) or "(null)"
            print(f"  Device {i}: name={name}, path={path}")
        else:
            print(f"  Device {i}: FAILED to get handle")

    # Use device 0
    ok = dll.candle_dev_get(list_ptr, 0, ctypes.byref(dev_handle))
    if not ok or not dev_handle.value:
        print("[FAIL] Cannot get device 0 handle")
        sys.exit(1)

    # -----------------------------------------------------------------------
    # Step 4: candle_dev_open
    # -----------------------------------------------------------------------
    print("\n=== Step 4: candle_dev_open ===")
    dll.candle_dev_open.restype = ctypes.c_bool
    dll.candle_dev_open.argtypes = [ctypes.c_void_p]
    ok = dll.candle_dev_open(dev_handle)
    if not ok:
        dll.candle_dev_last_error.restype = ctypes.c_int32
        dll.candle_dev_last_error.argtypes = [ctypes.c_void_p]
        err = dll.candle_dev_last_error(dev_handle)
        print(f"[FAIL] candle_dev_open failed, error code={err}")
        dll.candle_list_free(list_ptr)
        sys.exit(1)
    print("[OK] Device opened")

    # -----------------------------------------------------------------------
    # Step 5: candle_channel_set_bitrate(1 Mbps)
    # -----------------------------------------------------------------------
    print("\n=== Step 5: candle_channel_set_bitrate(1000000) ===")
    dll.candle_channel_set_bitrate.restype = ctypes.c_bool
    dll.candle_channel_set_bitrate.argtypes = [ctypes.c_void_p, ctypes.c_uint8, ctypes.c_uint32]
    ok = dll.candle_channel_set_bitrate(dev_handle, 0, 1000000)
    print(f"[{'OK' if ok else 'WARN'}] candle_channel_set_bitrate -> {ok}")

    # -----------------------------------------------------------------------
    # Step 6: candle_channel_start
    # -----------------------------------------------------------------------
    print("\n=== Step 6: candle_channel_start ===")
    dll.candle_channel_start.restype = ctypes.c_bool
    dll.candle_channel_start.argtypes = [ctypes.c_void_p, ctypes.c_uint8, ctypes.c_uint32]
    ok = dll.candle_channel_start(dev_handle, 0, 0)
    if not ok:
        print("[FAIL] candle_channel_start failed")
        dll.candle_dev_close(dev_handle)
        dll.candle_list_free(list_ptr)
        sys.exit(1)
    print("[OK] CAN channel 0 started")

    # Setup frame read/send
    dll.candle_frame_send.restype = ctypes.c_bool
    dll.candle_frame_send.argtypes = [ctypes.c_void_p, ctypes.c_uint8, ctypes.POINTER(GsHostFrame), ctypes.c_uint32]
    dll.candle_frame_read.restype = ctypes.c_bool
    dll.candle_frame_read.argtypes = [ctypes.c_void_p, ctypes.POINTER(GsHostFrame), ctypes.c_uint32]

    frame = GsHostFrame()

    # -----------------------------------------------------------------------
    # Step 7: Send heartbeat (discover device by listening first)
    # -----------------------------------------------------------------------
    print("\n=== Step 7: Listen for status frames (2s) then send heartbeat ===")

    # First, listen for 2 seconds to discover device IDs from status broadcasts
    discovered_ids = set()
    start = time.time()
    frame_count = 0
    while time.time() - start < 2.0:
        if dll.candle_frame_read(dev_handle, ctypes.byref(frame), 10):
            arb_id = frame.can_id & 0x1FFFFFFF
            d = decode_arb_id(arb_id)
            if d["dev_type"] == DEVICE_TYPE and d["mfr"] == MANUFACTURER:
                discovered_ids.add(d["device_id"])
                frame_count += 1

    if discovered_ids:
        print(f"[OK] Received {frame_count} status frames from device ID(s): {sorted(discovered_ids)}")
        target_id = sorted(discovered_ids)[0]
    else:
        print("[WARN] No status frames received — trying device ID 10 (default from HC2 log)")
        target_id = 10

    print(f"\nSending secondary heartbeat for device ID {target_id}...")
    hb_arb_id = make_arb_id(0x0B, 0x02, target_id)  # Class=11, Index=2
    hb_payload = build_heartbeat_payload(target_id)

    # Send 10 heartbeats at 80ms interval
    for i in range(10):
        frame.echo_id = 0
        frame.can_id = hb_arb_id | GS_CAN_FLAG_EFF
        frame.can_dlc = 8
        frame.channel = 0
        frame.flags = 0
        frame.reserved = 0
        for j in range(8):
            frame.data[j] = hb_payload[j]
        ok = dll.candle_frame_send(dev_handle, 0, ctypes.byref(frame), 1000)
        if i == 0:
            print(f"  Heartbeat arb_id=0x{hb_arb_id:08X}, payload={hb_payload.hex()} -> {'OK' if ok else 'FAIL'}")
        time.sleep(0.08)
    print(f"[OK] Sent 10 heartbeats")

    # -----------------------------------------------------------------------
    # Step 8: Read CAN ID via parameter read (Class=7, Index=1, param=0)
    # -----------------------------------------------------------------------
    print(f"\n=== Step 8: Read CAN ID (param 0) for device {target_id} ===")
    param_arb_id = make_arb_id(0x07, 0x01, target_id)
    param_payload = bytes([0x00]) + b'\x00' * 7  # param ID 0 = CAN ID

    frame.echo_id = 0
    frame.can_id = param_arb_id | GS_CAN_FLAG_EFF
    frame.can_dlc = 8
    frame.channel = 0
    frame.flags = 0
    frame.reserved = 0
    for j in range(8):
        frame.data[j] = param_payload[j]
    ok = dll.candle_frame_send(dev_handle, 0, ctypes.byref(frame), 1000)
    print(f"  Sent param read: arb_id=0x{param_arb_id:08X} -> {'OK' if ok else 'FAIL'}")

    # Wait for response
    response_found = False
    deadline = time.time() + 1.0
    while time.time() < deadline:
        if dll.candle_frame_read(dev_handle, ctypes.byref(frame), 10):
            arb_id = frame.can_id & 0x1FFFFFFF
            d = decode_arb_id(arb_id)
            dlc = frame.can_dlc
            data = bytes(frame.data[j] for j in range(min(dlc, 8)))

            if d["api_class"] == 0x07 and d["device_id"] == target_id and len(data) >= 8:
                param_id = data[0]
                status_byte = data[1]
                raw_val = data[2:6]
                type_tag = data[6]
                result_code = data[7]

                can_id_val = struct.unpack_from('<I', raw_val)[0]
                print(f"  RESPONSE: param_id={param_id}, status=0x{status_byte:02X}, "
                      f"value={can_id_val}, type_tag=0x{type_tag:02X}, result=0x{result_code:02X}")
                print(f"  -> CAN ID = {can_id_val}")
                response_found = True
                break

    if not response_found:
        print("  [WARN] No parameter response received within 1s")

    # -----------------------------------------------------------------------
    # Step 9: Monitor status frames for 3 seconds
    # -----------------------------------------------------------------------
    print(f"\n=== Step 9: Monitor CAN traffic (3s, sending heartbeats) ===")
    start = time.time()
    classes_seen = {}
    total_rx = 0
    last_hb = time.time()

    while time.time() - start < 3.0:
        # Send heartbeat every 80ms
        if time.time() - last_hb >= 0.08:
            frame.echo_id = 0
            frame.can_id = hb_arb_id | GS_CAN_FLAG_EFF
            frame.can_dlc = 8
            frame.channel = 0
            frame.flags = 0
            frame.reserved = 0
            for j in range(8):
                frame.data[j] = hb_payload[j]
            dll.candle_frame_send(dev_handle, 0, ctypes.byref(frame), 1000)
            last_hb = time.time()

        # Read frames
        if dll.candle_frame_read(dev_handle, ctypes.byref(frame), 5):
            arb_id = frame.can_id & 0x1FFFFFFF
            d = decode_arb_id(arb_id)
            cls = d["api_class"]
            idx = d["api_index"]
            key = f"cls=0x{cls:02X}/idx={idx}"
            classes_seen[key] = classes_seen.get(key, 0) + 1
            total_rx += 1

    print(f"  Total frames received: {total_rx}")
    print("  Frame classes seen:")
    for key in sorted(classes_seen.keys()):
        print(f"    {key}: {classes_seen[key]} frames")

    # -----------------------------------------------------------------------
    # Cleanup
    # -----------------------------------------------------------------------
    print("\n=== Cleanup ===")
    dll.candle_channel_stop.restype = ctypes.c_bool
    dll.candle_channel_stop.argtypes = [ctypes.c_void_p, ctypes.c_uint8]
    dll.candle_channel_stop(dev_handle, 0)

    dll.candle_dev_close.restype = None
    dll.candle_dev_close.argtypes = [ctypes.c_void_p]
    dll.candle_dev_close(dev_handle)

    dll.candle_list_free.restype = None
    dll.candle_list_free.argtypes = [ctypes.c_void_p]
    dll.candle_list_free(list_ptr)

    print("[OK] All resources released")
    print("\n" + "=" * 60)
    if total_rx > 0 and len(discovered_ids) > 0:
        print("SUCCESS: SPARK MAX communicating via Candle without HC2!")
        print("The FFI fixes have eliminated the HC2 dependency.")
    elif total_rx > 0:
        print("PARTIAL: Receiving frames but no device IDs discovered.")
        print("Heartbeat may not be reaching the device.")
    else:
        print("FAIL: No CAN traffic received.")
        print("Check USB connection, WinUSB driver, and SPARK MAX power.")


if __name__ == "__main__":
    main()
