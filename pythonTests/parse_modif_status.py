"""Parse modifForStatus.txt: extract setpoint commands, Status 0/1/2 signals.

SPARK MAX firmware ≥25.0 (REVLib 2026, API class 0x2E) frame encoding
----------------------------------------------------------------------

Status 0 (api_class=0x2E, index=0) — Applied output, voltage, current, temp:
  bytes 0-1 : int16_t  applied_output  × 3.082369457075716e-5  → duty cycle [-1, 1]
  bytes 2-4 : 12-bit packed voltage + current (bit-fields across 3 bytes)
      voltage_raw  = b[2] | ((b[3] & 0x0F) << 8)   (12 bits, LS nibble of b[3])
      current_raw  = ((b[3] >> 4) | (b[4] << 4)) & 0x0FFF  (12 bits, MS nibble of b[3])
      bus_voltage  = voltage_raw  × V_SCALE          → Volts  (V_SCALE ≈ 0.007326)
      output_current = current_raw × I_SCALE         → Amps   (I_SCALE ≈ 0.064)
  byte  5   : uint8_t  motor_temperature             → °C
  bytes 6-7 : packed status flags (bit 6[7] = hardware model, etc.)

  Derived quantity:
      output_voltage = applied_output × bus_voltage  → Volts applied to motor

  NOTE on voltage scale: 0.0073260073260073 = 2/273.
    At max 12-bit (4095): 4095 × 2/273 ≈ 30.0 V  (full-scale = 30 V)
  NOTE on current scale: 16/250 = 0.064 A/count.
    Derived from the documented 16-bit encoding (1/250 A per 16-bit count) scaled
    for 12-bit packing (12-bit covers 1/16 of 16-bit range → scale × 16).
    At max 12-bit (4095): 4095 × 0.064 ≈ 262 A  (matches 16-bit max 65535/250).

Status 1 (api_class=0x2E, index=1) — Faults & warnings:
  bytes 0-3 : uint32_t  active_faults    (bitmask; 0 = no faults)
  bytes 4-7 : uint32_t  sticky_faults    (bitmask; latched; 0 = no latched faults)

Status 2 (api_class=0x2E, index=2) — Primary encoder:
  bytes 0-3 : float32  velocity          → RPM  (positive = forward)
  bytes 4-7 : float32  position          → rotations

Setpoint command (api_class=0x00, index=2) — Duty-cycle setpoint:
  bytes 0-3 : float32  setpoint          → duty cycle [-1, 1]
  byte  4   : uint8_t  pid_slot          → 0-3
"""

import re
import struct
import csv
import sys
import os

# ---------------------------------------------------------------------------
# Scale constants
# ---------------------------------------------------------------------------

# Applied-output integer → duty cycle  (1 / (2^15 - 1))
APPLIED_OUTPUT_SCALE: float = 3.082369457075716e-05

# 12-bit voltage raw → Volts  (2 / 273, full-scale 30 V for 12-bit)
V_SCALE: float = 0.0073260073260073

# 12-bit current raw → Amps  (16 / 250, derived from 16-bit 1/250 mapping)
I_SCALE: float = 16.0 / 250.0   # ≈ 0.064 A/count, full-scale ≈ 262 A at 12-bit max

# ---------------------------------------------------------------------------
# SLCAN frame decoder
# ---------------------------------------------------------------------------

def decode_slcan_payload(hex_bytes: list[str]) -> tuple[int | None, bytes | None]:
    """Decode a list of hex byte strings as an SLCAN extended frame.

    Returns ``(arb_id, payload)`` on success, ``(None, None)`` otherwise.
    """
    try:
        ascii_vals = [int(b, 16) for b in hex_bytes]
        ascii_str = ''.join(chr(v) for v in ascii_vals if v >= 0x20)
    except ValueError:
        return None, None

    if not (ascii_str.startswith('T') and len(ascii_str) >= 10):
        return None, None

    try:
        arb_id = int(ascii_str[1:9], 16)
        dlc = int(ascii_str[9], 16)
        data_hex = ascii_str[10:10 + dlc * 2]
        if len(data_hex) == dlc * 2:
            return arb_id, bytes.fromhex(data_hex)
    except (ValueError, IndexError):
        pass

    return None, None


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

_LINE_RE = re.compile(
    r'(\d+\.\d+)ms\s+(RX|TX)\s+[^\[]+\[[\d.]+\]\s+((?:[0-9a-fA-F]{2}\s*)+)'
)


