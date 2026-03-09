"""
Deep analysis of REVLibDriver.dll - look for device paths, USB GUIDs,
COM port patterns, and any protocol-related strings.
"""
import os
import re

dll_path = r'C:\Users\chris.reckner\AppData\Local\Temp\revlib_dlls'

for dll_name in ['REVLibDriver.dll', 'BackendDriver.dll', 'CallbackDriver.dll']:
    full_path = os.path.join(dll_path, dll_name)
    if not os.path.exists(full_path):
        print(f"Not found: {full_path}")
        continue
    
    with open(full_path, 'rb') as f:
        data = f.read()
    
    print(f"\n{'='*60}")
    print(f"{dll_name} ({len(data)} bytes)")
    print(f"{'='*60}")
    
    # Extract wide strings (UTF-16LE)
    print("\nWide strings (UTF-16LE):")
    wide_strings = set()
    i = 0
    while i < len(data) - 4:
        # Look for sequences of printable ASCII as UTF-16LE
        j = i
        chars = []
        while j < len(data) - 1:
            c = data[j] | (data[j+1] << 8)
            if 0x20 <= c < 0x7F:
                chars.append(chr(c))
                j += 2
            elif c == 0 and len(chars) >= 3:
                break
            else:
                break
        
        if len(chars) >= 4:
            s = ''.join(chars)
            if s not in wide_strings:
                wide_strings.add(s)
                # Only print interesting ones
                interesting = any(k in s.lower() for k in [
                    'com', 'usb', 'guid', 'device', 'path', 'serial', 'port',
                    'slcan', 'can', 'spark', 'rev', 'error', 'fail', 'driver',
                    'wpi', 'create', 'open', 'close', 'write', 'read',
                    '\\\\', 'vid', 'pid', 'hid', 'winusb', 'class',
                    'interface', 'endpoint', 'bulk', 'pipe', 'handle',
                    'protocol', 'bridge', 'init', 'setup', 'config',
                    '{', 'heartbeat', 'param'
                ])
                if interesting or '\\' in s or '{' in s:
                    print(f"  W: {repr(s)}")
        i = max(i + 2, j)
    
    # Extract narrow strings (ASCII/UTF-8)
    print("\nNarrow strings (ASCII):")
    narrow_strings = set()
    i = 0
    while i < len(data) - 3:
        j = i
        chars = []
        while j < len(data):
            c = data[j]
            if 0x20 <= c < 0x7F:
                chars.append(chr(c))
                j += 1
            elif c == 0 and len(chars) >= 4:
                break
            else:
                break
        
        if len(chars) >= 4:
            s = ''.join(chars)
            if s not in narrow_strings:
                narrow_strings.add(s)
                interesting = any(k in s.lower() for k in [
                    'com', 'usb', 'guid', 'device', 'path', 'serial', 'port',
                    'slcan', 'can', 'spark', 'rev', 'error', 'fail', 'driver',
                    'wpi', 'create', 'open', 'close', 'write', 'read',
                    '\\\\', 'vid', 'pid', 'hid', 'winusb', 'class',
                    'interface', 'endpoint', 'bulk', 'pipe', 'handle',
                    'protocol', 'bridge', 'init', 'setup', 'heartbeat',
                    'param', 'baud', 'dtr', 'rts', 'format', 'frame',
                    'packet', '.dll', '.sys', '.inf'
                ])
                if interesting or '\\' in s or '{' in s or 'COM' in s:
                    print(f"  N: {repr(s)}")
        i = max(i + 1, j)
