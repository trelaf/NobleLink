"""Strip Qt refcount/debug-stream noise from Ghidra decompiler output. Usage: python3 -I declean.py FILE"""
import re, sys
src = open(sys.argv[1], errors="replace").read()
# collapse the QString/QByteArray refcount release idiom
src = re.sub(r"if \(\*\(int \*\)\w+ != -1\) \{\s*if \(\*\(int \*\)\w+ != 0\) \{\s*LOCK\(\);\s*[^;]+;\s*UNLOCK\(\);\s*if \(\*\(int \*\)\w+ != 0\) goto \w+;\s*\}\s*QArrayData::deallocate\([^;]+;\s*\}", "/*rel*/", src)
src = re.sub(r"if \(\*\w+ != -1\) \{\s*if \(\*\w+ != 0\) \{\s*LOCK\(\);\s*[^;]+;\s*UNLOCK\(\);\s*if \(\*\w+ != 0\) goto \w+;\s*\}\s*QArrayData::deallocate\([^;]+;\s*\}", "/*rel*/", src)
src = re.sub(r"if \(\(?\w+\)?\[0x20\] != \(QTextStream\)0x0\) \{\s*QTextStream::operator<<\(\w+,' '\);\s*\}", "", src)
src = re.sub(r"if \(1 < \*\w+ \+ 1U\) \{\s*LOCK\(\);\s*[^;]+;\s*UNLOCK\(\);\s*\}", "/*ref*/", src)
src = re.sub(r"if \(1 < \*\(int \*\)\w+ \+ 1U\) \{\s*LOCK\(\);\s*[^;]+;\s*UNLOCK\(\);\s*\}", "/*ref*/", src)
src = re.sub(r"if \(\*\(int \*\)\w+ - 1U < 0xfffffffe\) \{\s*LOCK\(\);\s*[^;]+;\s*UNLOCK\(\);\s*\}", "/*ref*/", src)
src = re.sub(r"if \(\*\w+ - 1U < 0xfffffffe\) \{\s*LOCK\(\);\s*[^;]+;\s*UNLOCK\(\);\s*\}", "/*ref*/", src)
src = re.sub(r"if \(\*\(int \*\)(\w+) != -1\) \{\s*(?:\w+ = \w+;\s*)?if \(\*\(int \*\)\1 != 0\) \{\s*LOCK\(\);\s*[^;]+;\s*UNLOCK\(\);\s*if \(\*\(int \*\)\1 != 0\) goto \w+;\s*(?:\w+ = \w+;\s*)?\}\s*(?:\w+ = \w+;\s*)?QArrayData::deallocate\([^;]+;\s*(?:\w+ = \w+;\s*)?\}", "/*rel*/", src)
src = re.sub(r"\(?\w+ = USBManager::GetInstance\(\),\s*", "(", src)
src = re.sub(r"\n\s*\w+ = USBManager::GetInstance\(\);", "", src)
src = re.sub(r"\n\s*USBManager::GetInstance\(\);", "", src)
src = re.sub(r"\*\(\w+ \*\)\(\w+ \+ (0x[0-9a-f]+)\)", lambda m: "USB[%s]" % m.group(1), src)
out = []
for line in src.split("\n"):
    s = line.strip()
    if not s or s == "/*rel*/" or s == "/*ref*/":
        continue
    if re.match(r"^LAB_[0-9a-f]+:$", s):
        continue
    out.append(line)
# drop declarations block
text = "\n".join(out)
text = re.sub(r"\n  (?:undefined\d*|long|ulong|int|uint|char|uchar|bool|byte|short|ushort|code|QArrayData|QTextStream|QString|QByteArray|QDebug|QVariant|QListData|QFile|QDataStream|QSettings|QThread|double|float|void|QDir|QFileInfo|QTime|QDateTime|Q\w+)\s*\**\s*\*?\w+(?: \[\d+\])*;", "", text)
print(text)
