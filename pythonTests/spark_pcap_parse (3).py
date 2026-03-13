"""
USBPcap → SPARK TX/RX Log
==========================
Reads a Wireshark .pcap or .pcapng file captured via USBPcap and
extracts all URB_BULK IN/OUT transfers, printing them as a clean
TX/RX log with SLCAN frame decoding.

Usage:
    python spark_pcap_parse.py capture.pcapng
    python spark_pcap_parse.py capture.pcapng --device 3.2
    python spark_pcap_parse.py capture.pcapng --device 3.2 --no-status
    python spark_pcap_parse.py capture.pcapng --device 3.2 --no-status --no-heartbeat --out log.txt

The --device filter is "bus.device" e.g. "3.2" — find it in Wireshark's
Source/Destination columns for any SPARK packet.

Requires:
    pip install dpkt
"""

import sys
import struct
import argparse

try:
    import dpkt
except ImportError:
    print("ERROR: dpkt not installed. Run:  pip install dpkt")
    sys.exit(1)


STATUS_CLASSES = {0x20, 0x2E, 46, 47}

USBPCAP_TRANSFER_BULK = 3

# ── CAN helpers ───────────────────────────────────────────────────────────────

def decode_can_id(can_id):
    return {
        "device_type":  (can_id >> 24) & 0x1F,
        "manufacturer": (can_id >> 16) & 0xFF,
        "api_class":    (can_id >> 10) & 0x3F,
        "api_index":    (can_id >>  6) & 0x0F,
        "device_id":     can_id        & 0x3F,
    }

def describe_frame(can_id, data):
    d = decode_can_id(can_id)
    cls = d['api_class']
    idx = d['api_index']
    dev = d['device_id']

    if cls in STATUS_CLASSES:
        return f"Status idx={idx} dev={dev}"
    if cls == 0x07:
        if idx == 0:
            pid = data[0] if data else '?'
            return f"PARAM WRITE  param={pid} dev={dev}  payload={data.hex(' ')}"
        if idx == 1:
            pid    = data[0] if data else '?'
            status = data[1] if len(data) > 1 else '?'
            tag    = "READ_RESP" if status == 0xFF else ("WRITE_ACK" if status == 0x00 else f"status=0x{status:02X}")
            return f"PARAM {tag}  param={pid} dev={dev}  payload={data.hex(' ')}"
        if idx == 2:
            return f"BURN FLASH dev={dev}"
        return f"PARAM cls=7 idx={idx} dev={dev}"
    if cls == 0x06:
        if idx == 0:
            return f"HEARTBEAT dev={dev}"
        if idx == 1:
            return f"BURN FLASH (old) dev={dev}"
        return f"SYSTEM cls=6 idx={idx} dev={dev}"
    if cls == 0x01:
        return f"OLD PROTO cls=1 idx={idx} dev={dev}  payload={data.hex(' ')}"
    return f"cls={cls:#04x} idx={idx} dev={dev}"

def decode_slcan_chunk(raw_bytes):
    results = []
    text = raw_bytes.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    for line in text.split(b'\n'):
        s = line.strip().decode('ascii', errors='replace')
        if not s:
            continue
        if s.startswith('T') and len(s) >= 10:
            try:
                can_id = int(s[1:9], 16)
                dlc    = int(s[9],   16)
                data   = bytes.fromhex(s[10:10 + dlc * 2])
                results.append((can_id, data, describe_frame(can_id, data)))
                continue
            except Exception:
                pass
        results.append((None, None, f"RAW: {s!r}"))
    return results


# ── USBPcap header parser ─────────────────────────────────────────────────────
#
# USBPcap header layout (little-endian):
#   0x00  uint16  headerLen
#   0x02  uint64  irpId
#   0x0A  uint32  status
#   0x0E  uint16  function
#   0x10  uint8   info
#   0x11  uint16  bus
#   0x13  uint16  device
#   0x15  uint8   endpoint
#   0x16  uint8   transfer    (3 = BULK)
#   0x17  uint32  dataLength
#   [headerLen - 27 bytes of optional extra header]
#   [dataLength bytes of payload]

