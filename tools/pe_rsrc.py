"""List (and optionally dump) PE resources. Usage: python3 -I pe_rsrc.py EXE [OUTDIR]"""
import struct, sys, os, math
from collections import Counter
d = open(sys.argv[1], 'rb').read()
out = sys.argv[2] if len(sys.argv) > 2 else None
pe = struct.unpack_from('<I', d, 0x3c)[0]
nsec = struct.unpack_from('<H', d, pe + 6)[0]
opt = struct.unpack_from('<H', d, pe + 20)[0]
secs = []
so = pe + 24 + opt
for i in range(nsec):
    name = d[so:so+8].rstrip(b'\0').decode()
    vsize, va, rsize, raw = struct.unpack_from('<IIII', d, so + 8)
    secs.append((name, va, vsize, raw, rsize)); so += 40
def rva2off(rva):
    for n, va, vs, raw, rs in secs:
        if va <= rva < va + max(vs, rs): return raw + rva - va
rs = [s for s in secs if s[0] == '.rsrc'][0]
base = rs[3]
def ent(b):
    if not b: return 0
    c = Counter(b); n = len(b)
    return -sum(v/n*math.log2(v/n) for v in c.values())
def name_of(v):
    if v & 0x80000000:
        o = base + (v & 0x7fffffff); ln = struct.unpack_from('<H', d, o)[0]
        return d[o+2:o+2+ln*2].decode('utf-16le')
    return str(v)
def walk(off, path):
    nn, ni = struct.unpack_from('<HH', d, base + off + 12)
    for i in range(nn + ni):
        nm, o = struct.unpack_from('<II', d, base + off + 16 + i*8)
        p = path + [name_of(nm)]
        if o & 0x80000000: walk(o & 0x7fffffff, p)
        else:
            rva, size, cp, _ = struct.unpack_from('<IIII', d, base + o)
            fo = rva2off(rva); blob = d[fo:fo+size]
            print('/'.join(p), 'size', size, 'entropy %.3f' % ent(blob[:1 << 20]), 'head', blob[:24].hex())
            if out:
                os.makedirs(out, exist_ok=True)
                open(os.path.join(out, '_'.join(p).replace('/', '_') + '.bin'), 'wb').write(blob)
walk(0, [])
