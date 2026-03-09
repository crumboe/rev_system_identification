"""
SPARK MAX Parameter Reader - Firmware 26.x (SLCAN Protocol)
============================================================
Firmware 26.x speaks SLCAN (Serial Line CAN) over USB, NOT raw binary.

Frame format (TX and RX):
  T{XXXXXXXX}{N}{DDDDDDDD...}\r\n
  T = extended CAN frame
  XXXXXXXX = 8 hex chars, 29-bit CAN ID (big-endian)
  N = DLC (number of data bytes, 1 hex char)
  DD... = 2*N hex chars of data
  \r\n = terminator

CAN ID bit layout (FRC standard):
  bits [28:24] = Device Type  = 0x02 (motor controller)
  bits [23:16] = Manufacturer = 0x05 (REV, changed from 0x15 in fw26)
  bits [15:10] = API Class
  bits  [9:6]  = API Index
  bits  [5:0]  = Device CAN ID

Requires: pip install pyserial
"""

import serial
import struct
import time
import threading

PORT     = "COM11"
BAUD     = 115200
DEVICE_TYPE  = 0x02
MANUFACTURER = 0x05  # firmware 26.x changed this from 0x15

# ── CAN ID builder ────────────────────────────────────────────────────────────

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

# ── SLCAN framing ─────────────────────────────────────────────────────────────

def slcan_encode(can_id: int, data: bytes) -> bytes:
    return f"T{can_id:08X}{len(data):1X}{data.hex().upper()}\r\n".encode('ascii')

def slcan_decode(line: str):
    """Parse a SLCAN line like 'T0205B80A80000520B0000A000'.
    Returns (can_id, data_bytes) or None if invalid."""
    line = line.strip()
    if not line.startswith('T') or len(line) < 10:
        return None
    try:
        can_id = int(line[1:9], 16)
        dlc    = int(line[9], 16)
        data   = bytes.fromhex(line[10:10 + dlc * 2])
        return can_id, data
    except Exception:
        return None

# ── Serial helpers ─────────────────────────────────────────────────────────────

def read_lines(ser, timeout=0.3):
    """Read all complete \r\n terminated lines within timeout seconds."""
    deadline = time.time() + timeout
    buf = b''
    lines = []
    while time.time() < deadline:
        chunk = ser.read(256)
        if chunk:
            buf += chunk
        while b'\r\n' in buf:
            line, buf = buf.split(b'\r\n', 1)
            lines.append(line.decode('ascii', errors='replace'))
    return lines

def send_and_listen(ser, can_id, data, wait=0.15):
    ser.reset_input_buffer()
    ser.write(slcan_encode(can_id, data))
    time.sleep(wait)
    raw = ser.read(512)
    lines = []
    for part in raw.split(b'\r\n'):
        s = part.decode('ascii', errors='replace').strip()
        if s:
            lines.append(s)
    return lines

# ── Discover device CAN ID ─────────────────────────────────────────────────────

def discover_device_id(ser, listen_secs=1.5):
    """
    The SPARK MAX streams periodic status frames continuously.
    Parse a few of them to extract the device CAN ID from bits [5:0].
    """
    print(f"Listening {listen_secs}s for periodic status frames...")
    deadline = time.time() + listen_secs
    buf = b''
    device_ids = set()
    while time.time() < deadline:
        chunk = ser.read(256)
        if chunk:
            buf += chunk
        while b'\r\n' in buf:
            line, buf = buf.split(b'\r\n', 1)
            result = slcan_decode(line.decode('ascii', errors='replace'))
            if result:
                can_id, _ = result
                d = decode_can_id(can_id)
                if d['device_type'] == DEVICE_TYPE and d['manufacturer'] == MANUFACTURER:
                    device_ids.add(d['device_id'])

    if not device_ids:
        print("  WARNING: No REV device frames detected. Defaulting device_id=0.")
        return 0
    if len(device_ids) > 1:
        print(f"  Multiple device IDs found: {device_ids}. Using lowest.")
    device_id = sorted(device_ids)[0]
    print(f"  Detected device CAN ID: {device_id}")
    return device_id

# ── Parameter read/write ───────────────────────────────────────────────────────

PARAM_READ_API_CLASS  = 7
PARAM_READ_API_INDEX  = 1
PARAM_WRITE_API_CLASS = 7
PARAM_WRITE_API_INDEX = 0

