"""
SPARK MAX Write API Systematic Probe - Firmware 26.x
=====================================================
The previous probe showed:
  - Writes on cls=7 idx=0 get a NAK with error byte[7]=0x02
  - The response comes back on cls=7 idx=1 (the READ api)
  - "type-at-6" layout only got a CAN echo (our own frame reflected back)

This script probes:
  1. All API indices on cls=7 for writes (maybe write moved to idx=2/3/4)
  2. Other API classes entirely (cls=5, cls=6, cls=8, cls=9)
  3. Whether a "write enable" / heartbeat frame is needed first
  4. Whether writing the exact read-response bytes back works (full mirror)
  5. What the error code byte[7] values mean across different payloads

Requires: pip install pyserial
"""

import serial
import struct
import time

PORT = "COM11"
BAUD = 115200

DEVICE_TYPE  = 0x02
MANUFACTURER = 0x05

PROBE_PARAM_ID = 7               # kInputDeadband - safe float
# PROBE_VALUE will be read dynamically from the device at startup
PROBE_VALUE    = None

# A different value to confirm actual write (not just echo)
TEST_VALUE     = 0.06
TEST_BYTES     = struct.pack('<f', TEST_VALUE)


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

def send_recv(ser, can_id, data, timeout=0.2):
    ser.reset_input_buffer()
    ser.write(slcan_encode(can_id, data))
    time.sleep(timeout)
    raw = ser.read(512)
    frames = []
    for part in raw.split(b'\r\n'):
        s = part.decode('ascii', errors='replace').strip()
        if not s:
            continue
        r = slcan_decode(s)
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
    return sorted(ids)[0] if ids else 0

def read_param(ser, device_id, param_id):
    data   = bytes([param_id]) + b'\x00' * 7
    can_id = make_can_id(7, 1, device_id)
    sent_can_id = can_id
    frames = send_recv(ser, can_id, data)
    for resp_id, resp_data in frames:
        d = decode_can_id(resp_id)
        # Exclude echo of our own frame
        if resp_id == sent_can_id and resp_data == data:
            continue
        if d['device_id'] == device_id and d['api_class'] == 7 and len(resp_data) >= 7:
            return resp_data
    return None

def print_response(frames, sent_can_id, sent_data, device_id):
    """Print all non-status, non-echo frames."""
    shown = False
    for resp_id, resp_data in frames:
        d = decode_can_id(resp_id)
        # Skip status stream
        if d['api_class'] == 0x20 or d['api_class'] == 0x2E:
            continue
        # Note if it's an echo
        is_echo = (resp_id == sent_can_id and resp_data == sent_data)
        tag = " [ECHO]" if is_echo else " [DEVICE RESPONSE]"
        b7 = f"0x{resp_data[7]:02x}" if len(resp_data) > 7 else "?"
        print(f"    recv cls={d['api_class']:2d} idx={d['api_index']} : "
              f"{resp_data.hex(' ')}  b7={b7}{tag}")
        shown = True
    if not shown:
        print("    recv: <no non-status frames>")

def probe_write(ser, device_id, label, api_class, api_index, payload, read_back=True):
    can_id = make_can_id(api_class, api_index, device_id)
    print(f"\n  [{label}]")
    print(f"    send cls={api_class:2d} idx={api_index} CAN=0x{can_id:08X} : {payload.hex(' ')}")

    frames = send_recv(ser, can_id, payload)
    print_response(frames, can_id, payload, device_id)

    if read_back:
        time.sleep(0.05)
        rb = read_param(ser, device_id, PROBE_PARAM_ID)
        if rb:
            val = struct.unpack_from('<f', rb, 2)[0]
            changed = abs(val - PROBE_VALUE) > 0.0001 if PROBE_VALUE is not None else False
            mark = " *** WRITE SUCCEEDED ***" if changed else " (unchanged)"
            print(f"    readback: {rb.hex(' ')} → float={val:.6g}{mark}")
        else:
            print(f"    readback: <no response>")
    time.sleep(0.05)


