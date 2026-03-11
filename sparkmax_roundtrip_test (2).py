"""
SPARK MAX Parameter Round-Trip Test v2 - Firmware 26.x
=======================================================
Reads 10 parameters, captures the device's own type tag from each
read response, then writes using that exact type tag.

Also prints a full diagnostic table showing raw bytes + type tag
so mismatches between our table and reality are visible.

Requires: pip install pyserial
"""

import serial
import struct
import time

PORT = "COM12"
BAUD = 115200

DEVICE_TYPE  = 0x02
MANUFACTURER = 0x05

# 10 parameters to test: (name, param_id, our_assumed_ptype, test_value)
# IDs from official docs: https://docs.revrobotics.com/brushless/spark-max/parameters
TEST_PARAMS = [
    ("kInputDeadband",          2,   "float",  1),  # default 0.05
    ("kInputDeadband",          7,   "float",  0.10),  # default 0.05
    ("kRampRate",              56,   "float",  0.50),  # default 0.0  (was wrong: 8 is Reserved)
    ("kP_0",                   13,   "float",  0.001), # default 0.0  (was wrong: 9 is Reserved)
    ("kI_0",                   14,   "float",  0.001), # default 0.0  (was wrong: 10 is kPolePairs)
    ("kD_0",                   15,   "float",  0.001), # default 0.0  (was wrong: 11 is kCurrentChop)
    ("kF_0",                   16,   "float",  0.001), # default 0.0  (was wrong: 12 is kCurrentChopCycles)
    ("kOutputMin_0",           19,   "float", -0.90),  # default -1.0 (was wrong: 15 is kD_0)
    ("kOutputMax_0",           20,   "float",  0.90),  # default  1.0 (was wrong: 16 is kF_0)
    ("kSmartCurrentStallLimit",59,   "uint",   35),    # default 80A  (was wrong: 55 is Reserved)
    ("kSmartCurrentFreeLimit", 60,   "uint",   15),    # default 20A  (was wrong: 56 is kRampRate)
]

# Type tag constants (fw26 confirmed)
TAG_TO_NAME  = {0x00: "bool", 0x02: "int", 0x03: "float", 0x04: "uint"}
TAG_TO_PTYPE = {0x00: "bool", 0x02: "int", 0x03: "float", 0x04: "uint"}


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
        "device_type":  (can_id >> 24) & 0x1F,
        "manufacturer": (can_id >> 16) & 0xFF,
        "api_class":    (can_id >> 10) & 0x3F,
        "api_index":    (can_id >>  6) & 0x0F,
        "device_id":     can_id        & 0x3F,
    }

def slcan_encode(can_id, data):
    return f"T{can_id:08X}{len(data):1X}{data.hex().upper()}\r\n".encode('ascii')

def slcan_decode(line):
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

def collect_frames(ser, timeout=0.2):
    deadline = time.time() + timeout
    buf = b''
    frames = []
    while time.time() < deadline:
        chunk = ser.read(256)
        if chunk:
            buf += chunk
        while b'\r\n' in buf:
            line, buf = buf.split(b'\r\n', 1)
            r = slcan_decode(line.decode('ascii', errors='replace'))
            if r:
                frames.append(r)
    return frames

def discover_device_id(ser, secs=1.5):
    deadline = time.time() + secs
    buf = b''
    ids = set()
    while time.time() < deadline:
        chunk = ser.read(256)
        if chunk:
            buf += chunk
        while b'\r\n' in buf:
            line, buf = buf.split(b'\r\n', 1)
            r = slcan_decode(line.decode('ascii', errors='replace'))
            if r:
                can_id, _ = r
                d = decode_can_id(can_id)
                if d['device_type'] == DEVICE_TYPE and d['manufacturer'] == MANUFACTURER:
                    ids.add(d['device_id'])
    return sorted(ids)[0] if ids else None


class ParamInfo:
    def __init__(self, param_id, raw_bytes, type_tag, value_float, value_uint):
        self.param_id    = param_id
        self.raw_bytes   = raw_bytes
        self.type_tag    = type_tag
        self.ptype       = TAG_TO_PTYPE.get(type_tag, "float")
        self.value_float = value_float
        self.value_uint  = value_uint

    @property
    def display_value(self):
        if self.ptype == "float":
            return f"{self.value_float:.6g}"
        return str(self.value_uint)

    @property
    def type_name(self):
        return TAG_TO_NAME.get(self.type_tag, f"unk(0x{self.type_tag:02x})")


def read_param(ser, device_id, param_id):
    can_id  = make_can_id(7, 1, device_id)
    payload = bytes([param_id]) + b'\x00' * 7
    ser.reset_input_buffer()
    ser.write(slcan_encode(can_id, payload))
    frames = collect_frames(ser, 0.2)
    for resp_id, resp_data in frames:
        if resp_id == can_id and resp_data == payload:
            continue
        d = decode_can_id(resp_id)
        if (d['device_id'] == device_id and d['api_class'] == 7
                and len(resp_data) >= 8 and resp_data[0] == param_id):
            type_tag    = resp_data[6]
            raw_val     = resp_data[2:6]
            value_float = struct.unpack_from('<f', raw_val)[0]
            value_uint  = struct.unpack_from('<I', raw_val)[0]
            return ParamInfo(param_id, resp_data, type_tag, value_float, value_uint)
    return None