def read_param(ser, param_id, device_id, retries=2):
    req_can_id = make_can_id(PARAM_READ_API_CLASS, PARAM_READ_API_INDEX, device_id)
    req_data   = bytes([param_id]) + b'\x00' * 7

    for attempt in range(retries + 1):
        lines = send_and_listen(ser, req_can_id, req_data, wait=0.12)
        for line in lines:
            result = slcan_decode(line)
            if result is None:
                continue
            resp_id, resp_data = result
            d = decode_can_id(resp_id)
            # Accept any frame that looks like a param response:
            # - same device_id
            # - api_class 7 (direct param response) OR any other non-status class
            # - data[0] == param_id echo (optional check)
            if d['device_id'] == device_id and d['api_class'] == PARAM_READ_API_CLASS:
                if len(resp_data) >= 8:
                    return resp_id, resp_data

            # Also catch any response frame (not a periodic status frame)
            # Periodic status uses api_class=0x20 (32). Anything else might be our response.
            if d['device_id'] == device_id and d['api_class'] != 0x20:
                if len(resp_data) >= 5:
                    return resp_id, resp_data

    return None, None

def write_param(ser, param_id, value_float, device_id):
    req_can_id = make_can_id(PARAM_WRITE_API_CLASS, PARAM_WRITE_API_INDEX, device_id)
    req_data   = bytes([param_id]) + struct.pack('<f', value_float) + b'\x00' * 3
    lines = send_and_listen(ser, req_can_id, req_data, wait=0.12)
    # Look for ACK
    for line in lines:
        result = slcan_decode(line)
        if result:
            resp_id, resp_data = result
            d = decode_can_id(resp_id)
            if d['device_id'] == device_id and d['api_class'] != 0x20:
                return resp_id, resp_data
    return None, None

# ── Parameter table ──────────────────────────────────────────────────────────

PARAMETERS = [
    (0,  "kCanID",             "int"),
    (1,  "kInputMode",         "int"),
    (2,  "kMotorType",         "int"),
    (5,  "kCtrlType",          "int"),
    (6,  "kIdleMode",          "int"),
    (7,  "kInputDeadband",     "float"),
    (8,  "kRampRate",          "float"),
    (9,  "kP_0",               "float"),
    (10, "kI_0",               "float"),
    (11, "kD_0",               "float"),
    (12, "kF_0",               "float"),
    (13, "kIZone_0",           "float"),
    (14, "kDFilter_0",         "float"),
    (15, "kOutputMin_0",       "float"),
    (16, "kOutputMax_0",       "float"),
    (17, "kP_1",               "float"),
    (18, "kI_1",               "float"),
    (19, "kD_1",               "float"),
    (20, "kF_1",               "float"),
    (21, "kIZone_1",           "float"),
    (22, "kDFilter_1",         "float"),
    (23, "kOutputMin_1",       "float"),
    (24, "kOutputMax_1",       "float"),
    (43, "kSerialNumberLow",   "int"),
    (44, "kSerialNumberMid",   "int"),
    (45, "kSerialNumberHigh",  "int"),
    (46, "kLimitSwitchFwdPolarity", "bool"),
    (47, "kLimitSwitchRevPolarity", "bool"),
    (48, "kHardLimitFwdEn",    "bool"),
    (49, "kHardLimitRevEn",    "bool"),
    (50, "kSoftLimitFwdEn",    "bool"),
    (51, "kSoftLimitRevEn",    "bool"),
    (52, "kRampRate_1",        "float"),
    (53, "kFollowerID",        "int"),
    (55, "kSmartCurrentStallLimit", "int"),
    (56, "kSmartCurrentFreeLimit",  "int"),
    (59, "kMotorKv",           "float"),
    (60, "kMotorR",            "float"),
    (61, "kMotorL",            "float"),
    (65, "kEncoderCountsPerRev","int"),
    (66, "kEncoderAverageDepth","int"),
    (68, "kEncoderInverted",    "bool"),
    (70, "kVoltageCompMode",    "int"),
    (71, "kCompensatedNominalVoltage","float"),
    (96, "kSoftLimitFwd",      "float"),
    (97, "kSoftLimitRev",      "float"),
    (114,"kDutyCyclePositionFactor","float"),
    (115,"kDutyCycleVelocityFactor","float"),
    (116,"kDutyCycleInverted",  "bool"),
    (118,"kPositionPIDWrapEnable","bool"),
    (119,"kPositionPIDMinInput", "float"),
    (120,"kPositionPIDMaxInput", "float"),
]

MOTOR_TYPES = {0: "Brushed", 1: "Brushless"}
IDLE_MODES  = {0: "Coast",   1: "Brake"}
CTRL_TYPES  = {0: "DutyCycle", 1: "Velocity", 2: "Position", 3: "Voltage"}

