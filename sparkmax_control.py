"""
SPARK MAX Motor Control - Firmware 26.x (SLCAN Protocol)
=========================================================
Heartbeat + duty cycle / velocity / position setpoint over SLCAN USB.

Command CAN IDs use the same structure as parameter reads:
  bits [28:24] = 0x02  (device type: motor controller)
  bits [23:16] = 0x05  (manufacturer: REV, fw26+)
  bits [15:10] = API Class
  bits  [9:6]  = API Index
  bits  [5:0]  = Device CAN ID

Key API commands:
  Heartbeat   : class=6,  index=0  — must send ≤100ms to keep motor enabled
  Duty cycle  : class=0,  index=2  — float32 LE, -1.0 to 1.0
  Velocity    : class=0,  index=11 — float32 LE, RPM
  Position    : class=0,  index=10 — float32 LE, rotations
  Burn flash  : class=6,  index=1  — persist param changes

Requires: pip install pyserial
"""

import serial
import struct
import time
import threading

PORT     = "COM11"
BAUD     = 115200
DEVICE_TYPE  = 0x02
MANUFACTURER = 0x05


# ── CAN / SLCAN helpers (same as param reader) ────────────────────────────────

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

def slcan_encode(can_id: int, data: bytes) -> bytes:
    return f"T{can_id:08X}{len(data):1X}{data.hex().upper()}\r\n".encode('ascii')

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


# ── SparkMax class ─────────────────────────────────────────────────────────────

class SparkMax:
    # API class / index constants
    API_DUTY_CYCLE  = (0,  2)
    API_VELOCITY    = (0,  11)
    API_POSITION    = (0,  10)
    API_VOLTAGE     = (0,  12)
    API_HEARTBEAT   = (6,  0)
    API_BURN_FLASH  = (6,  1)
    API_PARAM_READ  = (7,  1)
    API_PARAM_WRITE = (7,  0)

    def __init__(self, port, device_id=None, baud=115200):
        self.ser = serial.Serial(port, baud, timeout=0.05)
        time.sleep(0.2)
        self.ser.reset_input_buffer()

        # Auto-discover device CAN ID from stream if not provided
        if device_id is None:
            self.device_id = self._discover_id()
        else:
            self.device_id = device_id

        print(f"SparkMax ready on {port}, device CAN ID={self.device_id}")

        # Heartbeat thread
        self._hb_enabled = False
        self._hb_thread  = None
        self._lock       = threading.Lock()

    # ── internal helpers ──────────────────────────────────────────────────────

    def _discover_id(self, listen_secs=1.5):
        deadline = time.time() + listen_secs
        buf = b''
        device_ids = set()
        while time.time() < deadline:
            chunk = self.ser.read(256)
            if chunk:
                buf += chunk
            while b'\r\n' in buf:
                line, buf = buf.split(b'\r\n', 1)
                r = slcan_decode(line.decode('ascii', errors='replace'))
                if r:
                    can_id, _ = r
                    d = decode_can_id(can_id)
                    if d['device_type'] == DEVICE_TYPE and d['manufacturer'] == MANUFACTURER:
                        device_ids.add(d['device_id'])
        if not device_ids:
            print("WARNING: no device detected, defaulting to ID 0")
            return 0
        return sorted(device_ids)[0]

    def _send(self, api_class, api_index, data=b'\x00'*8):
        can_id = make_can_id(api_class, api_index, self.device_id)
        with self._lock:
            self.ser.write(slcan_encode(can_id, data))

    def _send_recv(self, api_class, api_index, data=b'\x00'*8, timeout=0.15):
        can_id = make_can_id(api_class, api_index, self.device_id)
        with self._lock:
            self.ser.reset_input_buffer()
            self.ser.write(slcan_encode(can_id, data))
            time.sleep(timeout)
            raw = self.ser.read(512)

        lines = []
        for part in raw.split(b'\r\n'):
            s = part.decode('ascii', errors='replace').strip()
            if s:
                lines.append(s)
        return lines

    def _parse_param_response(self, lines, expected_api_class=7):
        for line in lines:
            r = slcan_decode(line)
            if not r:
                continue
            can_id, data = r
            d = decode_can_id(can_id)
            if d['device_id'] == self.device_id and d['api_class'] == expected_api_class:
                if len(data) >= 7 and data[1] == 0xFF:
                    return data
        return None

    # ── Heartbeat ─────────────────────────────────────────────────────────────

    def start_heartbeat(self, interval=0.08):
        """
        Start sending heartbeat frames every `interval` seconds.
        The SPARK MAX requires a heartbeat within ~100ms to keep the motor enabled.
        Without a roboRIO on CAN, this USB heartbeat substitutes.
        """
        if self._hb_enabled:
            return
        self._hb_enabled = True

        def _loop():
            while self._hb_enabled:
                self._send(*self.API_HEARTBEAT)
                time.sleep(interval)

        self._hb_thread = threading.Thread(target=_loop, daemon=True)
        self._hb_thread.start()
        print(f"Heartbeat started (interval={interval*1000:.0f}ms)")

    def stop_heartbeat(self):
        self._hb_enabled = False
        if self._hb_thread:
            self._hb_thread.join(timeout=0.5)
        print("Heartbeat stopped")

    # ── Motor control ─────────────────────────────────────────────────────────

    def set_duty_cycle(self, throttle: float):
        """Set motor output as duty cycle, -1.0 (full reverse) to 1.0 (full forward)."""
        throttle = max(-1.0, min(1.0, throttle))
        data = struct.pack('<f', throttle) + b'\x00' * 4
        self._send(*self.API_DUTY_CYCLE, data)

    def set_velocity(self, rpm: float):
        """Set motor velocity setpoint in RPM (requires velocity PID configured)."""
        data = struct.pack('<f', rpm) + b'\x00' * 4
        self._send(*self.API_VELOCITY, data)

    def set_position(self, rotations: float):
        """Set motor position setpoint in rotations (requires position PID configured)."""
        data = struct.pack('<f', rotations) + b'\x00' * 4
        self._send(*self.API_POSITION, data)

    def set_voltage(self, volts: float):
        """Set motor output as voltage."""
        data = struct.pack('<f', volts) + b'\x00' * 4
        self._send(*self.API_VOLTAGE, data)

    def stop(self):
        """Stop the motor (set duty cycle to 0)."""
        self.set_duty_cycle(0.0)

    # ── Parameter access ──────────────────────────────────────────────────────

    def read_param(self, param_id: int):
        """Read a parameter. Returns (float_value, int_value, type_tag) or None."""
        data = bytes([param_id]) + b'\x00' * 7
        lines = self._send_recv(*self.API_PARAM_READ, data)
        resp = self._parse_param_response(lines)
        if resp is None:
            return None
        raw_float = struct.unpack_from('<f', resp, 2)[0]
        raw_uint  = struct.unpack_from('<I', resp, 2)[0]
        type_tag  = resp[6]  # 0x00=bool, 0x02=int, 0x03=float, 0x04=uint
        return raw_float, raw_uint, type_tag

    def write_param(self, param_id: int, value):
        """Write a parameter. Value can be float or int."""
        if isinstance(value, bool):
            packed = struct.pack('<I', int(value))
        elif isinstance(value, int):
            packed = struct.pack('<I', value)
        else:
            packed = struct.pack('<f', float(value))
        data = bytes([param_id]) + b'\x00' + packed + b'\x00' * 2
        lines = self._send_recv(*self.API_PARAM_WRITE, data)
        return self._parse_param_response(lines)

    def burn_flash(self):
        """Persist all parameter changes to flash."""
        lines = self._send_recv(*self.API_BURN_FLASH)
        print("Burn flash sent")
        return lines

    # ── Status telemetry ──────────────────────────────────────────────────────

    def read_status(self, listen_secs=0.3):
        """
        Read one round of periodic status frames from the device stream.
        Returns dict with applied_output, velocity_rpm, position_rot, voltage_V, temp_C, faults.
        """
        deadline = time.time() + listen_secs
        buf = b''
        status = {}
        with self._lock:
            self.ser.reset_input_buffer()
            while time.time() < deadline:
                chunk = self.ser.read(256)
                if chunk:
                    buf += chunk
                while b'\r\n' in buf:
                    line, buf = buf.split(b'\r\n', 1)
                    r = slcan_decode(line.decode('ascii', errors='replace'))
                    if not r:
                        continue
                    can_id, data = r
                    d = decode_can_id(can_id)
                    if d['device_id'] != self.device_id or d['api_class'] != 0x20:
                        continue
                    idx = d['api_index']

                    if idx == 0 and len(data) >= 6:
                        # Status 0: applied output, faults
                        applied = struct.unpack_from('<h', data, 0)[0] / 32767.0
                        faults  = struct.unpack_from('<H', data, 2)[0]
                        status['applied_output'] = round(applied, 4)
                        status['faults']         = f"0x{faults:04X}"

                    elif idx == 1 and len(data) >= 6:
                        # Status 1: velocity, temp, voltage
                        status['velocity_rpm'] = round(struct.unpack_from('<f', data, 0)[0], 1)
                        status['temp_C']       = data[4]
                        status['voltage_V']    = round(struct.unpack_from('<H', data, 5)[0] / 128.0, 2)

                    elif idx == 2 and len(data) >= 4:
                        # Status 2: position
                        status['position_rot'] = round(struct.unpack_from('<f', data, 0)[0], 4)

        return status

    # ── Cleanup ───────────────────────────────────────────────────────────────

    def close(self):
        self.stop_heartbeat()
        self.stop()
        time.sleep(0.05)
        self.ser.close()
        print("Disconnected.")

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


