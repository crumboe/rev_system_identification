import os
dll_path = r'C:\Program Files\WindowsApps\RevHardwareClient_1.0.7.0_x64__9pbt3jssjtwma\bin\REVLibDriver.dll'
with open(dll_path, 'rb') as f:
    data = f.read()

search = [b'HAL_', b'WPI', b'FRC_', b'SendMessage', b'ReceiveMessage',
          b'sendCAN', b'CAN_', b'CANBridge',
          b'CreateDevice', b'OpenDevice',
          b'DCB', b'SetCommState', b'SetCommTimeouts',
          b'ReadFile', b'WriteFile', b'PurgeComm',
          b'GetOverlappedResult', b'WaitForSingleObject',
          b'c_Spark_Create', b'RegisterId',
          b'pipe', b'Pipe', b'PIPE',
          b'Overlapped', b'OVERLAPPED',
          b'\\\\.\\'
          ]

for term in search:
    idx = 0
    found_strs = set()
    while True:
        idx = data.find(term, idx)
        if idx == -1:
            break
        start = idx
        while start > 0 and data[start-1] != 0 and data[start-1] >= 32 and data[start-1] < 127:
            start -= 1
        end = idx + len(term)
        while end < len(data) and data[end] != 0 and data[end] >= 32 and data[end] < 127:
            end += 1
        s = data[start:end].decode('ascii', errors='replace')
        if len(s) < 200:
            found_strs.add(s)
        idx += 1
    if found_strs:
        tname = term.decode('ascii', errors='replace')
        print(f'--- {tname} ---')
        for s in sorted(found_strs):
            print(f'  {s}')
        print()

# Also check DLL imports
print("=== DLL Import table strings ===")
# Look for imported DLL names
for dll_name in [b'kernel32', b'msvcrt', b'ucrt', b'setupapi', b'hid', b'winusb', b'cfgmgr']:
    if dll_name in data.lower():
        idx = data.lower().find(dll_name)
        start = idx
        while start > 0 and data[start-1] != 0 and (data[start-1] >= 32 and data[start-1] < 127):
            start -= 1
        end = idx
        while end < len(data) and data[end] != 0 and (data[end] >= 32 and data[end] < 127):
            end += 1
        s = data[start:end].decode('ascii', errors='replace')
        print(f'  {s}')
