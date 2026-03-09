import zipfile, struct

hc2 = r'C:\Program Files\WindowsApps\RevHardwareClient_1.0.7.0_x64__9pbt3jssjtwma'
jar = hc2 + r'\app\canbridge-0.0.0.jar'

def parse_class(data):
    if struct.unpack('>I', data[:4])[0] != 0xCAFEBABE: return None
    cp_count = struct.unpack('>H', data[8:10])[0]
    cp = [None]
    i = 10
    idx = 1
    while idx < cp_count:
        tag = data[i]; i += 1
        if tag == 1:
            l = struct.unpack('>H', data[i:i+2])[0]; i+=2
            cp.append(('utf8', data[i:i+l])); i+=l
        elif tag == 3: cp.append(('int', struct.unpack('>i', data[i:i+4])[0])); i+=4
        elif tag == 4: cp.append(('float', struct.unpack('>f', data[i:i+4])[0])); i+=4
        elif tag == 5: cp.append(('long', struct.unpack('>q', data[i:i+8])[0])); cp.append(None); i+=8; idx+=1
        elif tag == 6: cp.append(('double',)); cp.append(None); i+=8; idx+=1
        elif tag == 7: cp.append(('class', struct.unpack('>H', data[i:i+2])[0])); i+=2
        elif tag == 8: cp.append(('string', struct.unpack('>H', data[i:i+2])[0])); i+=2
        elif tag == 9: cp.append(('fieldref', struct.unpack('>HH', data[i:i+4]))); i+=4
        elif tag == 10: cp.append(('methodref', struct.unpack('>HH', data[i:i+4]))); i+=4
        elif tag == 11: cp.append(('ifmethodref', struct.unpack('>HH', data[i:i+4]))); i+=4
        elif tag == 12: cp.append(('nameandtype', struct.unpack('>HH', data[i:i+4]))); i+=4
        elif tag == 15: cp.append(('methodhandle',)); i+=3
        elif tag == 16: cp.append(('methodtype',)); i+=2
        elif tag in (17,18): cp.append(('dynamic',)); i+=4
        elif tag in (19,20): cp.append(None); i+=2
        else: cp.append(('unknown', tag)); break
        idx += 1
    return cp

def resolve_name(cp, idx):
    if idx < len(cp) and cp[idx]:
        t = cp[idx][0]
        if t == 'utf8': return cp[idx][1].decode('utf-8', errors='replace')
        if t == 'class': return resolve_name(cp, cp[idx][1])
        if t == 'string': return '"' + resolve_name(cp, cp[idx][1]) + '"'
        if t == 'nameandtype': return resolve_name(cp, cp[idx][1][0]) + ':' + resolve_name(cp, cp[idx][1][1])
        if t in ('methodref','fieldref','ifmethodref'):
            return resolve_name(cp, cp[idx][1][0]) + '.' + resolve_name(cp, cp[idx][1][1])
        if t == 'int': return f'int({cp[idx][1]})'
        if t == 'long': return f'long({cp[idx][1]})'
    return f'?{idx}'

opcodes = {
    0:'nop',1:'aconst_null',2:'iconst_m1',3:'iconst_0',4:'iconst_1',5:'iconst_2',6:'iconst_3',7:'iconst_4',8:'iconst_5',
    9:'lconst_0',10:'lconst_1',
    16:'bipush',17:'sipush',18:'ldc',19:'ldc_w',20:'ldc2_w',
    21:'iload',22:'lload',23:'fload',24:'dload',25:'aload',
    26:'iload_0',27:'iload_1',28:'iload_2',29:'iload_3',
    30:'lload_0',31:'lload_1',32:'lload_2',33:'lload_3',
    42:'aload_0',43:'aload_1',44:'aload_2',45:'aload_3',
    46:'iaload',47:'laload',48:'faload',49:'daload',50:'aaload',51:'baload',52:'caload',53:'saload',
    54:'istore',55:'lstore',58:'astore',59:'istore_0',60:'istore_1',61:'istore_2',62:'istore_3',
    63:'lstore_0',64:'lstore_1',65:'lstore_2',66:'lstore_3',
    75:'astore_0',76:'astore_1',77:'astore_2',78:'astore_3',
    79:'iastore',80:'lastore',83:'aastore',84:'bastore',
    87:'pop',88:'pop2',89:'dup',92:'dup2',
    96:'iadd',97:'ladd',100:'isub',104:'imul',108:'idiv',112:'irem',
    116:'ineg',120:'ishl',122:'ishr',124:'iushr',126:'iand',128:'ior',130:'ixor',
    132:'iinc',133:'i2l',134:'i2f',136:'l2i',
    148:'lcmp',
    153:'ifeq',154:'ifne',155:'iflt',156:'ifge',157:'ifgt',158:'ifle',
    159:'if_icmpeq',160:'if_icmpne',161:'if_icmplt',162:'if_icmpge',163:'if_icmpgt',164:'if_icmple',
    165:'if_acmpeq',166:'if_acmpne',
    167:'goto',168:'jsr',169:'ret',170:'tableswitch',171:'lookupswitch',
    172:'ireturn',173:'lreturn',174:'freturn',175:'dreturn',176:'areturn',177:'return',
    178:'getstatic',179:'putstatic',180:'getfield',181:'putfield',
    182:'invokevirtual',183:'invokespecial',184:'invokestatic',185:'invokeinterface',
    186:'invokedynamic',187:'new',188:'newarray',189:'anewarray',190:'arraylength',
    191:'athrow',192:'checkcast',193:'instanceof',194:'monitorenter',195:'monitorexit',
    196:'wide',197:'multianewarray',198:'ifnull',199:'ifnonnull',200:'goto_w'
}