def main():
    global PROBE_VALUE
    print(f"Opening {PORT}...")
    ser = serial.Serial(PORT, BAUD, timeout=0.05)
    time.sleep(0.2)
    ser.reset_input_buffer()

    device_id = discover_device_id(ser)
    print(f"Device CAN ID: {device_id}")

    # =====================================================================
    # FULL SWEEP: all 64 apiClass values (0x00–0x3F), idx=0
    # With 2 payload formats, on param 7 (kInputDeadband)
    # =====================================================================

    PARAM_ID = 7  # kInputDeadband, safe float param

    # Read baseline
    rb = read_param(ser, device_id, PARAM_ID)
    if not rb:
        print("ERROR: Could not read baseline")
        ser.close()
        return

    baseline = struct.unpack_from('<f', rb, 2)[0]
    print(f"Baseline param {PARAM_ID}: {rb.hex(' ')}  float={baseline:.6g}")

    TEST_VAL = 0.06 if abs(baseline - 0.06) > 0.0001 else 0.07
    test_bytes = struct.pack('<f', TEST_VAL)
    print(f"Test value: {TEST_VAL} = {test_bytes.hex(' ')}")

    # Two payload formats
    payloads = [
        ("[p][00][val][00*2]", bytes([PARAM_ID, 0x00]) + test_bytes + b'\x00\x00'),
        ("[p][val][00*3]",     bytes([PARAM_ID]) + test_bytes + b'\x00' * 3),
    ]

    print(f"\n{'='*75}")
    print(f"FULL API CLASS SWEEP: cls=0x00..0x3F, idx=0, param={PARAM_ID}")
    print(f"  2 payload formats × 64 classes = 128 attempts")
    print(f"{'='*75}")

    results = []

    # PHASE 1: Fast scan — just send and check for ANY response (no readbacks)
    print("\n  Phase 1: Fast response scan...")
    for cls in range(0x40):  # 0x00 to 0x3F
        for fmt_name, payload in payloads:
            can_id = make_can_id(cls, 0, device_id)

            ser.reset_input_buffer()
            ser.write(slcan_encode(can_id, payload))
            time.sleep(0.08)
            raw = ser.read(1024)

            # Parse responses
            got_response = False
            resp_info = ""
            for part in raw.split(b'\r\n'):
                s = part.decode('ascii', errors='replace').strip()
                if not s:
                    continue
                r = slcan_decode(s)
                if not r:
                    continue
                resp_id, resp_data = r
                d = decode_can_id(resp_id)
                if d['api_class'] in (0x20, 0x2E, 0x2F):
                    continue
                is_echo = (resp_id == can_id and resp_data == payload)
                if is_echo:
                    continue
                got_response = True
                b7 = f"0x{resp_data[7]:02x}" if len(resp_data) > 7 else "?"
                resp_info = f"cls=0x{d['api_class']:02X} idx={d['api_index']} data={resp_data.hex(' ')} b7={b7}"

            if got_response:
                print(f"    cls=0x{cls:02X} {fmt_name:<20} → {resp_info}")

            results.append((cls, fmt_name, got_response, False, resp_info))

    # PHASE 2: For classes that got a response, do a proper readback test
    responded_classes = set(r[0] for r in results if r[2])
    print(f"\n  Phase 2: Readback test on {len(responded_classes)} responsive classes...")
    
    final_results = []
    for cls in sorted(responded_classes):
        for fmt_name, payload in payloads:
            can_id = make_can_id(cls, 0, device_id)

            ser.reset_input_buffer()
            ser.write(slcan_encode(can_id, payload))
            time.sleep(0.12)
            ser.read(1024)  # drain

            time.sleep(0.05)
            rb2 = read_param(ser, device_id, PARAM_ID)
            changed = False
            if rb2:
                val2 = struct.unpack_from('<f', rb2, 2)[0]
                changed = abs(val2 - baseline) > 0.0001
                if changed:
                    restore = bytes([PARAM_ID, 0x00]) + struct.pack('<f', baseline) + b'\x00\x00'
                    send_recv(ser, make_can_id(7, 0, device_id), restore)
                    time.sleep(0.1)
            
            mark = "*** CHANGED ***" if changed else "unchanged"
            print(f"    cls=0x{cls:02X} {fmt_name:<20} → {mark}")
            final_results.append((cls, fmt_name, True, changed, ""))

    # =====================================================================
    # SUMMARY
    # =====================================================================
    print(f"\n{'='*75}")
    print("SUMMARY — classes that got ANY device response:")
    print(f"{'='*75}")
    print(f"  {'cls':<8} {'Format':<22} {'Changed?':<12} {'Response'}")
    print(f"  {'-'*70}")

    responded = [r for r in results if r[2]]
    if responded:
        for cls, fmt, got_resp, changed, info in responded:
            print(f"  0x{cls:02X}    {fmt:<22} {info}")
    else:
        print("  (none)")

    successes = [r for r in final_results if r[3]]
    if successes:
        print(f"\n  ✓ WRITES SUCCEEDED on:")
        for cls, fmt, _, _, _ in successes:
            print(f"    cls=0x{cls:02X} {fmt}")
    else:
        print(f"\n  ✗ NO writes succeeded across all 64 API classes")

    print(f"\n{'='*75}")
    print("Done.")
    ser.close()


if __name__ == "__main__":
    main()
