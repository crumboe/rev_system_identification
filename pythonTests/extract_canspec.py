"""Extract CAN message specifications from SparkCanSpec inner classes."""
import zipfile, os, struct

hc2_path = r'C:\Program Files\WindowsApps\RevHardwareClient_1.0.7.0_x64__9pbt3jssjtwma'
jar = os.path.join(hc2_path, 'app', 'rev-devices.jar')

def extract_class_info(jar_path, class_name):
    with zipfile.ZipFile(jar_path) as z:
        data = z.read(class_name)
        idx = 8
        cp_count = struct.unpack('>H', data[idx:idx+2])[0]; idx += 2
        strings = {}
        integers = {}
        longs = {}
        i = 1
        while i < cp_count:
            tag = data[idx]; idx += 1
            if tag == 1:
                ln = struct.unpack('>H', data[idx:idx+2])[0]; idx += 2
                s = data[idx:idx+ln].decode('utf-8', errors='replace'); idx += ln
                strings[i] = s
            elif tag == 3:  # integer
                val = struct.unpack('>i', data[idx:idx+4])[0]
                integers[i] = val
                idx += 4
            elif tag == 4:  # float
                idx += 4
            elif tag in (9, 10, 11, 12, 17, 18): idx += 4
            elif tag == 5:  # long
                val = struct.unpack('>q', data[idx:idx+8])[0]
                longs[i] = val
                idx += 8
                i += 1
            elif tag == 6:  # double
                idx += 8
                i += 1
            elif tag in (7, 8, 16, 19, 20): idx += 2
            elif tag == 15: idx += 3
            i += 1
        return strings, integers, longs

targets = [
    'USBOnlyIdentify',
    'USBOnlyEnterDFUBootloader', 
    'SecondaryHeartbeat',
    'Identify',
    'IdentifyUniqueSPARK',
    'GetFirmwareVersion',
    'Status0',
    'ParameterWrite',
    'ParameterWriteResponse',
    'ReadParameter0and1',
    'ClearFaults',
    'Ack',
    'Nack',
    'DutyCycleSetpoint',
    'SetStatusesEnabled',
    'SetStatusesEnabledResponse',
    'PersistParameters',
    'PersistParametersResponse',
    'LegacyStatus0',
    'UniqueIDBroadcast',
    'SetCANID',
    'VelocitySetpoint',
    'EnterSWDLCANBootloader',
]

with zipfile.ZipFile(jar) as z:
    all_names = z.namelist()
    for t in targets:
        class_name = f'com/revrobotics/SparkCanSpec${t}.class'
        if class_name not in all_names:
            print(f'\n=== {t} === NOT FOUND')
            continue
        print(f'\n=== {t} ===')
        s, ints, longs = extract_class_info(jar, class_name)
        
        # Print relevant strings
        seen = set()
        for v in s.values():
            if v not in seen and len(v) > 1:
                if not v.startswith('java/') and not v.startswith('('):
                    seen.add(v)
                    print(f'  STR: {v}')
        if ints:
            for k, v in ints.items():
                print(f'  INT[{k}]: {v} (0x{v & 0xFFFFFFFF:08X})')
        if longs:
            for k, v in longs.items():
                print(f'  LONG[{k}]: {v} (0x{v & 0xFFFFFFFFFFFFFFFF:016X})')

# Also check the main SparkCanSpec for the CAN arb ID formula
print('\n\n=== SparkCanSpec (main class) INTEGER CONSTANTS ===')
s, ints, longs = extract_class_info(jar, 'com/revrobotics/SparkCanSpec.class')
if ints:
    for k, v in ints.items():
        print(f'  INT[{k}]: {v} (0x{v & 0xFFFFFFFF:08X})')
if longs:
    for k, v in longs.items():
        print(f'  LONG[{k}]: {v} (0x{v & 0xFFFFFFFFFFFFFFFF:016X})')

# Also look at parsing helpers - CanIdParsing
print('\n\n=== CanIdParsing ===')
cip_name = 'com/revrobotics/device/detection/parsing/CanIdParsing.class'
if cip_name in all_names:
    s, ints, longs = extract_class_info(jar, cip_name)
    seen = set()
    for v in s.values():
        if v not in seen and len(v) > 1 and not v.startswith('java/') and not v.startswith('('):
            seen.add(v)
            print(f'  STR: {v}')
    if ints:
        for k, v in ints.items():
            print(f'  INT[{k}]: {v} (0x{v & 0xFFFFFFFF:08X})')
