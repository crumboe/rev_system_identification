"""Decode Status idx=0 frames from with_status.txt - compare 16-bit vs 12-bit packed."""
import re
import struct

lines = open('with_status.txt', 'r').readlines()

results = []
i = 0
while i < len(lines):
    if i >= len(lines):
        break
    line = lines[i].strip()
    m = re.match(r'(\d+\.\d+)ms\s+(RX|TX)\s+.+\[[\d.]+\]\s+((?:[0-9a-fA-F]{2}\s*)+)', line)
    if m:
        timestamp = float(m.group(1))
        hex_bytes = m.group(3).split()
        ascii_str = ''.join(chr(int(b, 16)) for b in hex_bytes if int(b, 16) >= 0x20)

        if i+1 < len(lines):
            desc_line = lines[i+1].strip()
            frame_type = None
            if 'Status idx=0 dev=41' in desc_line:
                frame_type = 'STATUS0'
            elif 'Status idx=2 dev=41' in desc_line:
                frame_type = 'STATUS2'
            elif 'cls=0x00 idx=4 dev=41' in desc_line:
                frame_type = 'CTRL'

            if frame_type and ascii_str.startswith('T') and len(ascii_str) >= 10:
                dlc = int(ascii_str[9], 16)
                data_hex = ascii_str[10:10+dlc*2]
                if len(data_hex) == dlc * 2:
                    data_bytes = [int(data_hex[j:j+2], 16) for j in range(0, len(data_hex), 2)]
                    results.append((timestamp, frame_type, data_bytes))
    i += 2

status0 = [(ts, d) for ts, typ, d in results if typ == 'STATUS0']
status2 = [(ts, d) for ts, typ, d in results if typ == 'STATUS2']
ctrl = [(ts, d) for ts, typ, d in results if typ == 'CTRL']

print(f"Found {len(status0)} Status0, {len(status2)} Status2, {len(ctrl)} control frames")
print(f"Time span: {status0[0][0]:.0f}ms - {status0[-1][0]:.0f}ms")

# Show control command changes
print("\n=== Control setpoint changes ===")
prev_sp = None
for ts, data in ctrl:
    sp = struct.unpack('<f', bytes(data[:4]))[0]
    ct = data[4] if len(data) > 4 else -1
    if prev_sp is None or abs(sp - prev_sp) > 0.001:
        print(f"  {ts:8.1f}ms  setpoint={sp:.6f}  ctrlType={ct}  raw=[{' '.join(f'{b:02x}' for b in data)}]")
        prev_sp = sp

# Compare the two decode hypotheses
print("\n" + "="*120)
print("COMPARISON: 16-bit (current parser) vs 12-bit packed (like legacy)")
print("="*120)
print(f"{'Time':>8s}  {'raw bytes':24s}  │ {'appOut':>7s}  {'V_16b':>7s}  {'I_16b':>7s}  {'T_16b':>5s}  │ {'V_12b':>7s}  {'I_12b':>7s}  {'T_12b':>5s}  │ {'flags':>6s}")
print("-"*120)

prev = None
for ts, data in status0:
    if len(data) < 8:
        continue
    if prev is not None and data == prev:
        continue
    prev = data[:]
    b = data

    # Current parser: bytes 2-3=voltage(u16), 4-5=current(u16), 6=temp, 7=flags
    v_16 = (b[2] | (b[3] << 8)) * 0.0073260073260073
    i_16 = (b[4] | (b[5] << 8)) / 250.0
    t_16 = b[6]

    # 12-bit packed hypothesis: bytes 2-4 = packed voltage(12)+current(12), 5=temp, 6-7=flags
    v_12_raw = (b[2] | (b[3] << 8)) & 0x0FFF
    i_12_raw = ((b[3] >> 4) | (b[4] << 4)) & 0x0FFF
    v_12 = v_12_raw * 0.0073260073260073
    i_12 = i_12_raw / 250.0   # try same scale first
    t_12 = b[5]

    applied = struct.unpack('<h', bytes(b[0:2]))[0] * 3.082369457075716e-05
    flags = f"0x{b[6]:02x}{b[7]:02x}" if len(b) > 7 else "?"

    raw = ' '.join(f'{x:02x}' for x in b)
    print(f"  {ts:7.0f}ms  [{raw}]  │ {applied:7.4f}  {v_16:6.2f}V  {i_16:6.2f}A  {t_16:5d}  │ {v_12:6.2f}V  {i_12:6.2f}A  {t_12:5d}  │ {flags}")

# Also decode Status2 (velocity + position) to see motor movement
print("\n=== Status2 (velocity/position) - unique values ===")
prev = None
for ts, data in status2:
    if prev is not None and data == prev:
        continue
    prev = data[:]
    vel = struct.unpack('<f', bytes(data[0:4]))[0]
    pos = struct.unpack('<f', bytes(data[4:8]))[0]
    print(f"  {ts:8.1f}ms  vel={vel:10.3f} RPM  pos={pos:10.4f} rot")
