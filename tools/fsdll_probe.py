"""Exploratory parser for .fsdll model backups. Usage: python3 -I fsdll_probe.py FILE..."""
import sys
from collections import Counter, OrderedDict

def frames(data):
    off = 0
    n = len(data)
    while off < n:
        if data[off:off+2] != b"\r\n":
            yield ("junk", off, data[off:off+64])
            return
        ln = int.from_bytes(data[off+2:off+4], "big")
        body = data[off+4:off+4+ln]
        x = 0
        for b in data[off:off+4+ln-1]:
            x ^= b
        ok = (x == body[-1]) if body else False
        yield ("frame", off, ln, body, ok)
        off += 4 + ln

for path in sys.argv[1:]:
    data = open(path, "rb").read()
    print("==", path, len(data))
    cnt = 0; bad = 0
    cmds = Counter(); lens = Counter()
    names = []
    first_ids = []
    boundaries = []
    for fr in frames(data):
        if fr[0] == "junk":
            print("  JUNK at", hex(fr[1]), fr[2].hex())
            break
        _, off, ln, body, ok = fr
        cnt += 1
        if not ok: bad += 1
        cmds[(body[0], body[1])] += 1
        lens[ln] += 1
        pid = int.from_bytes(body[3:5], "big")
        if pid == 0x07d0:
            boundaries.append((off, body.hex()))
        if pid == 0x07d1:
            names.append((off, body[2], body[5:-1].split(b"\0")[0].decode("latin1")))
    print("  frames", cnt, "bad-xor", bad)
    print("  cmd bytes", dict(cmds))
    print("  len hist", sorted(lens.items()))
    print("  model-start (0x07d0) frames:", len(boundaries))
    for o, n_idx, nm in names:
        print("   name @%#x idx=%d %r" % (o, n_idx, nm))