def fmt_value(data, ptype):
    """Decode parameter value from an 8-byte response frame.

    Response layout (confirmed from fw26 SLCAN output):
      byte[0]   = param_id echo
      byte[1]   = 0xFF (status OK)
      bytes[2:6]= value, little-endian float32 / uint32
      byte[6]   = type tag: 0x00=bool, 0x02=int, 0x03=float, 0x04=uint
      byte[7]   = reserved
    """
    if len(data) < 7:
        return "?", None

    # status byte must be 0xFF for a valid response
    if data[1] != 0xFF:
        return f"<status=0x{data[1]:02X}>", None

    raw_float = struct.unpack_from('<f', data, 2)[0]
    raw_uint  = struct.unpack_from('<I', data, 2)[0]
    type_tag  = data[6]  # 0x00=bool, 0x02=int, 0x03=float, 0x04=uint

    # Use type_tag when available, fall back to ptype hint
    if type_tag == 0x00 or ptype == "bool":
        return str(bool(raw_uint)), raw_uint
    elif type_tag in (0x02, 0x04) or ptype == "int":
        return str(raw_uint), raw_uint
    else:
        return f"{raw_float:.6g}", raw_float

# ── Status frame decoder (for the live stream printout) ───────────────────────

def decode_status0(data):
    if len(data) < 8:
        return {}
    applied = struct.unpack_from('<h', data, 0)[0] / 32767.0
    faults  = struct.unpack_from('<H', data, 2)[0]
    sticky  = struct.unpack_from('<H', data, 4)[0]
    return {"applied_output": f"{applied:.3f}", "faults": f"0x{faults:04X}", "sticky_faults": f"0x{sticky:04X}"}

def decode_status1(data):
    if len(data) < 8:
        return {}
    velocity = struct.unpack_from('<f', data, 0)[0]
    temp     = data[4]
    voltage  = struct.unpack_from('<H', data, 5)[0] / 128.0
    current  = struct.unpack_from('<H', data, 7)[0] / 32.0 if len(data) > 7 else 0
    return {"velocity_rpm": f"{velocity:.1f}", "temp_C": temp, "voltage_V": f"{voltage:.2f}"}

def decode_status2(data):
    if len(data) < 4:
        return {}
    position = struct.unpack_from('<f', data, 0)[0]
    return {"position_rot": f"{position:.4f}"}

STATUS_DECODERS = {0: decode_status0, 1: decode_status1, 2: decode_status2}

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    print(f"Connecting to SPARK MAX on {PORT} at {BAUD} baud...")
    try:
        ser = serial.Serial(PORT, BAUD, timeout=0.05)
    except serial.SerialException as e:
        print(f"ERROR: {e}")
        return

    time.sleep(0.2)
    ser.reset_input_buffer()

    # --- Step 1: Discover device CAN ID from the live stream ---
    device_id = discover_device_id(ser)

    # --- Step 2: Show a few live status frames ---
    print(f"\nLive status frames (device CAN ID={device_id}):")
    print(f"  Param read  CAN ID: 0x{make_can_id(PARAM_READ_API_CLASS,  PARAM_READ_API_INDEX,  device_id):08X}")
    print(f"  Param write CAN ID: 0x{make_can_id(PARAM_WRITE_API_CLASS, PARAM_WRITE_API_INDEX, device_id):08X}")

    ser.reset_input_buffer()
    lines = read_lines(ser, timeout=0.5)
    status_seen = set()
    for line in lines:
        r = slcan_decode(line)
        if not r:
            continue
        can_id, data = r
        d = decode_can_id(can_id)
        if d['device_id'] == device_id and d['api_class'] == 0x20 and d['api_index'] not in status_seen:
            idx = d['api_index']
            status_seen.add(idx)
            decoded = STATUS_DECODERS.get(idx, lambda x: {})(data)
            print(f"  Status {idx}: {decoded}")

    # --- Step 3: Read parameters ---
    print(f"\n{'ID':<5} {'Parameter':<45} {'Value':<22} {'Raw resp ID'}")
    print("-" * 90)

    ok_count = 0
    err_count = 0

    for param_id, name, ptype in PARAMETERS:
        resp_id, resp_data = read_param(ser, param_id, device_id)

        if resp_data is None:
            print(f"{param_id:<5} {name:<45} {'<no response>'}")
            err_count += 1
            time.sleep(0.02)
            continue

        value_str, _ = fmt_value(resp_data, ptype)

        # Human-readable label for enums
        label = ""
        if param_id == 2:
            try: label = MOTOR_TYPES.get(int(value_str), "")
            except: pass
        elif param_id == 5:
            try: label = CTRL_TYPES.get(int(value_str), "")
            except: pass
        elif param_id == 6:
            try: label = IDLE_MODES.get(int(value_str), "")
            except: pass

        d = decode_can_id(resp_id)
        id_info = f"cls={d['api_class']} idx={d['api_index']}"
        display = f"{value_str}  {label}"
        print(f"{param_id:<5} {name:<45} {display:<22} [{id_info}]  raw={resp_data.hex()}")
        ok_count += 1
        time.sleep(0.01)

    print("-" * 90)
    print(f"Done. {ok_count} OK, {err_count} no response.")
    ser.close()


if __name__ == "__main__":
    main()