def parse_log(path: str) -> list[tuple]:
    """Return all decoded frames from *path* as ``(ts, direction, arb_id, payload, desc)``."""
    frames = []
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        lines = fh.readlines()

    i = 0
    while i < len(lines) - 1:
        m = _LINE_RE.match(lines[i].strip())
        if m:
            ts = float(m.group(1))
            direction = m.group(2)
            hex_bytes = m.group(3).split()
            arb_id, payload = decode_slcan_payload(hex_bytes)
            desc = lines[i + 1].strip() if i + 1 < len(lines) else ''
            frames.append((ts, direction, arb_id, payload, desc))
            i += 2
        else:
            i += 1

    return frames


# ---------------------------------------------------------------------------
# Frame decoders
# ---------------------------------------------------------------------------

def decode_status0(payload: bytes) -> dict:
    """Decode a new-protocol Status Frame 0 (api_class=0x2E, index=0).

    Returns a dict with keys:
      applied_output   float  duty cycle, [-1, +1]
      bus_voltage      float  DC bus voltage, Volts
      output_current   float  motor phase current, Amps (scale 16/250 per 12-bit count)
      output_voltage   float  effective motor terminal voltage, Volts
      temperature_c    int    controller temperature, °C
      flags            int    raw 16-bit flags word (bytes 6-7)
    """
    if len(payload) < 8:
        return {}

    applied_raw = struct.unpack_from('<h', payload, 0)[0]
    applied_output = applied_raw * APPLIED_OUTPUT_SCALE

    # 12-bit packed voltage: b[2] | ((b[3] & 0x0F) << 8)
    v_raw = (payload[2] | ((payload[3] & 0x0F) << 8))
    bus_voltage = v_raw * V_SCALE

    # 12-bit packed current: high nibble of b[3] concatenated with b[4]
    i_raw = ((payload[3] >> 4) | (payload[4] << 4)) & 0x0FFF
    output_current = i_raw * I_SCALE

    temperature_c = payload[5]
    flags = (payload[6] << 8) | payload[7]

    return {
        'applied_output': applied_output,
        'bus_voltage': bus_voltage,
        'output_current': output_current,
        'output_voltage': applied_output * bus_voltage,
        'temperature_c': temperature_c,
        'flags': flags,
        'v_raw': v_raw,
        'i_raw': i_raw,
    }


def decode_status1(payload: bytes) -> dict:
    """Decode a new-protocol Status Frame 1 (api_class=0x2E, index=1).

    Returns a dict with keys:
      active_faults   int  bitmask of currently active faults (0 = OK)
      sticky_faults   int  bitmask of latched (sticky) faults  (0 = OK)
    """
    if len(payload) < 8:
        return {}

    active_faults = struct.unpack_from('<I', payload, 0)[0]
    sticky_faults = struct.unpack_from('<I', payload, 4)[0]

    return {
        'active_faults': active_faults,
        'sticky_faults': sticky_faults,
    }


def decode_status2(payload: bytes) -> dict:
    """Decode a new-protocol Status Frame 2 (api_class=0x2E, index=2).

    Returns a dict with keys:
      velocity_rpm    float  primary encoder velocity, RPM
      position_rot    float  primary encoder position, rotations
    """
    if len(payload) < 8:
        return {}

    velocity_rpm = struct.unpack_from('<f', payload, 0)[0]
    position_rot = struct.unpack_from('<f', payload, 4)[0]

    return {
        'velocity_rpm': velocity_rpm,
        'position_rot': position_rot,
    }


def decode_setpoint(payload: bytes) -> dict:
    """Decode a duty-cycle setpoint command (api_class=0x00, index=2).

    Returns a dict with keys:
      setpoint   float  commanded duty cycle, [-1, +1]
      pid_slot   int    PID slot index, 0-3
    """
    if len(payload) < 4:
        return {}

    setpoint = struct.unpack_from('<f', payload, 0)[0]
    pid_slot = payload[4] if len(payload) > 4 else 0

    return {
        'setpoint': setpoint,
        'pid_slot': pid_slot,
    }


# ---------------------------------------------------------------------------
# Main analysis
# ---------------------------------------------------------------------------

