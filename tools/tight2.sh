#!/bin/sh
# tight.sh plus removal of byte-concat noise. Usage: tight2.sh FILE
"$(dirname "$0")/tight.sh" "$1" | LC_ALL=C /usr/bin/grep -a -v -E "CONCAT1|cStack_\w+ = '\\\\0'|local_58\)+;?$|^\s*\)+;?$|^\s*;$|cStack_\w+ == '\\\\0'\) goto|cStack_\w+ = \(char\)|^\s*pQVar\w+ = \(QArrayData \*\)$|^\s*pQVar\w+ = local_\w+;$|^\s*local_\w+ = \(QTextStream \*\)pQVar\w+;$|^\s*pQVar\w+ = \(QArrayData \*\)local_\w+;$|^\s*goto LAB_\w+;$|== -1\) goto|== 0\) goto LAB"
