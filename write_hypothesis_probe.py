"""
Probe: Test remaining write hypotheses on actual device.
  1. device_id=0 (USB self-address) for writes
  2. SLCAN init commands (C/S6/O) before write
  3. byte[1] type tag variants (0x03=float, 0x02=int, etc.)
  4. Combined: init + devId=0 + type tag
"""
import serial, struct, time

PORT = 'COM11'
BAUD = 115200
DEV_TYPE = 0x02
MFR = 0x05

def make_can_id(cls, idx, dev):
    return (DEV_TYPE << 24) | (MFR << 16) | (cls << 10) | (idx << 6) | dev

def slcan_encode(cid, data):
    return f'T{cid:08X}{len(data):X}{data.hex().upper()}\r\n'.encode()

def slcan_decode(s):
    s = s.strip()
    if not s.startswith('T') or len(s) < 10:
        return None
    try:
        cid = int(s[1:9], 16)
        n = int(s[9], 16)
        d = bytes.fromhex(s[10:10 + n * 2])
        return (cid, d)
    except Exception:
        return None

def decode_can_id(cid):
    return {
        'api_class': (cid >> 10) & 0x3F,
        'api_index': (cid >> 6) & 0xF,
        'dev_id': cid & 0x3F,
    }

def send_recv(ser, cid, data, t=0.15):
    ser.reset_input_buffer()
    ser.write(slcan_encode(cid, data))
    time.sleep(t)
    raw = ser.read(4096)
    frames = []
    for part in raw.split(b'\r\n'):
        s = part.decode('ascii', errors='replace').strip()
        if s:
            r = slcan_decode(s)
            if r:
                frames.append(r)
    return frames

def get_write_response(frames, sent_cid, sent_data):
    """Return (b7, full_data) for first non-status non-echo response, or None."""
    for fid, fd in frames:
        d = decode_can_id(fid)
        if d['api_class'] in (0x20, 0x2E, 0x2F):
            continue
        if fid == sent_cid and fd == sent_data:
            continue  # echo
        b7 = fd[7] if len(fd) > 7 else None
        return (b7, fd, d)
    return None

def read_param(ser, did, pid):
    frames = send_recv(ser, make_can_id(7, 1, did), bytes([pid]) + b'\x00' * 7)
    for fid, fd in frames:
        d = decode_can_id(fid)
        if d['api_class'] == 7 and d['api_index'] == 1 and len(fd) >= 6 and fd[0] == pid:
            return fd
    return None

def discover_device_id(ser):
    for _ in range(30):
        raw = ser.read(4096)
        for part in raw.split(b'\r\n'):
            s = part.decode('ascii', 'replace').strip()
            if s:
                r = slcan_decode(s)
                if r:
                    d = decode_can_id(r[0])
                    if d['api_class'] in (0x20, 0x2E):
                        return d['dev_id']
        time.sleep(0.1)
    return None


