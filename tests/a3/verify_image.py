#!/usr/bin/env python3
"""Verify locally generated UF2 against application HEX; never accesses a device."""
from pathlib import Path
import struct, sys, zipfile, json
hex_path, uf2_path, dfu_path = map(Path, sys.argv[1:4])
mem = {}; upper = 0
for line in hex_path.read_text().splitlines():
    if not line: continue
    assert line[0] == ':'
    raw = bytes.fromhex(line[1:]); assert sum(raw) % 256 == 0
    n = raw[0]; a = int.from_bytes(raw[1:3],'big'); kind = raw[3]
    data = raw[4:4+n]; assert len(raw)==n+5
    if kind == 0:
        for i,b in enumerate(data): mem[upper+a+i] = b
    elif kind == 2: upper = int.from_bytes(data,'big') << 4
    elif kind == 4: upper = int.from_bytes(data,'big') << 16
    elif kind == 1: break
    elif kind not in (3,5): raise AssertionError(f'unexpected HEX kind {kind}')
assert min(mem)==0x27000 and max(mem)<0xED000, 'not an application-only image'
uf2 = uf2_path.read_bytes(); assert len(uf2)%512==0
blocks = len(uf2)//512; reconstructed={}; indices=set()
for offset in range(0,len(uf2),512):
    b = uf2[offset:offset+512]
    m0,m1,flags,addr,size,index,count,family = struct.unpack_from('<8I',b)
    assert (m0,m1)==(0x0A324655,0x9E5D5157)
    assert struct.unpack_from('<I',b,508)[0]==0x0AB16F30
    assert flags & 0x2000 and family==0xADA52840
    assert size<=476 and count==blocks and index not in indices
    assert addr>=0x27000 and addr+size<=0xED000
    indices.add(index)
    for i,v in enumerate(b[32:32+size]): reconstructed[addr+i]=v
assert len(indices)==blocks
assert all(reconstructed.get(a)==v for a,v in mem.items())
with zipfile.ZipFile(dfu_path) as z:
    manifest=json.loads(z.read('manifest.json'))['manifest']
    assert set(manifest)=={'application','dfu_version'}, 'DFU ZIP must contain application only'
    app=manifest['application']
    assert app['bin_file'] in z.namelist() and app['dat_file'] in z.namelist()
    payload=z.read(app['bin_file'])
    base=min(mem)
    assert all(payload[a-base]==v for a,v in mem.items())
print(f'PASS: UF2 {blocks} blocks/family 0xADA52840 matches {len(mem)} HEX bytes; application-only 0x{min(mem):X}..0x{max(mem):X}; DFU ZIP contains application only')
