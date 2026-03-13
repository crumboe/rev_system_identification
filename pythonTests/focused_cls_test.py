"""Deep test on the 3 responsive apiClasses: 0x01, 0x07, 0x1F"""
import serial, struct, time

PORT = 'COM11'
BAUD = 115200
DEV_TYPE = 0x02
MFR = 0x05

def make_can_id(cls, idx, dev): return (DEV_TYPE<<24)|(MFR<<16)|(cls<<10)|(idx<<6)|dev
def slcan_encode(cid, data):
    h = f'T{cid:08X}{len(data):X}' + data.hex().upper() + '\r\n'
    return h.encode()
def slcan_decode(s):
    if not s.startswith('T') or len(s) < 10: return None
    cid = int(s[1:9], 16)
    n = int(s[9], 16)
    d = bytes.fromhex(s[10:10+n*2])
    return (cid, d)
def decode_can_id(cid):
    return {'api_class':(cid>>10)&0x3F, 'api_index':(cid>>6)&0xF, 'dev_id':cid&0x3F}
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
            if r: frames.append(r)
    return frames
def read_param(ser, did, pid):
    frames = send_recv(ser, make_can_id(7, 1, did), bytes([pid])+b'\x00'*7)
    for fid, fd in frames:
        d = decode_can_id(fid)
        if d['api_class']==7 and d['api_index']==1 and len(fd)>=6 and fd[0]==pid:
            return fd
    return None

ser = serial.Serial(PORT, BAUD, timeout=0.05)
time.sleep(0.2)
ser.reset_input_buffer()

# discover
did = None
for _ in range(20):
    raw = ser.read(4096)
    for part in raw.split(b'\r\n'):
        s = part.decode('ascii','replace').strip()
        if s:
            r = slcan_decode(s)
            if r:
                d = decode_can_id(r[0])
                if d['api_class'] in (0x20, 0x2E):
                    did = d['dev_id']
                    break
    if did: break
    time.sleep(0.1)
print(f'Device: {did}')

# baseline
rb = read_param(ser, did, 7)
baseline = struct.unpack_from('<f', rb, 2)[0]
print(f'Baseline param 7: {rb.hex(" ")} = {baseline}')

test_val = 0.06 if abs(baseline - 0.06) > 0.0001 else 0.07
test_bytes = struct.pack('<f', test_val)

# ============================================================================
# Test cls=0x1F across all 16 apiIndex values
# ============================================================================
print(f'\n=== cls=0x1F (31) deep test — all idx 0-15 ===')
for idx in range(16):
    for payload in [
        bytes([7, 0x00]) + test_bytes + b'\x00\x00',
        bytes([7]) + test_bytes + b'\x00'*3,
    ]:
        frames = send_recv(ser, make_can_id(0x1F, idx, did), payload, t=0.1)
        for fid, fd in frames:
            d2 = decode_can_id(fid)
            if d2['api_class'] in (0x20, 0x2E, 0x2F): continue
            print(f'  idx={idx} payload={payload.hex(" ")} -> resp cls=0x{d2["api_class"]:02X} idx={d2["api_index"]} data={fd.hex(" ")}')

# Check if 0x1F changed param
rb2 = read_param(ser, did, 7)
val2 = struct.unpack_from('<f', rb2, 2)[0]
print(f'After all 0x1F tests: val={val2}  changed={abs(val2-baseline)>0.0001}')

# ============================================================================
# Test cls=0x1F as unlock → then write with cls=0x07
# ============================================================================
print(f'\n=== cls=0x1F as unlock, then cls=0x07 write ===')
for unlock_data in [b'\x00'*8, b'\x01'*8, bytes([7,0x00])+test_bytes+b'\x00\x00', b'\xFF'*8]:
    send_recv(ser, make_can_id(0x1F, 0, did), unlock_data, t=0.05)
    payload = bytes([7, 0x00]) + test_bytes + b'\x00\x00'
    frames = send_recv(ser, make_can_id(7, 0, did), payload)
    for fid, fd in frames:
        d2 = decode_can_id(fid)
        if d2['api_class'] in (0x20, 0x2E, 0x2F): continue
        b7 = f'0x{fd[7]:02x}' if len(fd)>7 else '?'
        print(f'  unlock={unlock_data.hex()} -> resp b7={b7} data={fd.hex(" ")}')
    rb3 = read_param(ser, did, 7)
    v3 = struct.unpack_from('<f', rb3, 2)[0]
    if abs(v3-baseline)>0.0001:
        print(f'  *** VALUE CHANGED to {v3}! ***')

