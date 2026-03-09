"""
Extract ALL strings from REVLibDriver.dll - both wide and narrow.
"""
import os

dll_path = os.path.join(r'C:\Users\chris.reckner\AppData\Local\Temp\revlib_dlls', 'REVLibDriver.dll')
with open(dll_path, 'rb') as f:
    data = f.read()

print(f"REVLibDriver.dll: {len(data)} bytes")

# Wide strings (UTF-16LE) 
print("\n=== ALL Wide strings (UTF-16LE) >=4 chars ===")
i = 0
count = 0
while i < len(data) - 4:
    j = i
    chars = []
    while j < len(data) - 1:
        c = data[j] | (data[j+1] << 8)
        if 0x20 <= c < 0x7F:
            chars.append(chr(c))
            j += 2
        elif c == 0 and len(chars) >= 4:
            break
        else:
            break
    
    if len(chars) >= 4:
        s = ''.join(chars)
        print(f"  {i:#08x}: {s}")
        count += 1
    i = max(i + 2, j)
print(f"Total: {count} wide strings")

# Also narrow 
print("\n=== Narrow strings >=6 chars (interesting only) ===")
i = 0
while i < len(data) - 5:
    j = i
    chars = []
    while j < len(data):
        c = data[j]
        if 0x20 <= c < 0x7F:
            chars.append(chr(c))
            j += 1
        elif c == 0 and len(chars) >= 6:
            break
        else:
            break
    
    if len(chars) >= 6:
        s = ''.join(chars)
        # Skip common noise
        if not any(skip in s for skip in ['@@', '__', 'PEAX', '.?AV', 'AEBV', 'AEAV']):
            print(f"  {i:#08x}: {s}")
    i = max(i + 1, j)
