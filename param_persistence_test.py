"""
Test parameter writes using API Class=14 (fw26 modern path) vs Class=7 (legacy).

The REVLib-driver-2026.0.4 headers define:
  - PARAMETER_WRITE: API Class=14 (0x0E), Index=0 (request), Index=1 (response)
  - PARAMETER_READ:  API Class=15 (0x0F), Index=0 (request), Index=1 (response)

Our current code uses API Class=7 which works for immediate writes but
may not mark parameters as "dirty" for persistence.

This script tests both paths via Candle/CANBridge.dll to see which one
results in values that survive a burnFlash + power cycle.
"""

import ctypes
import ctypes.wintypes
import os
import time
import struct

DLL_PATH = (
    r"C:\Program Files (x86)\REV Robotics\REV Hardware Client\resources"
    r"\app.asar.unpacked\node_modules\@rev-robotics\can-bridge\prebuilds"
    r"\node_canbridge-win32-x64\CANBridge.dll"
)

DEV_ID = 10
DEV_TYPE = 0x02
MFR_REV = 0x05
CAN_BITRATE = 1000000

# gs_host_frame
class GsHostFrame(ctypes.Structure):
    _pack_ = 1
    _fields_ = [
        ("echo_id", ctypes.c_uint32),
        ("can_id", ctypes.c_uint32),
        ("can_dlc", ctypes.c_uint8),
        ("channel", ctypes.c_uint8),
        ("flags", ctypes.c_uint8),
        ("reserved", ctypes.c_uint8),
        ("data", ctypes.c_uint8 * 8),
    ]

GS_CAN_FLAG_EFF = 0x80000000


def build_arb_id(api_class, api_index, device_id=DEV_ID):
    return (DEV_TYPE << 24) | (MFR_REV << 16) | (api_class << 10) | (api_index << 6) | device_id


def decode_arb_id(arb_id):
    return {
        "api_class": (arb_id >> 10) & 0x3F,
        "api_index": (arb_id >> 6) & 0x0F,
        "device_id": arb_id & 0x3F,
    }


def init_candle():
    """Initialize Candle/WinUSB connection."""
    dll_dir = os.path.dirname(DLL_PATH)
    os.add_dll_directory(dll_dir)
    dll = ctypes.CDLL(DLL_PATH)
    
    # Bind functions
    dll.candle_list_scan.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    dll.candle_list_scan.restype = ctypes.c_bool
    
    dll.candle_list_length.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8)]
    dll.candle_list_length.restype = ctypes.c_bool
    
    dll.candle_dev_get.argtypes = [ctypes.c_void_p, ctypes.c_uint8, ctypes.POINTER(ctypes.c_void_p)]
    dll.candle_dev_get.restype = ctypes.c_bool
    
    dll.candle_dev_open.argtypes = [ctypes.c_void_p]
    dll.candle_dev_open.restype = ctypes.c_bool
    
    dll.candle_dev_close.argtypes = [ctypes.c_void_p]
    dll.candle_dev_close.restype = None
    
    dll.candle_channel_set_bitrate.argtypes = [ctypes.c_void_p, ctypes.c_uint8, ctypes.c_uint32]
    dll.candle_channel_set_bitrate.restype = ctypes.c_bool
    
    dll.candle_channel_start.argtypes = [ctypes.c_void_p, ctypes.c_uint8, ctypes.c_uint32]
    dll.candle_channel_start.restype = ctypes.c_bool
    
    dll.candle_channel_stop.argtypes = [ctypes.c_void_p, ctypes.c_uint8]
    dll.candle_channel_stop.restype = ctypes.c_bool
    
    dll.candle_frame_read.argtypes = [ctypes.c_void_p, ctypes.POINTER(GsHostFrame), ctypes.c_uint32]
    dll.candle_frame_read.restype = ctypes.c_bool
    
    dll.candle_frame_send.argtypes = [ctypes.c_void_p, ctypes.c_uint8, ctypes.POINTER(GsHostFrame), ctypes.c_uint32]
    dll.candle_frame_send.restype = ctypes.c_bool
    
    dll.candle_list_free.argtypes = [ctypes.c_void_p]
    dll.candle_list_free.restype = None
    
    # Scan
    list_ptr = ctypes.c_void_p()
    ok = dll.candle_list_scan(ctypes.byref(list_ptr))
    if not ok:
        raise RuntimeError("candle_list_scan failed")
    
    count = ctypes.c_uint8(0)
    ok = dll.candle_list_length(list_ptr, ctypes.byref(count))
    if not ok or count.value == 0:
        raise RuntimeError(f"No devices found (count={count.value})")
    
    print(f"Found {count.value} device(s)")
    
    dev = ctypes.c_void_p()
    ok = dll.candle_dev_get(list_ptr, 0, ctypes.byref(dev))
    if not ok:
        raise RuntimeError("candle_dev_get failed")
    
    if not dll.candle_dev_open(dev):
        raise RuntimeError("candle_dev_open failed")
    
    dll.candle_channel_set_bitrate(dev, 0, CAN_BITRATE)
    
    if not dll.candle_channel_start(dev, 0, 0):
        raise RuntimeError("candle_channel_start failed")
    
    return dll, list_ptr, dev


