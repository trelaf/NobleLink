"""Reduce a cleaned Ghidra function to its protocol skeleton: USBManager field writes/reads,
send/receive calls, comparisons, progress and referenced strings.
Usage: python3 -I skeleton.py CSTRINGS DECOMP_FILE [--all]"""
import re, sys
cs = {}
for line in open(sys.argv[1], errors="replace"):
    m = re.match(r"^([0-9a-f]{16})  (.*)$", line.rstrip("\n"))
    if m:
        cs[int(m.group(1), 16)] = m.group(2)
def annot(line):
    def rep(m):
        v = int(m.group(0), 16) + 0x100000000 if len(m.group(0)) <= 8 else int(m.group(0), 16)
        s = cs.get(v)
        return m.group(0) + (' /*"%s"*/' % s[:60] if s is not None else "")
    return re.sub(r"0x3[def][0-9a-f]{4}\b", rep, line)
keep = re.compile(r"\+ 0x(38|40|48|50|58|60|68|70|78|80|88|8[9a-f]|9[0-9a-f]|a[0-9a-f]|b[0-9a-f])\)|onFunctionSend|readBuff|sendProgress|sendError|sendCusse|msleep|fromUtf8_helper|fromLocal8Bit|ComputeCRC|DataExportCRC|ObjectSerialze|QFile::|QDataStream|while|for \(|if \(|else|break|goto|return|memcpy|toInt|toUInt|toLatin1|toHex|number|append|QByteArray|== 0x|!= 0x|local_\w+\[")
allmode = "--all" in sys.argv
for line in open(sys.argv[2], errors="replace"):
    line = line.rstrip("\n")
    if allmode or keep.search(line):
        print(annot(line))