def parse_usbpcap(raw):
    if len(raw) < 27:
        return None
    try:
        header_len  = struct.unpack_from('<H', raw, 0)[0]
        bus         = struct.unpack_from('<H', raw, 17)[0]
        device      = struct.unpack_from('<H', raw, 19)[0]
        endpoint    = struct.unpack_from('<B', raw, 21)[0]
        transfer    = struct.unpack_from('<B', raw, 22)[0]
        data_length = struct.unpack_from('<I', raw, 23)[0]

        if transfer != USBPCAP_TRANSFER_BULK:
            return None
        if data_length == 0:
            return None
        if header_len + data_length > len(raw):
            return None

        # Endpoint MSB=1 → IN (device→host = RX), MSB=0 → OUT (host→device = TX)
        direction = "RX" if (endpoint & 0x80) else "TX"
        payload   = raw[header_len:header_len + data_length]

        return bus, device, direction, payload
    except Exception:
        return None


def open_pcap(path):
    with open(path, 'rb') as f:
        magic = f.read(4)
    f = open(path, 'rb')
    if magic == b'\x0a\x0d\x0d\x0a':
        return dpkt.pcapng.Reader(f), f
    else:
        return dpkt.pcap.Reader(f), f


def main():
    parser = argparse.ArgumentParser(description="Parse USBPcap .pcapng into SPARK TX/RX log")
    parser.add_argument("pcap", help="Path to .pcap or .pcapng file")
    parser.add_argument("--device", default=None,
                        help="USB bus.device filter e.g. '3.2'")
    parser.add_argument("--no-status", action="store_true",
                        help="Hide status stream frames to reduce noise")
    parser.add_argument("--no-heartbeat", action="store_true",
                        help="Hide heartbeat frames (cls=6 idx=0)")
    parser.add_argument("--out", default=None,
                        help="Save output to a log file")
    args = parser.parse_args()

    dev_bus = dev_addr = None
    if args.device:
        try:
            parts    = args.device.split('.')
            dev_bus  = int(parts[0])
            dev_addr = int(parts[1])
        except Exception:
            print(f"ERROR: --device should be 'bus.device' e.g. '3.2'")
            sys.exit(1)

    print(f"Reading {args.pcap}...")
    if args.device:
        print(f"Device filter: bus={dev_bus} device={dev_addr}")
    if args.no_status:
        print("Status frames hidden")
    if args.no_heartbeat:
        print("Heartbeat frames hidden")
    print()

    outfile = open(args.out, 'w', encoding='utf-8') if args.out else None

    def emit(line):
        print(line)
        if outfile:
            outfile.write(line + '\n')

    try:
        reader, fh = open_pcap(args.pcap)
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)

    t0 = None
    total = shown = 0

    for ts, raw in reader:
        total += 1
        result = parse_usbpcap(raw)
        if result is None:
            continue

        bus, device, direction, payload = result

        if dev_bus is not None and (bus != dev_bus or device != dev_addr):
            continue

        if t0 is None:
            t0 = ts
        ms = (ts - t0) * 1000

        frames = decode_slcan_chunk(payload)

        if args.no_status:
            frames = [f for f in frames
                      if f[0] is None or
                      decode_can_id(f[0])['api_class'] not in STATUS_CLASSES]

        if args.no_heartbeat:
            HEARTBEAT_IDS = {0x000502C0, 0x02052C80}
            frames = [f for f in frames
                      if f[0] is None or f[0] not in HEARTBEAT_IDS]

        if not frames:
            continue

        shown += 1
        arrow = "──►" if direction == "TX" else "◄──"
        emit(f"{ms:>10.1f}ms  {direction}  {arrow}  [{bus}.{device}]  {payload.hex(' ')}")
        for can_id, data, desc in frames:
            if can_id is not None:
                emit(f"              0x{can_id:08X}  {desc}")
            else:
                emit(f"              {desc}")
        emit("")

    fh.close()
    if outfile:
        outfile.close()
        print(f"Log saved to {args.out}")

    print(f"Done. {total} packets, {shown} bulk transfers shown.")


if __name__ == "__main__":
    main()