def main():
    ser = serial.Serial(PORT, BAUD, timeout=0.05)
    time.sleep(0.2)
    ser.reset_input_buffer()

    did = discover_device_id(ser)
    print(f"Device CAN ID: {did}")

    PARAM = 7  # kInputDeadband
    rb = read_param(ser, did, PARAM)
    baseline = struct.unpack_from('<f', rb, 2)[0]
    print(f"Baseline param {PARAM}: {rb.hex(' ')}  float={baseline}")

    test_val = 0.06 if abs(baseline - 0.06) > 0.0001 else 0.07
    test_f32 = struct.pack('<f', test_val)
    print(f"Test value: {test_val} = {test_f32.hex(' ')}")

    def try_write(label, dev_id, payload, cls=7, idx=0):
        cid = make_can_id(cls, idx, dev_id)
        frames = send_recv(ser, cid, payload)
        r = get_write_response(frames, cid, payload)
        if r:
            b7, fd, d = r
            b7s = f"0x{b7:02x}" if b7 is not None else "?"
            print(f"  {label:<55} -> b7={b7s}  data={fd.hex(' ')}")
        else:
            print(f"  {label:<55} -> <no response>")

        # Check readback
        time.sleep(0.03)
        rb2 = read_param(ser, did, PARAM)
        if rb2:
            v = struct.unpack_from('<f', rb2, 2)[0]
            if abs(v - baseline) > 0.0001:
                print(f"    *** VALUE CHANGED to {v}! Restoring... ***")
                restore = bytes([PARAM, 0x00]) + struct.pack('<f', baseline) + b'\x00\x00'
                send_recv(ser, make_can_id(7, 0, did), restore)
                time.sleep(0.1)
                return True
        return False

    # =========================================================================
    # TEST 1: device_id=0 (USB self-address) for writes
    # =========================================================================
    print(f"\n{'='*70}")
    print("TEST 1: device_id=0 for writes (USB self-address)")
    print(f"{'='*70}")
    # Standard payload with devId=0
    try_write("devId=0 [p][00][val][00*2]", 0,
              bytes([PARAM, 0x00]) + test_f32 + b'\x00\x00')
    try_write("devId=0 [p][val][00*3]", 0,
              bytes([PARAM]) + test_f32 + b'\x00' * 3)
    # Also try read with devId=0 to see if it responds at all
    print("  Reading param with devId=0:")
    rb0 = read_param(ser, 0, PARAM)
    if rb0:
        print(f"    devId=0 read: {rb0.hex(' ')}")
    else:
        print(f"    devId=0 read: <no response>")

    # =========================================================================
    # TEST 2: byte[1] = type tag variants
    # =========================================================================
    print(f"\n{'='*70}")
    print("TEST 2: byte[1] type tag variants")
    print(f"{'='*70}")
    for b1, desc in [(0x00, "0x00 (current)"), (0x01, "0x01"), (0x02, "0x02 (int?)"),
                      (0x03, "0x03 (float?)"), (0x04, "0x04 (uint?)"),
                      (0x05, "0x05"), (0x06, "0x06"), (0x10, "0x10"),
                      (0x20, "0x20"), (0x80, "0x80"), (0xFF, "0xFF")]:
        payload = bytes([PARAM, b1]) + test_f32 + b'\x00\x00'
        try_write(f"devId={did} byte1={desc}", did, payload)

    # Also with devId=0
    print("  --- Same with devId=0 ---")
    for b1 in [0x00, 0x03, 0xFF]:
        payload = bytes([PARAM, b1]) + test_f32 + b'\x00\x00'
        try_write(f"devId=0 byte1=0x{b1:02x}", 0, payload)

    # =========================================================================
    # TEST 3: SLCAN init commands before write
    # =========================================================================
    print(f"\n{'='*70}")
    print("TEST 3: SLCAN init (C -> S6 -> O) then write")
    print(f"{'='*70}")

    # First verify reads still work
    rb_pre = read_param(ser, did, PARAM)
    print(f"  Pre-init read: {'OK' if rb_pre else 'FAIL'}")

    # Send SLCAN init sequence
    for cmd, desc in [("C\r", "Close CAN"), ("S6\r", "Set 500k"), ("O\r", "Open CAN")]:
        ser.write(cmd.encode())
        time.sleep(0.1)
        resp = ser.read(1024)
        print(f"  Sent {desc!r:12} -> {resp!r}")

    time.sleep(0.2)

    # Verify reads still work after init
    rb_post = read_param(ser, did, PARAM)
    print(f"  Post-init read: {'OK val=' + str(struct.unpack_from('<f', rb_post, 2)[0]) if rb_post else 'FAIL'}")

    # Now try writes
    print("  --- Writes after SLCAN init ---")
    try_write("post-init devId=did [p][00][val][00*2]", did,
              bytes([PARAM, 0x00]) + test_f32 + b'\x00\x00')
    try_write("post-init devId=0 [p][00][val][00*2]", 0,
              bytes([PARAM, 0x00]) + test_f32 + b'\x00\x00')
    try_write("post-init devId=did byte1=0x03", did,
              bytes([PARAM, 0x03]) + test_f32 + b'\x00\x00')

    # =========================================================================
    # TEST 4: SLCAN loopback mode (L command)
    # =========================================================================
    print(f"\n{'='*70}")
    print("TEST 4: SLCAN listen-only mode (L) then back to normal (O)")
    print(f"{'='*70}")
    ser.write(b"C\r")
    time.sleep(0.1)
    ser.read(1024)
    ser.write(b"L\r")  # Listen-only
    time.sleep(0.1)
    resp = ser.read(1024)
    print(f"  L (listen) -> {resp!r}")
    ser.write(b"O\r")  # Back to normal
    time.sleep(0.1)
    resp = ser.read(1024)
    print(f"  O (open)   -> {resp!r}")
    time.sleep(0.2)
    try_write("after L->O devId=did [p][00][val][00*2]", did,
              bytes([PARAM, 0x00]) + test_f32 + b'\x00\x00')

    # =========================================================================
    # TEST 5: Write with DLC variations
    # =========================================================================
    print(f"\n{'='*70}")
    print("TEST 5: Different DLC (payload lengths)")
    print(f"{'='*70}")
    # Maybe the write needs exactly the right number of bytes
    for payload, desc in [
        (bytes([PARAM, 0x00]) + test_f32, "6 bytes [p][00][val]"),
        (bytes([PARAM]) + test_f32, "5 bytes [p][val]"),
        (bytes([PARAM, 0x00]) + test_f32 + b'\x00', "7 bytes [p][00][val][00]"),
        (bytes([PARAM, 0x00]) + test_f32 + b'\x00\x00', "8 bytes [p][00][val][00*2] (standard)"),
        (bytes([PARAM, 0x00]) + test_f32 + b'\x00\x00\x00', "9-byte? (will truncate to 8)"),
    ]:
        payload = payload[:8]  # CAN max 8 bytes
        try_write(f"DLC={len(payload)} {desc}", did, payload)

    # =========================================================================
    # TEST 6: Write param as uint32 instead of float32
    # =========================================================================
    print(f"\n{'='*70}")
    print("TEST 6: Write as raw uint32 (same bit pattern as float)")
    print(f"{'='*70}")
    # kInputDeadband baseline is 0.05 = 0x3D4CCCCD
    # Try writing the uint32 representation directly
    uint_val = struct.unpack('<I', test_f32)[0]
    uint_bytes = struct.pack('<I', uint_val)
    try_write(f"uint32 {uint_val} = {uint_bytes.hex(' ')}", did,
              bytes([PARAM, 0x00]) + uint_bytes + b'\x00\x00')

    # =========================================================================
    # FINAL CHECK
    # =========================================================================
    print(f"\n{'='*70}")
    print("FINAL: Verify param unchanged")
    print(f"{'='*70}")
    rb_final = read_param(ser, did, PARAM)
    if rb_final:
        vf = struct.unpack_from('<f', rb_final, 2)[0]
        print(f"  param {PARAM} = {vf} (baseline was {baseline})")
        print(f"  {'UNCHANGED' if abs(vf - baseline) < 0.0001 else 'CHANGED!'}")
    else:
        print("  Could not read param")

    ser.close()
    print("Done.")


if __name__ == "__main__":
    main()
