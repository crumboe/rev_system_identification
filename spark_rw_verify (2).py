"""
SPARK MAX — Read / Write / Verify / Burn  (fw26 corrected protocol)
====================================================================
Protocol confirmed from RHC2 pcap capture:

  SLCAN init : S8\\r  then  O\\r
  Read       : cls=0x07 idx=0x01  (T frame, confirmed working)
  Write      : cls=0x0E idx=0x00  payload=[param_id][value 4B LE]  (5 bytes, no type tag)
  Write ACK  : cls=0x0E idx=0x01  response=[param_id][type_tag][value 4B LE][flags]
               ACK is any response where data[0]==param_id and data[1]==type_tag
  Burn flash : cls=0x3F idx=0x0F  payload=0xa3 0x3a  (magic 2-byte token)
  Burn ACK   : cls=0x01 idx=0x04  payload=0x00  (~125ms later)

Usage:
    python spark_rw_verify.py
    python spark_rw_verify.py --port COM11 --device 10 --param 7 --value 0.05
    python spark_rw_verify.py --param 6 --value 1 --restore

Requires: pip install pyserial
"""

import serial
import struct
import time
import argparse

# ── Config ────────────────────────────────────────────────────────────────────

DEFAULT_PORT      = "COM12"
DEFAULT_DEVICE_ID = 10
DEFAULT_PARAM_ID  = 7      # kInputDeadband — safe float param
DEFAULT_VALUE     = 0.05   # factory default

DEVICE_TYPE  = 0x02
MANUFACTURER = 0x05

TYPE_NAMES = {0x00: "bool", 0x02: "int", 0x03: "float", 0x04: "uint"}

BURN_FLASH_MAGIC = bytes([0xa3, 0x3a])

# ── CAN ID helpers ────────────────────────────────────────────────────────────

def make_can_id(api_class, api_index, device_id):
    return (
        (DEVICE_TYPE  & 0x1F) << 24 |
        (MANUFACTURER & 0xFF) << 16 |
        (api_class    & 0x3F) << 10 |
        (api_index    & 0x0F) << 6  |
        (device_id    & 0x3F)
    )

def decode_can_id(can_id):
    return {
        "api_class": (can_id >> 10) & 0x3F,
        "api_index": (can_id >>  6) & 0x0F,
        "device_id":  can_id        & 0x3F,
    }

# ── SLCAN framing ─────────────────────────────────────────────────────────────

def slcan_encode(can_id, data: bytes) -> bytes:
    return f"T{can_id:08X}{len(data):X}{data.hex().upper()}\r".encode('ascii')

def slcan_decode(line: str):
    line = line.strip()
    if not line.startswith('T') or len(line) < 10:
        return None
    try:
        can_id = int(line[1:9], 16)
        dlc    = int(line[9],   16)
        data   = bytes.fromhex(line[10:10 + dlc * 2])
        return can_id, data
    except Exception:
        return None

# ── Serial read helper ────────────────────────────────────────────────────────

def wait_for(ser, match_fn, timeout=0.5):
    """Read frames until match_fn(can_id, data) returns True. Returns (can_id, data) or None."""
    deadline = time.time() + timeout
    buf = b''
    while time.time() < deadline:
        chunk = ser.read(256)
        if chunk:
            buf += chunk
        while b'\r' in buf:
            line, buf = buf.split(b'\r', 1)
            f = slcan_decode(line.decode('ascii', errors='replace'))
            if f and match_fn(*f):
                return f
    return None

# ── SLCAN init ────────────────────────────────────────────────────────────────

def slcan_init(ser):
    """S8 (1 Mbps) + O (open channel) — required before any T frames."""
    ser.reset_input_buffer()
    ser.write(b'S8\r')
    time.sleep(0.02)
    ser.write(b'O\r')
    time.sleep(0.1)
    ser.reset_input_buffer()
    print("  SLCAN init sent (S8 + O)")

# ── Parameter read (cls=0x07) ─────────────────────────────────────────────────

def read_param(ser, param_id, device_id):
    """
    cls=0x07 idx=0x01  request  : [param_id, 0x00 x7]
    cls=0x07 idx=0x01  response : [param_id, 0xFF, value(4LE), type_tag, 0x00]
    Returns (value, type_tag) or None.
    """
    can_id  = make_can_id(0x07, 0x01, device_id)
    payload = bytes([param_id]) + b'\x00' * 7
    ser.write(slcan_encode(can_id, payload))

    def is_response(resp_id, data):
        d = decode_can_id(resp_id)
        return (d['api_class'] == 0x07
                and d['device_id'] == device_id
                and len(data) >= 7
                and data[0] == param_id
                and data[1] == 0xFF)

    result = wait_for(ser, is_response)
    if result is None:
        return None

    _, data  = result
    type_tag = data[6]
    value    = struct.unpack('<f', data[2:6])[0] if type_tag == 0x03 else struct.unpack('<I', data[2:6])[0]
    return value, type_tag

# ── Parameter write (cls=0x0E) ────────────────────────────────────────────────

