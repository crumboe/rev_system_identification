"""
Candle/WinUSB initialization test — diagnose why connection fails after power cycle.

Uses CANBridge.dll directly via ctypes to test the gs_usb initialization sequence.
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

# CAN bitrate for SPARK MAX (1 Mbps)
CAN_BITRATE = 1000000

# gs_host_frame struct: echo_id(4) + can_id(4) + dlc(1) + ch(1) + flags(1) + rsv(1) + data(8) = 20 bytes
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


def decode_can_id(can_id):
    return {
        "device_type":  (can_id >> 24) & 0x1F,
        "manufacturer": (can_id >> 16) & 0xFF,
        "api_class":    (can_id >> 10) & 0x3F,
        "api_index":    (can_id >>  6) & 0x0F,
        "device_id":     can_id        & 0x3F,
    }


def main():
    print(f"Loading {DLL_PATH}...")
    dll_dir = os.path.dirname(DLL_PATH)
    # Add DLL directory so dependent DLLs (wpiHal.dll, wpiutil.dll) can be found
    os.add_dll_directory(dll_dir)
    dll = ctypes.CDLL(DLL_PATH)

    # Bind functions — note: all functions use cdecl on x64
    dll.candle_list_scan.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    dll.candle_list_scan.restype = ctypes.c_bool

    dll.candle_list_length.argtypes = [ctypes.c_void_p]
    dll.candle_list_length.restype = ctypes.c_uint8

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

    dll.candle_dev_last_error.argtypes = [ctypes.c_void_p]
    dll.candle_dev_last_error.restype = ctypes.c_int32

    dll.candle_dev_get_path.argtypes = [ctypes.c_void_p]
    dll.candle_dev_get_path.restype = ctypes.c_wchar_p

    dll.candle_dev_get_name.argtypes = [ctypes.c_void_p]
    dll.candle_dev_get_name.restype = ctypes.c_wchar_p

    # --- Step 1: Scan ---
    print("\n--- Step 1: Scan for devices ---")
    list_ptr = ctypes.c_void_p()
    ok = dll.candle_list_scan(ctypes.byref(list_ptr))
    print(f"  candle_list_scan: {ok}, list_ptr=0x{list_ptr.value or 0:X}")
    if not ok or not list_ptr.value:
        print("  FAILED: No WinUSB CAN devices found.")
        return

    # candle_list_length may take an output pointer: (list, *count) -> bool
    dll.candle_list_length.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8)]
    dll.candle_list_length.restype = ctypes.c_bool
    count_out = ctypes.c_uint8(0)
    ok2 = dll.candle_list_length(list_ptr, ctypes.byref(count_out))
    count = count_out.value
    print(f"  candle_list_length: ok={ok2}, count={count}")
    if count == 0:
        dll.candle_list_free(list_ptr)
        print("  FAILED: Device count is 0.")
        return

    # --- Step 2: Get device handle ---
    print("\n--- Step 2: Get device handle ---")
    dev_handle = ctypes.c_void_p()
    ok = dll.candle_dev_get(list_ptr, 0, ctypes.byref(dev_handle))
    print(f"  candle_dev_get(0): {ok}")
    if not ok or not dev_handle.value:
        dll.candle_list_free(list_ptr)
        print("  FAILED: Could not get device handle.")
        return

    path = dll.candle_dev_get_path(dev_handle)
    name = dll.candle_dev_get_name(dev_handle)
    print(f"  Path: {path}")
    print(f"  Name: {name}")

    # --- Step 3: Open device ---
    print("\n--- Step 3: Open device ---")
    ok = dll.candle_dev_open(dev_handle)
    print(f"  candle_dev_open: {ok}")
    if not ok:
        err = dll.candle_dev_last_error(dev_handle)
        print(f"  FAILED: error code {err}")
        dll.candle_list_free(list_ptr)
        return

    # --- Step 4: Set bitrate ---
    print(f"\n--- Step 4: Set bitrate to {CAN_BITRATE} ---")
    ok = dll.candle_channel_set_bitrate(dev_handle, 0, CAN_BITRATE)
    print(f"  candle_channel_set_bitrate(ch=0, {CAN_BITRATE}): {ok}")
    if not ok:
        err = dll.candle_dev_last_error(dev_handle)
        print(f"  WARNING: set_bitrate failed (error {err}) — continuing anyway")

    # --- Step 5: Start channel ---
    print("\n--- Step 5: Start channel ---")
    ok = dll.candle_channel_start(dev_handle, 0, 0)
    print(f"  candle_channel_start(ch=0, flags=0): {ok}")
    if not ok:
        err = dll.candle_dev_last_error(dev_handle)
        print(f"  FAILED: error code {err}")
        dll.candle_dev_close(dev_handle)
        dll.candle_list_free(list_ptr)
        return

    # --- Step 6: Read frames for 3 seconds ---
    print("\n--- Step 6: Reading CAN frames for 3 seconds ---")
    frame = GsHostFrame()
    rx_count = 0
    deadline = time.time() + 3.0

    while time.time() < deadline:
        ok = dll.candle_frame_read(dev_handle, ctypes.byref(frame), 10)
        if ok:
            arb = frame.can_id & 0x1FFFFFFF
            d = decode_can_id(arb)
            data_bytes = bytes(frame.data[i] for i in range(frame.can_dlc))
            rx_count += 1
            if rx_count <= 20:
                print(f"  RX #{rx_count:3d}: 0x{arb:08X} cls={d['api_class']:2d} "
                      f"idx={d['api_index']:2d} dev={d['device_id']:2d} "
                      f"[{data_bytes.hex(' ')}]")

    print(f"\n  Total frames received: {rx_count}")

    # --- Step 7: Try a param read (paramId=6, idle mode) ---
    if rx_count > 0:
        # Find device ID from a received frame
        ok2 = dll.candle_frame_read(dev_handle, ctypes.byref(frame), 100)
        if ok2:
            dev_id = frame.can_id & 0x3F
        else:
            dev_id = 10  # fallback
        print(f"\n--- Step 7: Param read test (idle mode, param 6) to device {dev_id} ---")
        arb_id = (0x02 << 24) | (0x05 << 16) | (0x07 << 10) | (0x01 << 6) | dev_id
        tx_frame = GsHostFrame()
        tx_frame.echo_id = 0
        tx_frame.can_id = arb_id | GS_CAN_FLAG_EFF
        tx_frame.can_dlc = 8
        tx_frame.channel = 0
        tx_frame.flags = 0
        tx_frame.reserved = 0
        tx_frame.data[0] = 6  # param ID
        for i in range(1, 8):
            tx_frame.data[i] = 0

        ok = dll.candle_frame_send(dev_handle, 0, ctypes.byref(tx_frame), 1000)
        print(f"  candle_frame_send: {ok}")

        # Read response
        resp_deadline = time.time() + 1.0
        found_response = False
        while time.time() < resp_deadline:
            ok = dll.candle_frame_read(dev_handle, ctypes.byref(frame), 10)
            if ok:
                arb = frame.can_id & 0x1FFFFFFF
                d = decode_can_id(arb)
                data_bytes = bytes(frame.data[i] for i in range(frame.can_dlc))
                if d['api_class'] == 7 and d['device_id'] == dev_id and frame.data[1] == 0xFF:
                    print(f"  PARAM RESPONSE: 0x{arb:08X} [{data_bytes.hex(' ')}]")
                    print(f"  Param ID: {frame.data[0]}, Value bytes: {data_bytes[2:6].hex(' ')}, "
                          f"Type tag: 0x{frame.data[6]:02X}")
                    found_response = True
                    break
        if not found_response:
            print("  No param response received within 1s")

    # --- Cleanup ---
    print("\n--- Cleanup ---")
    dll.candle_channel_stop(dev_handle, 0)
    dll.candle_dev_close(dev_handle)
    dll.candle_list_free(list_ptr)
    print("Done.")


if __name__ == "__main__":
    main()
