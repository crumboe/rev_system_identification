import zipfile, struct
hc2 = r'C:\Program Files\WindowsApps\RevHardwareClient_1.0.7.0_x64__9pbt3jssjtwma'
jar = hc2 + r'\app\canbridge-0.0.0.jar'

with zipfile.ZipFile(jar) as z:
    data = z.read('com/revrobotics/canbridge/slcan/SLCanContext.class')
    cp_count = struct.unpack('>H', data[8:10])[0]
    cp = [None]
    i = 10
    idx = 1
    while idx < cp_count:
        tag = data[i]; i += 1
        if tag == 1:
            length = struct.unpack('>H', data[i:i+2])[0]; i += 2
            cp.append(('utf8', data[i:i+length])); i += length
        elif tag == 3: cp.append(('int', struct.unpack('>i', data[i:i+4])[0])); i += 4
        elif tag == 4: cp.append(None); i += 4
        elif tag == 5: cp.append(('long',)); cp.append(None); i += 8; idx += 1
        elif tag == 6: cp.append(None); cp.append(None); i += 8; idx += 1
        elif tag == 7: cp.append(('class', struct.unpack('>H', data[i:i+2])[0])); i += 2
        elif tag == 8: cp.append(('string', struct.unpack('>H', data[i:i+2])[0])); i += 2
        elif tag in (9,10,11,12): cp.append(None); i += 4
        elif tag == 15: cp.append(None); i += 3
        elif tag == 16: cp.append(None); i += 2
        elif tag in (17,18): cp.append(None); i += 4
        elif tag in (19,20): cp.append(None); i += 2
        else: break
        idx += 1

    print("All short string constants in SLCanContext:")
    for idx2 in range(1, len(cp)):
        e = cp[idx2]
        if e and e[0] == 'string':
            utf_idx = e[1]
            ue = cp[utf_idx]
            if ue and ue[0] == 'utf8':
                raw = ue[1]
                if len(raw) <= 10:
                    print(f'  #{idx2} -> UTF8#{utf_idx}: len={len(raw)} hex={raw.hex()} repr={repr(raw)}')
    
    # Also check SLCanParser for encoding format
    data2 = z.read('com/revrobotics/canbridge/slcan/SLCanParser.class')
    cp2_count = struct.unpack('>H', data2[8:10])[0]
    cp2 = [None]
    i = 10
    idx = 1
    while idx < cp2_count:
        tag = data2[i]; i += 1
        if tag == 1:
            length = struct.unpack('>H', data2[i:i+2])[0]; i += 2
            cp2.append(('utf8', data2[i:i+length])); i += length
        elif tag == 3: cp2.append(('int', struct.unpack('>i', data2[i:i+4])[0])); i += 4
        elif tag == 4: cp2.append(None); i += 4
        elif tag == 5: cp2.append(('long',)); cp2.append(None); i += 8; idx += 1
        elif tag == 6: cp2.append(None); cp2.append(None); i += 8; idx += 1
        elif tag == 7: cp2.append(('class', struct.unpack('>H', data2[i:i+2])[0])); i += 2
        elif tag == 8: cp2.append(('string', struct.unpack('>H', data2[i:i+2])[0])); i += 2
        elif tag in (9,10,11,12): cp2.append(None); i += 4
        elif tag == 15: cp2.append(None); i += 3
        elif tag == 16: cp2.append(None); i += 2
        elif tag in (17,18): cp2.append(None); i += 4
        elif tag in (19,20): cp2.append(None); i += 2
        else: break
        idx += 1

    print("\nAll short string constants in SLCanParser:")
    for idx2 in range(1, len(cp2)):
        e = cp2[idx2]
        if e and e[0] == 'string':
            utf_idx = e[1]
            ue = cp2[utf_idx]
            if ue and ue[0] == 'utf8':
                raw = ue[1]
                if len(raw) <= 20:
                    print(f'  #{idx2} -> UTF8#{utf_idx}: len={len(raw)} hex={raw.hex()} repr={repr(raw)}')
    
    # Also show ALL utf8 entries that could be format strings
    print("\nSLCanParser UTF8 entries (format-like):")
    for idx2 in range(1, len(cp2)):
        e = cp2[idx2]
        if e and e[0] == 'utf8':
            raw = e[1]
            try:
                text = raw.decode('utf-8')
                if '%' in text or ('T' in text and len(text) < 30):
                    print(f'  UTF8#{idx2}: {repr(text)}')
            except: pass