def send_frame(dll, dev, arb_id, payload):
    """Send a CAN frame."""
    frame = GsHostFrame()
    frame.echo_id = 0
    frame.can_id = arb_id | GS_CAN_FLAG_EFF
    frame.can_dlc = 8
    frame.channel = 0
    frame.flags = 0
    frame.reserved = 0
    for i in range(8):
        frame.data[i] = payload[i] if i < len(payload) else 0
    ok = dll.candle_frame_send(dev, 0, ctypes.byref(frame), 1000)
    return ok


def read_response(dll, dev, expected_class, timeout_ms=2000):
    """Read CAN frames until we find one matching expected_class or timeout."""
    frame = GsHostFrame()
    deadline = time.time() + timeout_ms / 1000.0
    
    while time.time() < deadline:
        ok = dll.candle_frame_read(dev, ctypes.byref(frame), 50)
        if ok:
            arb = frame.can_id & 0x1FFFFFFF
            d = decode_arb_id(arb)
            if d["api_class"] == expected_class and d["device_id"] == DEV_ID:
                data = bytes(frame.data[i] for i in range(8))
                return {"arb_id": arb, "data": data, **d}
    return None


def send_heartbeat(dll, dev):
    """Send a secondary heartbeat enabling device 10."""
    hb_arb = build_arb_id(0x0B, 0x02, 0)  # Class=11, Index=2, device_id=0
    payload = bytearray(8)
    payload[DEV_ID // 8] = 1 << (DEV_ID % 8)
    send_frame(dll, dev, hb_arb, payload)


def read_param_class7(dll, dev, param_id):
    """Read parameter using API Class=7, Index=1."""
    arb = build_arb_id(0x07, 0x01)
    payload = bytearray(8)
    payload[0] = param_id & 0xFF
    send_frame(dll, dev, arb, payload)
    resp = read_response(dll, dev, 0x07)
    if resp:
        data = resp["data"]
        type_tag = data[6]
        raw_value = data[2:6]
        if type_tag == 0x03:  # float
            value = struct.unpack("<f", raw_value)[0]
        else:
            value = struct.unpack("<I", raw_value)[0]
        return {"param_id": data[0], "type_tag": type_tag, "value": value, "raw": raw_value.hex()}
    return None


def write_param_class7(dll, dev, param_id, value, type_tag):
    """Write parameter using API Class=7, Index=0."""
    arb = build_arb_id(0x07, 0x00)
    payload = bytearray(8)
    payload[0] = param_id & 0xFF
    payload[1] = 0x00
    if type_tag == 0x03:
        struct.pack_into("<f", payload, 2, value)
    else:
        struct.pack_into("<I", payload, 2, int(value))
    payload[6] = type_tag
    payload[7] = 0x00
    return send_frame(dll, dev, arb, payload)


def read_param_class15(dll, dev, param_id):
    """Read parameter using API Class=15 (0x0F), Index=0."""
    arb = build_arb_id(0x0F, 0x00)
    payload = bytearray(8)
    payload[0] = param_id & 0xFF
    send_frame(dll, dev, arb, payload)
    resp = read_response(dll, dev, 0x0F)
    if resp:
        data = resp["data"]
        type_tag = data[6]
        raw_value = data[2:6]
        if type_tag == 0x03:
            value = struct.unpack("<f", raw_value)[0]
        else:
            value = struct.unpack("<I", raw_value)[0]
        return {"param_id": data[0], "type_tag": type_tag, "value": value, "raw": raw_value.hex(), "api_index": resp["api_index"]}
    return None


def write_param_class14(dll, dev, param_id, value, type_tag):
    """Write parameter using API Class=14 (0x0E), Index=0."""
    arb = build_arb_id(0x0E, 0x00)
    payload = bytearray(8)
    payload[0] = param_id & 0xFF
    payload[1] = 0x00
    if type_tag == 0x03:
        struct.pack_into("<f", payload, 2, value)
    else:
        struct.pack_into("<I", payload, 2, int(value))
    payload[6] = type_tag
    payload[7] = 0x00
    return send_frame(dll, dev, arb, payload)


def burn_flash(dll, dev):
    """Send persist parameters (burn flash) command."""
    arb = build_arb_id(0x3F, 0x0F)  # Class=63, Index=15
    payload = bytearray(8)
    struct.pack_into("<H", payload, 0, 15011)  # Magic 0x3AA3
    send_frame(dll, dev, arb, payload)
    time.sleep(0.5)
    # Look for ACK
    resp = read_response(dll, dev, 0x01, timeout_ms=2000)
    if resp:
        print(f"  Burn flash ACK: data={resp['data'].hex(' ')}")
        return resp["data"][0] == 0x00  # 0=success
    print("  No burn flash ACK received")
    return False


def drain_frames(dll, dev, duration=0.5):
    """Read and discard frames for a given duration."""
    frame = GsHostFrame()
    deadline = time.time() + duration
    count = 0
    while time.time() < deadline:
        if dll.candle_frame_read(dev, ctypes.byref(frame), 10):
            count += 1
    return count


def main():
    print("=== Parameter Write Persistence Test ===\n")
    
    dll, list_ptr, dev = init_candle()
    
    # Send heartbeats to wake up the device
    print("\nSending heartbeats...")
    for _ in range(5):
        send_heartbeat(dll, dev)
        time.sleep(0.05)
    
    drain_frames(dll, dev, 0.5)
    
    # --- Test Parameter: kParamSlot0D (param 15, float, PID D gain) ---
    TEST_PARAM = 15
    TEST_VALUE_A = 0.0
    TEST_VALUE_B = 0.12345
    
    print(f"\n=== Test: param {TEST_PARAM} (PID Slot 0 D gain) ===\n")
    
    # Step 1: Read current value via Class=7
    print("--- Step 1: Read current value (Class=7) ---")
    send_heartbeat(dll, dev)
    drain_frames(dll, dev, 0.2)
    result = read_param_class7(dll, dev, TEST_PARAM)
    if result:
        print(f"  Current: {result}")
    else:
        print("  FAILED to read via Class=7")
    
    # Step 2: Try read via Class=15
    print("\n--- Step 2: Read current value (Class=15) ---")
    send_heartbeat(dll, dev)
    drain_frames(dll, dev, 0.2)
    result15 = read_param_class15(dll, dev, TEST_PARAM)
    if result15:
        print(f"  Current: {result15}")
    else:
        print("  No response via Class=15 (expected for legacy firmware)")
    
    # Step 3: Write via Class=7, read back
    print(f"\n--- Step 3: Write {TEST_VALUE_B} via Class=7, read back ---")
    send_heartbeat(dll, dev)
    drain_frames(dll, dev, 0.2)
    write_param_class7(dll, dev, TEST_PARAM, TEST_VALUE_B, 0x03)
    time.sleep(0.1)
    drain_frames(dll, dev, 0.2)
    result7w = read_param_class7(dll, dev, TEST_PARAM)
    if result7w:
        print(f"  Read back (Class=7): {result7w}")
        matches = abs(result7w["value"] - TEST_VALUE_B) < 0.001
        print(f"  Matches: {matches}")
    
    # Step 4: Write via Class=14, read back
    print(f"\n--- Step 4: Write {TEST_VALUE_B + 0.1} via Class=14, read back ---")
    send_heartbeat(dll, dev)
    drain_frames(dll, dev, 0.2)
    write_param_class14(dll, dev, TEST_PARAM, TEST_VALUE_B + 0.1, 0x03)
    time.sleep(0.1)
    
    # Check for response on Class=14 (index=1 would be response)
    resp14 = read_response(dll, dev, 0x0E, timeout_ms=1000)
    if resp14:
        print(f"  Class=14 response: data={resp14['data'].hex(' ')}, idx={resp14['api_index']}")
    else:
        print("  No Class=14 response")
    
    drain_frames(dll, dev, 0.2)
    result14w = read_param_class7(dll, dev, TEST_PARAM)
    if result14w:
        print(f"  Read back (Class=7): {result14w}")
        expected = TEST_VALUE_B + 0.1
        matches = abs(result14w["value"] - expected) < 0.001
        print(f"  Matches expected {expected:.5f}: {matches}")
    
    # Step 5: Write a known value via Class=7, burn flash
    PERSIST_VALUE = 0.54321
    print(f"\n--- Step 5: Write {PERSIST_VALUE} via Class=7, burn flash ---")
    send_heartbeat(dll, dev)
    drain_frames(dll, dev, 0.2)
    write_param_class7(dll, dev, TEST_PARAM, PERSIST_VALUE, 0x03)
    time.sleep(0.1)
    drain_frames(dll, dev, 0.2)
    rb = read_param_class7(dll, dev, TEST_PARAM)
    if rb:
        print(f"  Pre-burn read: {rb}")
    
    print("\n  Burning flash...")
    send_heartbeat(dll, dev)
    drain_frames(dll, dev, 0.2)
    burn_ok = burn_flash(dll, dev)
    print(f"  Burn result: {'SUCCESS' if burn_ok else 'FAILED/NO ACK'}")
    
    # Read back after burn
    send_heartbeat(dll, dev)
    drain_frames(dll, dev, 0.5)
    rb_after = read_param_class7(dll, dev, TEST_PARAM)
    if rb_after:
        print(f"  Post-burn read: {rb_after}")
        matches = abs(rb_after["value"] - PERSIST_VALUE) < 0.001
        print(f"  Value persisted in RAM: {matches}")
    
    # Step 6: Reset to 0 and burn (cleanup)
    print(f"\n--- Step 6: Write 0.0 and burn (cleanup) ---")
    send_heartbeat(dll, dev)
    drain_frames(dll, dev, 0.2)
    write_param_class7(dll, dev, TEST_PARAM, 0.0, 0x03)
    time.sleep(0.1)
    drain_frames(dll, dev, 0.2)
    burn_flash(dll, dev)
    
    print(f"\n=== NEXT STEP ===")
    print(f"Power cycle the SPARK MAX, then run this script again")
    print(f"to check if the value persisted.")
    print(f"Expected: param {TEST_PARAM} should read {PERSIST_VALUE}")
    print(f"(unless cleanup burned 0.0 — in that case, comment out Step 6)")
    
    # Cleanup
    dll.candle_channel_stop(dev, 0)
    dll.candle_dev_close(dev)
    dll.candle_list_free(list_ptr)
    print("\nDone.")


if __name__ == "__main__":
    main()