def analyse(path: str, csv_out: str | None = None) -> None:
    """Parse *path* and print a summary table; optionally write CSV to *csv_out*."""
    frames = parse_log(path)
    print(f"Loaded {len(frames)} frame records from '{path}'")

    status0_frames = [(ts, p) for ts, _, _, p, d in frames if p and 'Status idx=0' in d]
    status1_frames = [(ts, p) for ts, _, _, p, d in frames if p and 'Status idx=1' in d]
    status2_frames = [(ts, p) for ts, _, _, p, d in frames if p and 'Status idx=2' in d]
    setpoint_frames = [(ts, p) for ts, _, _, p, d in frames if p and 'cls=0x00 idx=2' in d]

    print(f"  Status 0  : {len(status0_frames)} frames")
    print(f"  Status 1  : {len(status1_frames)} frames")
    print(f"  Status 2  : {len(status2_frames)} frames")
    print(f"  Setpoints : {len(setpoint_frames)} frames")
    print()

    # -----------------------------------------------------------------------
    # Status 0
    # -----------------------------------------------------------------------
    print("=" * 110)
    print("STATUS 0 — Applied output, bus voltage, output current, temperature")
    print("  Bit layout: bytes[0:2]=applied_output(int16), bytes[2:5]=12-bit{voltage,current},")
    print("              byte[5]=temp(°C), bytes[6:8]=flags")
    print(f"  Scales: V_SCALE={V_SCALE:.10f} V/count,  I_SCALE={I_SCALE:.6f} A/count (16/250)")
    print("=" * 110)
    print(
        f"{'ts_ms':>8s}  {'appOut':>8s}  {'V_bus(V)':>8s}  {'I_out(A)':>8s}  "
        f"{'V_out(V)':>8s}  {'T(°C)':>6s}  {'v_raw':>6s}  {'i_raw':>6s}  {'flags':>6s}"
    )
    print("-" * 110)

    prev_data: bytes | None = None
    s0_rows: list[dict] = []

    for ts, payload in status0_frames:
        if payload == prev_data:
            continue
        prev_data = payload
        d = decode_status0(payload)
        if not d:
            continue
        s0_rows.append({'ts_ms': ts, **d})
        print(
            f"{ts:8.0f}ms  {d['applied_output']:8.4f}  {d['bus_voltage']:8.3f}  "
            f"{d['output_current']:8.3f}  {d['output_voltage']:8.3f}  "
            f"{d['temperature_c']:6d}  {d['v_raw']:6d}  {d['i_raw']:6d}  0x{d['flags']:04x}"
        )

    # -----------------------------------------------------------------------
    # Status 1
    # -----------------------------------------------------------------------
    print()
    print("=" * 60)
    print("STATUS 1 — Faults & warnings (bitfields)")
    print("=" * 60)
    print(f"{'ts_ms':>8s}  {'active_faults':>14s}  {'sticky_faults':>14s}")
    print("-" * 60)

    prev_data = None
    s1_rows: list[dict] = []
    non_zero_count = 0

    for ts, payload in status1_frames:
        if payload == prev_data:
            continue
        prev_data = payload
        d = decode_status1(payload)
        if not d:
            continue
        s1_rows.append({'ts_ms': ts, **d})
        if d['active_faults'] != 0 or d['sticky_faults'] != 0:
            non_zero_count += 1
            print(f"{ts:8.0f}ms  0x{d['active_faults']:08x}    0x{d['sticky_faults']:08x}")

    if non_zero_count == 0:
        print("  (all Status 1 frames show zero faults — no faults detected)")

    # -----------------------------------------------------------------------
    # Status 2
    # -----------------------------------------------------------------------
    print()
    print("=" * 70)
    print("STATUS 2 — Primary encoder velocity (RPM) and position (rotations)")
    print("=" * 70)
    print(f"{'ts_ms':>8s}  {'vel(RPM)':>10s}  {'pos(rot)':>10s}")
    print("-" * 70)

    prev_data = None
    prev_vel = None
    s2_rows: list[dict] = []

    for ts, payload in status2_frames:
        if payload == prev_data:
            continue
        prev_data = payload
        d = decode_status2(payload)
        if not d:
            continue
        s2_rows.append({'ts_ms': ts, **d})
        # Print only when velocity changes significantly
        if prev_vel is None or abs(d['velocity_rpm'] - prev_vel) > 1.0:
            print(f"{ts:8.0f}ms  {d['velocity_rpm']:10.2f}  {d['position_rot']:10.4f}")
            prev_vel = d['velocity_rpm']

    # -----------------------------------------------------------------------
    # Setpoints
    # -----------------------------------------------------------------------
    print()
    print("=" * 60)
    print("SETPOINT COMMANDS — Duty-cycle (cls=0x00 idx=2)")
    print("=" * 60)
    print(f"{'ts_ms':>8s}  {'setpoint':>10s}  {'pid_slot':>8s}")
    print("-" * 60)

    prev_sp = None
    sp_rows: list[dict] = []

    for ts, payload in setpoint_frames:
        d = decode_setpoint(payload)
        if not d:
            continue
        sp_rows.append({'ts_ms': ts, **d})
        if prev_sp is None or abs(d['setpoint'] - prev_sp) > 0.001:
            print(f"{ts:8.0f}ms  {d['setpoint']:10.4f}  {d['pid_slot']:8d}")
            prev_sp = d['setpoint']

    # -----------------------------------------------------------------------
    # Merged timeline: setpoint, setpoint×12V, applied voltage, current
    # -----------------------------------------------------------------------
    print()
    print("=" * 100)
    print("TIMELINE — Setpoint, Voltage, Current, Velocity, Acceleration")
    print("=" * 140)
    print(
        f"{'ts_ms':>8s}  {'src':>7s}  {'DutySetpt':>10s}  "
        f"{'Setpt×12V':>10s}  {'AppliedV':>10s}  {'dV/dt':>10s}  "
        f"{'AppliedA':>10s}  {'Vel(RPM)':>10s}  {'Accel':>10s}"
    )
    print("-" * 140)

    # Build sorted event list
    timeline_events: list[tuple[float, str, dict]] = []
    for r in sp_rows:
        timeline_events.append((r['ts_ms'], 'SP', r))
    for r in s0_rows:
        timeline_events.append((r['ts_ms'], 'ST0', r))
    for r in s2_rows:
        timeline_events.append((r['ts_ms'], 'ST2', r))
    timeline_events.sort(key=lambda x: x[0])

    # Carry-forward state for the last known values
    last_setpoint: float | None = None
    last_applied_v: float | None = None
    last_applied_i: float | None = None
    last_velocity: float | None = None
    prev_applied_v: float | None = None
    prev_velocity: float | None = None
    prev_ts: float | None = None
    timeline_rows: list[dict] = []

    for ts, src, row in timeline_events:
        if src == 'SP':
            last_setpoint = row['setpoint']
        elif src == 'ST0':
            last_applied_v = row['output_voltage']
            last_applied_i = row['output_current']
        elif src == 'ST2':
            last_velocity = row['velocity_rpm']

        # Compute dAppliedVoltage/dt  (V/s)
        dv_dt: float | None = None
        if (last_applied_v is not None and prev_applied_v is not None
                and prev_ts is not None and ts != prev_ts):
            dt_s = (ts - prev_ts) / 1000.0  # ms → s
            dv_dt = (last_applied_v - prev_applied_v) / dt_s

        # Compute acceleration  (RPM/s)
        accel: float | None = None
        if (last_velocity is not None and prev_velocity is not None
                and prev_ts is not None and ts != prev_ts):
            dt_s = (ts - prev_ts) / 1000.0
            accel = (last_velocity - prev_velocity) / dt_s

        sp_str = f"{last_setpoint:10.4f}" if last_setpoint is not None else f"{'—':>10s}"
        sp12_str = f"{last_setpoint * 12.0:10.4f}" if last_setpoint is not None else f"{'—':>10s}"
        av_str = f"{last_applied_v:10.4f}" if last_applied_v is not None else f"{'—':>10s}"
        dvdt_str = f"{dv_dt:10.2f}" if dv_dt is not None else f"{'—':>10s}"
        ai_str = f"{last_applied_i:10.4f}" if last_applied_i is not None else f"{'—':>10s}"
        vel_str = f"{last_velocity:10.2f}" if last_velocity is not None else f"{'—':>10s}"
        acc_str = f"{accel:10.2f}" if accel is not None else f"{'—':>10s}"

        tl_row = {
            'ts_ms': ts,
            'source': src,
            'duty_setpoint': last_setpoint,
            'setpoint_x12v': last_setpoint * 12.0 if last_setpoint is not None else None,
            'applied_voltage': last_applied_v,
            'dv_dt': dv_dt,
            'applied_current': last_applied_i,
            'velocity_rpm': last_velocity,
            'accel_rpm_s': accel,
        }
        timeline_rows.append(tl_row)

        print(f"{ts:8.0f}ms  {src:>7s}  {sp_str}  {sp12_str}  {av_str}  {dvdt_str}  {ai_str}  {vel_str}  {acc_str}")

        prev_applied_v = last_applied_v
        prev_velocity = last_velocity
        prev_ts = ts

    # -----------------------------------------------------------------------
    # CSV export
    # -----------------------------------------------------------------------
    if csv_out:
        _write_csv(csv_out, s0_rows, s1_rows, s2_rows, sp_rows, timeline_rows)
        print(f"\nCSV written to '{csv_out}'")


