"""Enumerate all exports from REVLibDriver.dll using the PE export table."""

import struct
import os

DLL_PATH = os.path.join(
    os.path.dirname(__file__),
    "revlib_dlls",
    "REVLibDriver.dll"
)


def read_pe_exports(path):
    """Read export names from a PE DLL file."""
    with open(path, "rb") as f:
        data = f.read()
    
    # DOS header
    if data[:2] != b"MZ":
        print("Not a PE file")
        return []
    
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_offset:pe_offset+4] != b"PE\x00\x00":
        print("Invalid PE signature")
        return []
    
    # COFF header
    machine = struct.unpack_from("<H", data, pe_offset + 4)[0]
    num_sections = struct.unpack_from("<H", data, pe_offset + 6)[0]
    optional_header_size = struct.unpack_from("<H", data, pe_offset + 20)[0]
    
    # Optional header starts at pe_offset + 24
    opt_offset = pe_offset + 24
    magic = struct.unpack_from("<H", data, opt_offset)[0]
    
    if magic == 0x20B:  # PE32+
        # Export directory RVA at offset 112 from optional header start
        export_rva = struct.unpack_from("<I", data, opt_offset + 112)[0]
        export_size = struct.unpack_from("<I", data, opt_offset + 116)[0]
    elif magic == 0x10B:  # PE32
        export_rva = struct.unpack_from("<I", data, opt_offset + 96)[0]
        export_size = struct.unpack_from("<I", data, opt_offset + 100)[0]
    else:
        print(f"Unknown PE magic: 0x{magic:X}")
        return []
    
    if export_rva == 0:
        print("No export directory")
        return []
    
    # Parse section headers to map RVA to file offset
    sections_offset = opt_offset + optional_header_size
    sections = []
    for i in range(num_sections):
        sec_off = sections_offset + i * 40
        name = data[sec_off:sec_off+8].rstrip(b'\x00').decode('ascii', errors='replace')
        virtual_size = struct.unpack_from("<I", data, sec_off + 8)[0]
        virtual_addr = struct.unpack_from("<I", data, sec_off + 12)[0]
        raw_size = struct.unpack_from("<I", data, sec_off + 16)[0]
        raw_offset = struct.unpack_from("<I", data, sec_off + 20)[0]
        sections.append((name, virtual_addr, virtual_size, raw_offset, raw_size))
    
    def rva_to_offset(rva):
        for name, va, vs, ro, rs in sections:
            if va <= rva < va + max(vs, rs):
                return rva - va + ro
        return None
    
    # Parse export directory
    exp_off = rva_to_offset(export_rva)
    if exp_off is None:
        print("Cannot resolve export directory RVA")
        return []
    
    num_names = struct.unpack_from("<I", data, exp_off + 24)[0]
    names_rva = struct.unpack_from("<I", data, exp_off + 32)[0]
    
    names_off = rva_to_offset(names_rva)
    if names_off is None:
        print("Cannot resolve names RVA")
        return []
    
    exports = []
    for i in range(num_names):
        name_rva = struct.unpack_from("<I", data, names_off + i * 4)[0]
        name_off = rva_to_offset(name_rva)
        if name_off is not None:
            end = data.index(b'\x00', name_off)
            name = data[name_off:end].decode('ascii', errors='replace')
            exports.append(name)
    
    return exports


if __name__ == "__main__":
    exports = read_pe_exports(DLL_PATH)
    print(f"Found {len(exports)} exports:")
    for name in sorted(exports):
        print(f"  {name}")