# ============================================================================
# Also test if 0x1F idx=0 + different data patterns is an unlock
# ============================================================================
print(f'\n=== More unlock patterns on 0x1F before cls=0x07 write ===')
for unlock_data in [
    struct.pack('<Q', 0xA5A5A5A5A5A5A5A5),  # magic pattern
    struct.pack('<I', did) + b'\x00'*4,       # device ID
    bytes([0x02, 0x05]) + b'\x00'*6,          # devType+mfr
    b'\x00\x01\x02\x03\x04\x05\x06\x07',
]:
    send_recv(ser, make_can_id(0x1F, 0, did), unlock_data, t=0.05)
    payload = bytes([7, 0x00]) + test_bytes + b'\x00\x00'
    frames = send_recv(ser, make_can_id(7, 0, did), payload)
    for fid, fd in frames:
        d2 = decode_can_id(fid)
        if d2['api_class'] in (0x20, 0x2E, 0x2F): continue
        b7 = f'0x{fd[7]:02x}' if len(fd)>7 else '?'
        print(f'  unlock2={unlock_data.hex()} -> resp b7={b7}')
    rb4 = read_param(ser, did, 7)
    v4 = struct.unpack_from('<f', rb4, 2)[0]
    if abs(v4-baseline)>0.0001:
        print(f'  *** VALUE CHANGED to {v4}! ***')

# ============================================================================
# cls=0x01 legacy readback check
# ============================================================================
print(f'\n=== cls=0x01 (legacy) readback ===')
for payload in [bytes([7,0x00])+test_bytes+b'\x00\x00', bytes([7])+test_bytes+b'\x00'*3]:
    frames = send_recv(ser, make_can_id(1, 0, did), payload)
    for fid, fd in frames:
        d2 = decode_can_id(fid)
        if d2['api_class'] in (0x20, 0x2E, 0x2F): continue
        print(f'  payload={payload.hex(" ")} -> data={fd.hex(" ")}')
    rb5 = read_param(ser, did, 7)
    v5 = struct.unpack_from('<f', rb5, 2)[0]
    print(f'  readback: {v5} changed={abs(v5-baseline)>0.0001}')

# ============================================================================
# Try write with cls=0x07 but different apiIndex values (0-15)
# ============================================================================
print(f'\n=== cls=0x07 with all idx 0-15 ===')
for idx in range(16):
    payload = bytes([7, 0x00]) + test_bytes + b'\x00\x00'
    frames = send_recv(ser, make_can_id(7, idx, did), payload, t=0.1)
    for fid, fd in frames:
        d2 = decode_can_id(fid)
        if d2['api_class'] in (0x20, 0x2E, 0x2F): continue
        b7 = f'0x{fd[7]:02x}' if len(fd)>7 else '?'
        print(f'  idx={idx} -> resp cls=0x{d2["api_class"]:02X} idx={d2["api_index"]} b7={b7} data={fd.hex(" ")}')
    rb6 = read_param(ser, did, 7)
    v6 = struct.unpack_from('<f', rb6, 2)[0]
    if abs(v6-baseline)>0.0001:
        print(f'  *** idx={idx} VALUE CHANGED to {v6}! ***')

print(f'\nFinal baseline check:')
rbf = read_param(ser, did, 7)
vf = struct.unpack_from('<f', rbf, 2)[0]
print(f'  param 7 = {vf} (was {baseline})')

ser.close()
print('Done.')