def disasm(data, cp, start, code_len):
    result = []
    j = 0
    while j < code_len:
        op = data[start + j]
        name = opcodes.get(op, f'op{op}')
        if op in (178,179,180,181,182,183,184):
            ref = struct.unpack('>H', data[start+j+1:start+j+3])[0]
            result.append(f'  {j:4d}: {name} // {resolve_name(cp, ref)}')
            j += 3
        elif op == 185:
            ref = struct.unpack('>H', data[start+j+1:start+j+3])[0]
            result.append(f'  {j:4d}: {name} // {resolve_name(cp, ref)}')
            j += 5
        elif op == 186:
            ref = struct.unpack('>H', data[start+j+1:start+j+3])[0]
            result.append(f'  {j:4d}: invokedynamic #{ref}')
            j += 5
        elif op in (16, 21, 22, 23, 24, 25, 54, 55, 58, 169):
            val = data[start+j+1]
            result.append(f'  {j:4d}: {name} {val}')
            j += 2
        elif op == 17:
            val = struct.unpack('>h', data[start+j+1:start+j+3])[0]
            result.append(f'  {j:4d}: {name} {val}')
            j += 3
        elif op == 18:
            idx2 = data[start+j+1]
            result.append(f'  {j:4d}: {name} // {resolve_name(cp, idx2)}')
            j += 2
        elif op in (19,20):
            idx2 = struct.unpack('>H', data[start+j+1:start+j+3])[0]
            result.append(f'  {j:4d}: {name} // {resolve_name(cp, idx2)}')
            j += 3
        elif op in (153,154,155,156,157,158,159,160,161,162,163,164,165,166,167,168,198,199):
            offset = struct.unpack('>h', data[start+j+1:start+j+3])[0]
            result.append(f'  {j:4d}: {name} -> {j+offset}')
            j += 3
        elif op in (187,189,192,193):
            ref = struct.unpack('>H', data[start+j+1:start+j+3])[0]
            result.append(f'  {j:4d}: {name} // {resolve_name(cp, ref)}')
            j += 3
        elif op == 132:  # iinc
            index = data[start+j+1]
            const = struct.unpack('>b', bytes([data[start+j+2]]))[0]
            result.append(f'  {j:4d}: iinc {index} by {const}')
            j += 3
        elif op == 197:  # multianewarray
            j += 4
            result.append(f'  {j-4:4d}: multianewarray')
        elif op == 200:  # goto_w
            offset = struct.unpack('>i', data[start+j+1:start+j+5])[0]
            result.append(f'  {j:4d}: goto_w -> {j+offset}')
            j += 5
        elif op == 170:  # tableswitch
            result.append(f'  {j:4d}: tableswitch (skipping)')
            break
        elif op == 171:  # lookupswitch
            result.append(f'  {j:4d}: lookupswitch (skipping)')
            break
        else:
            result.append(f'  {j:4d}: {name}')
            j += 1
    return result

with zipfile.ZipFile(jar) as z:
    data = z.read('com/revrobotics/canbridge/slcan/SLCanParser.class')
    cp = parse_class(data)
    
    # Find methods section
    i = 10
    idx = 1
    cp_count = struct.unpack('>H', data[8:10])[0]
    while idx < cp_count:
        tag = data[i]; i += 1
        if tag == 1: l = struct.unpack('>H', data[i:i+2])[0]; i += 2 + l
        elif tag in (3,4): i += 4
        elif tag in (5,6): i += 8; idx += 1
        elif tag in (7,8,16,19,20): i += 2
        elif tag in (9,10,11,12,17,18): i += 4
        elif tag == 15: i += 3
        else: break
        idx += 1
    
    i += 6  # access, this, super
    iface_count = struct.unpack('>H', data[i:i+2])[0]; i += 2 + iface_count * 2
    field_count = struct.unpack('>H', data[i:i+2])[0]; i += 2
    for _ in range(field_count):
        i += 6
        attr_count = struct.unpack('>H', data[i:i+2])[0]; i += 2
        for _ in range(attr_count):
            i += 2; al = struct.unpack('>I', data[i:i+4])[0]; i += 4 + al
    
    method_count = struct.unpack('>H', data[i:i+2])[0]; i += 2
    for _ in range(method_count):
        acc, name_idx, desc_idx = struct.unpack('>HHH', data[i:i+6]); i += 6
        mname = cp[name_idx][1].decode('utf-8', errors='replace') if cp[name_idx] else '?'
        mdesc = cp[desc_idx][1].decode('utf-8', errors='replace') if cp[desc_idx] else '?'
        attr_count = struct.unpack('>H', data[i:i+2])[0]; i += 2
        for _ in range(attr_count):
            attr_name_idx = struct.unpack('>H', data[i:i+2])[0]; i += 2
            al = struct.unpack('>I', data[i:i+4])[0]; i += 4
            aname = cp[attr_name_idx][1].decode('utf-8', errors='replace') if cp[attr_name_idx] else '?'
            if aname == 'Code' and mname in ('encodeCanMessage', 'parseSLCanMessageOrNull'):
                ms, ml, cl = struct.unpack('>HHI', data[i:i+8])
                print(f'\nMETHOD: {mname}{mdesc}  (code_len={cl})')
                lines = disasm(data, cp, i+8, min(cl, 500))
                for line in lines:
                    print(line)
            i += al