def _write_csv(
    path: str,
    s0_rows: list[dict],
    s1_rows: list[dict],
    s2_rows: list[dict],
    sp_rows: list[dict],
    timeline_rows: list[dict] | None = None,
) -> None:
    """Write merged timeline CSV with Status 0/1/2 and setpoint data."""

    # Build sorted event list
    events: list[tuple[float, str, dict]] = []
    for r in s0_rows:
        events.append((r['ts_ms'], 'status0', r))
    for r in s1_rows:
        events.append((r['ts_ms'], 'status1', r))
    for r in s2_rows:
        events.append((r['ts_ms'], 'status2', r))
    for r in sp_rows:
        events.append((r['ts_ms'], 'setpoint', r))
    events.sort(key=lambda x: x[0])

    fieldnames = [
        'ts_ms', 'frame_type',
        # Status 0
        'applied_output', 'bus_voltage_V', 'output_current_A', 'output_voltage_V',
        'temperature_C', 'status0_flags', 'v_raw', 'i_raw',
        # Status 1
        'active_faults', 'sticky_faults',
        # Status 2
        'velocity_rpm', 'position_rot',
        # Setpoint
        'setpoint', 'pid_slot',
    ]

    with open(path, 'w', newline='') as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction='ignore')
        writer.writeheader()
        for ts, ftype, row in events:
            out: dict = {'ts_ms': ts, 'frame_type': ftype}
            if ftype == 'status0':
                out['applied_output'] = f"{row['applied_output']:.6f}"
                out['bus_voltage_V'] = f"{row['bus_voltage']:.4f}"
                out['output_current_A'] = f"{row['output_current']:.4f}"
                out['output_voltage_V'] = f"{row['output_voltage']:.4f}"
                out['temperature_C'] = row['temperature_c']
                out['status0_flags'] = f"0x{row['flags']:04x}"
                out['v_raw'] = row['v_raw']
                out['i_raw'] = row['i_raw']
            elif ftype == 'status1':
                out['active_faults'] = f"0x{row['active_faults']:08x}"
                out['sticky_faults'] = f"0x{row['sticky_faults']:08x}"
            elif ftype == 'status2':
                out['velocity_rpm'] = f"{row['velocity_rpm']:.3f}"
                out['position_rot'] = f"{row['position_rot']:.6f}"
            elif ftype == 'setpoint':
                out['setpoint'] = f"{row['setpoint']:.6f}"
                out['pid_slot'] = row['pid_slot']
            writer.writerow(out)

    # Write a separate timeline CSV (same base name with _timeline suffix)
    if timeline_rows:
        base, ext = os.path.splitext(path)
        tl_path = f"{base}_timeline{ext}"
        tl_fields = [
            'ts_ms', 'source', 'duty_setpoint', 'setpoint_x12v',
            'applied_voltage_V', 'dAppliedV_dt_Vps', 'applied_current_A',
            'velocity_rpm', 'accel_rpm_per_s',
        ]
        with open(tl_path, 'w', newline='') as fh2:
            tw = csv.DictWriter(fh2, fieldnames=tl_fields, extrasaction='ignore')
            tw.writeheader()
            for r in timeline_rows:
                tw.writerow({
                    'ts_ms': r['ts_ms'],
                    'source': r['source'],
                    'duty_setpoint': f"{r['duty_setpoint']:.6f}" if r['duty_setpoint'] is not None else '',
                    'setpoint_x12v': f"{r['setpoint_x12v']:.6f}" if r['setpoint_x12v'] is not None else '',
                    'applied_voltage_V': f"{r['applied_voltage']:.4f}" if r['applied_voltage'] is not None else '',
                    'dAppliedV_dt_Vps': f"{r['dv_dt']:.4f}" if r.get('dv_dt') is not None else '',
                    'applied_current_A': f"{r['applied_current']:.4f}" if r['applied_current'] is not None else '',
                    'velocity_rpm': f"{r['velocity_rpm']:.3f}" if r.get('velocity_rpm') is not None else '',
                    'accel_rpm_per_s': f"{r['accel_rpm_s']:.4f}" if r.get('accel_rpm_s') is not None else '',
                })
        print(f"Timeline CSV written to '{tl_path}'")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == '__main__':
    log_path = sys.argv[1] if len(sys.argv) > 1 else 'modifForStatus.txt'
    csv_path = sys.argv[2] if len(sys.argv) > 2 else None

    import os
    if not os.path.isfile(log_path):
        print(f"Usage: python parse_modif_status.py <log_file> [output.csv]")
        print(f"Error: file not found: '{log_path}'")
        sys.exit(1)

    analyse(log_path, csv_path)