def write_param(ser, param_id, value, type_tag, device_id):
    """
    cls=0x0E idx=0x00  request  : [param_id, value(4LE)]  — 5 bytes, no type tag
    cls=0x0E idx=0x01  response : [param_id, type_tag, value(4LE), flags]
    ACK = any response where data[0]==param_id and data[1]==type_tag.
    Returns True (ACK) or None (timeout).
    """
    raw     = struct.pack('<f', float(value)) if type_tag == 0x03 else struct.pack('<I', int(value))
    can_id  = make_can_id(0x0E, 0x00, device_id)
    payload = bytes([param_id]) + raw  # 5 bytes only — no type tag, no trailing 0x00

    ser.reset_input_buffer()
    ser.write(slcan_encode(can_id, payload))

    def is_response(resp_id, data):
        d = decode_can_id(resp_id)
        # Any response on cls=0x0E idx=0x01 with matching param_id and type_tag = ACK
        return (d['api_class'] == 0x0E and d['api_index'] == 0x01
                and d['device_id'] == device_id
                and len(data) >= 2
                and data[0] == param_id
                and data[1] == type_tag)

    result = wait_for(ser, is_response)
    return result is not None

# ── Burn flash (cls=0x3F idx=0x0F) ───────────────────────────────────────────

def burn_flash(ser, device_id):
    """
    cls=0x3F idx=0x0F  payload=0xa3 0x3a  (magic token)
    ACK: cls=0x01 idx=0x04  payload=0x00  (~125ms later)
    Returns True on ACK, False on timeout.
    """
    can_id = make_can_id(0x3F, 0x0F, device_id)
    ser.reset_input_buffer()
    ser.write(slcan_encode(can_id, BURN_FLASH_MAGIC))

    def is_ack(resp_id, data):
        d = decode_can_id(resp_id)
        return (d['api_class'] == 0x01 and d['api_index'] == 0x04
                and d['device_id'] == device_id)

    return wait_for(ser, is_ack, timeout=0.5) is not None

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="SPARK MAX read/write/verify/burn (fw26)")
    parser.add_argument("--port",    default=DEFAULT_PORT,      help="Serial port (default: COM11)")
    parser.add_argument("--device",  default=DEFAULT_DEVICE_ID, type=int, help="CAN device ID (default: 10)")
    parser.add_argument("--param",   default=DEFAULT_PARAM_ID,  type=int, help="Parameter ID (default: 7 = kInputDeadband)")
    parser.add_argument("--value",   default=None,              type=float, help="Value to write")
    parser.add_argument("--restore", action="store_true",       help="Restore original value and re-burn after verify")
    args = parser.parse_args()

    print(f"\nSPARK MAX Read/Write/Verify/Burn  (fw26 protocol)")
    print(f"  Port      : {args.port}")
    print(f"  Device ID : {args.device}")
    print(f"  Param ID  : {args.param}")
    print()

    # ── Connect ────────────────────────────────────────────────────────────────
    print("[ 1 ] Connecting...")
    ser = serial.Serial(args.port, 115200, timeout=0.05)
    time.sleep(0.3)
    slcan_init(ser)

    # ── Read ───────────────────────────────────────────────────────────────────
    print(f"\n[ 2 ] Reading param {args.param}...")
    result = read_param(ser, args.param, args.device)
    if result is None:
        print("  ERROR: No response — check port, device ID, and connections.")
        ser.close()
        return

    original_value, type_tag = result
    type_name = TYPE_NAMES.get(type_tag, f"0x{type_tag:02X}")
    print(f"  Value    : {original_value}")
    print(f"  Type tag : 0x{type_tag:02X} ({type_name})")

    # ── Determine write value ──────────────────────────────────────────────────
    if args.value is not None:
        write_value = args.value
    elif type_tag == 0x03:
        write_value = round(float(original_value) + 0.001, 6)
        print(f"\n  No --value given, nudging by 0.001 → {write_value}")
    else:
        write_value = int(original_value)
        print(f"\n  No --value given, writing same value back: {write_value}")

    # ── Write ──────────────────────────────────────────────────────────────────
    print(f"\n[ 3 ] Writing param {args.param} = {write_value} ({type_name})...")
    ack = write_param(ser, args.param, write_value, type_tag, args.device)
    if ack:
        print("  ACK — write accepted")
    else:
        print("  TIMEOUT — no response received")
        ser.close()
        return

    # ── Verify ─────────────────────────────────────────────────────────────────
    print(f"\n[ 4 ] Verifying...")
    time.sleep(0.05)
    result2 = read_param(ser, args.param, args.device)
    if result2 is None:
        print("  ERROR: No response to verify read.")
        ser.close()
        return

    verify_value, _ = result2
    print(f"  Read back: {verify_value}")

    match = (abs(float(verify_value) - float(write_value)) < 1e-4
             if type_tag == 0x03 else int(verify_value) == int(write_value))

    if not match:
        print(f"  FAIL — expected {write_value}, got {verify_value}")
        ser.close()
        return
    print("  PASS — value matches")

    # ── Burn flash ─────────────────────────────────────────────────────────────
    print(f"\n[ 5 ] Burning to flash...")
    if burn_flash(ser, args.device):
        print("  ACK — value will persist across power cycle")
    else:
        print("  TIMEOUT — no burn ACK (value in RAM but may not have persisted)")

    # ── Restore ────────────────────────────────────────────────────────────────
    if args.restore:
        print(f"\n[ 6 ] Restoring original value ({original_value})...")
        time.sleep(0.1)
        ack = write_param(ser, args.param, original_value, type_tag, args.device)
        if ack:
            print(f"  Restored to {original_value}")
            print(f"\n[ 7 ] Burning restored value...")
            if burn_flash(ser, args.device):
                print("  ACK — restore persisted")
            else:
                print("  TIMEOUT — restore burn failed")
        else:
            print(f"  WARNING: Restore write timed out")

    print()
    ser.close()


if __name__ == "__main__":
    main()