def write_param(ser, device_id, param_id, value, type_tag):
    ptype = TAG_TO_PTYPE.get(type_tag, "float")
    if ptype == "float":
        packed = struct.pack('<f', float(value))
    else:
        packed = struct.pack('<I', int(value))
    data   = bytes([param_id, 0x00]) + packed + bytes([type_tag, 0x00])
    can_id = make_can_id(7, 0, device_id)
    ser.reset_input_buffer()
    ser.write(slcan_encode(can_id, data))
    frames = collect_frames(ser, 0.2)
    for resp_id, resp_data in frames:
        if resp_id == can_id and resp_data == data:
            continue
        d = decode_can_id(resp_id)
        if (d['device_id'] == device_id and d['api_class'] == 7
                and len(resp_data) >= 8
                and resp_data[0] == param_id
                and resp_data[1] == 0x00
                and resp_data[7] == 0x00):
            return True
    return False


def values_match(a, b, type_tag):
    if type_tag == 0x03:
        return abs(float(a) - float(b)) < 1e-4
    return int(a) == int(b)


def main():
    print(f"Connecting to {PORT}...")
    try:
        ser = serial.Serial(PORT, BAUD, timeout=0.05)
    except Exception as e:
        print(f"ERROR: {e}")
        return
    time.sleep(0.3)
    ser.reset_input_buffer()

    device_id = discover_device_id(ser)
    if device_id is None:
        print("ERROR: No device found.")
        ser.close()
        return
    print(f"Device CAN ID: {device_id}\n")

    # ── Phase 1: Diagnostic read ──────────────────────────────────────────────
    print("PHASE 1 — Reading current state and device type tags")
    print(f"  {'Parameter':<28} {'ID':>3}  {'Device type':>12}  {'Our table':>10}  {'Raw bytes':>25}  Value")
    print("  " + "-" * 92)

    param_info = {}
    for name, param_id, assumed_ptype, _ in TEST_PARAMS:
        info = read_param(ser, device_id, param_id)
        if info is None:
            print(f"  {name:<28} {param_id:>3}  {'<no response>':>12}")
            continue
        param_info[param_id] = info
        match = "OK" if info.ptype == assumed_ptype else "MISMATCH <--"
        print(f"  {name:<28} {param_id:>3}  "
              f"{info.type_name:>12}  "
              f"{assumed_ptype:>10}  {match:<14}  "
              f"{info.raw_bytes.hex(' ')}  {info.display_value}")
        time.sleep(0.03)

    # ── Phase 2: Write test values using device's actual type tag ─────────────
    print(f"\nPHASE 2 — Writing test values using device's actual type tag")
    print(f"  {'Parameter':<28} {'ID':>3}  {'Original':>10}  {'Written':>10}  {'Confirm':>10}  {'Type':>8}  Result")
    print("  " + "-" * 90)

    originals = {}
    results   = []

    for name, param_id, _, test_val in TEST_PARAMS:
        if param_id not in param_info:
            print(f"  {name:<28} {param_id:>3}  {'—':>10}  {'—':>10}  {'—':>10}  {'—':>8}  SKIP")
            results.append((name, None))
            continue

        info = param_info[param_id]
        originals[param_id] = info

        # Convert test_val to the device's actual type
        if info.ptype == "float":
            write_val     = float(test_val)
            write_val_str = f"{write_val:.6g}"
        else:
            # If test_val was a tiny float like 0.001, use a sensible integer instead
            write_val     = int(round(float(test_val))) if abs(float(test_val)) < 1 else int(test_val)
            if write_val == int(info.value_uint):
                write_val += 1  # ensure we're writing a different value
            write_val_str = str(write_val)

        ack = write_param(ser, device_id, param_id, write_val, info.type_tag)
        time.sleep(0.03)

        confirm = read_param(ser, device_id, param_id)
        if confirm is None:
            ok           = False
            confirm_str  = "<read fail>"
        elif info.ptype == "float":
            ok           = values_match(confirm.value_float, write_val, 0x03)
            confirm_str  = f"{confirm.value_float:.6g}"
        else:
            ok           = values_match(confirm.value_uint, write_val, 0x02)
            confirm_str  = str(confirm.value_uint)

        ack_note   = "" if ack else " (no ACK)"
        result_str = "PASS" if ok else f"FAIL{ack_note}"
        result_pfx = "+" if ok else "!"
        print(f"  {result_pfx} {name:<27} {param_id:>3}  "
              f"{info.display_value:>10}  "
              f"{write_val_str:>10}  "
              f"{confirm_str:>10}  "
              f"{info.type_name:>8}  {result_str}")
        results.append((name, ok))
        time.sleep(0.03)

    passed  = sum(1 for _, ok in results if ok is True)
    failed  = sum(1 for _, ok in results if ok is False)
    skipped = sum(1 for _, ok in results if ok is None)
    print("  " + "-" * 90)
    print(f"  {passed} passed  |  {failed} failed  |  {skipped} skipped\n")

    # ── Phase 3: Restore originals ────────────────────────────────────────────
    print("PHASE 3 — Restoring original values")
    for name, param_id, _, _ in TEST_PARAMS:
        if param_id not in originals:
            continue
        info     = originals[param_id]
        orig_val = info.value_float if info.ptype == "float" else info.value_uint
        ack      = write_param(ser, device_id, param_id, orig_val, info.type_tag)
        time.sleep(0.03)
        verify   = read_param(ser, device_id, param_id)
        if verify is None:
            ok = False
        elif info.ptype == "float":
            ok = values_match(verify.value_float, orig_val, 0x03)
        else:
            ok = values_match(verify.value_uint, orig_val, 0x02)
        status = "+" if ok else "!"
        print(f"  {status} {name:<28} restored to {info.display_value}")
        time.sleep(0.03)

    print("\nDone.")
    ser.close()


if __name__ == "__main__":
    main()