# ── Demo ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    with SparkMax(PORT) as motor:

        # Read a couple params to confirm comms
        r = motor.read_param(2)  # kMotorType
        if r:
            motor_type = {0: "Brushed", 1: "Brushless"}.get(r[1], str(r[1]))
            print(f"Motor type : {motor_type}")
        r = motor.read_param(6)  # kIdleMode
        if r:
            idle = {0: "Coast", 1: "Brake"}.get(r[1], str(r[1]))
            print(f"Idle mode  : {idle}")

        # Start heartbeat - required before motor will respond to setpoints
        motor.start_heartbeat(interval=0.08)
        time.sleep(0.2)  # let a few heartbeats go out

        print("\nStarting motor ramp...")
        print(f"{'Setpoint':>10}  {'Applied':>10}  {'Velocity':>12}  {'Voltage':>10}")
        print("-" * 50)

        # Ramp up slowly
        for pct in range(0, 25, 5):
            throttle = pct / 100.0
            motor.set_duty_cycle(throttle)
            time.sleep(0.3)
            s = motor.read_status()
            print(f"{throttle:>10.2f}  {s.get('applied_output','?'):>10}  "
                  f"{s.get('velocity_rpm','?'):>12}  {s.get('voltage_V','?'):>10}")

        # Hold for 1 second
        time.sleep(1.0)

        # Ramp back down
        for pct in range(20, -5, -5):
            throttle = pct / 100.0
            motor.set_duty_cycle(throttle)
            time.sleep(0.3)
            s = motor.read_status()
            print(f"{throttle:>10.2f}  {s.get('applied_output','?'):>10}  "
                  f"{s.get('velocity_rpm','?'):>12}  {s.get('voltage_V','?'):>10}")

        print("\nDone.")
