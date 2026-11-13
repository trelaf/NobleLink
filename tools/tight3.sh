#!/bin/sh
# tight2.sh plus removal of alloca return-address stores and SendFormat struct copies. Usage: tight3.sh FILE
"$(dirname "$0")/tight2.sh" "$1" | LC_ALL=C /usr/bin/grep -a -v -E "\(long\)&uStack_38 \+ lVar\w+\) = 0x1000|^\s*uVar\w+ = USB\[0x(30|34|38|3c|40|44|48|4c|54|58|5c)\];$|\(long\)local_50 \+ lVar\w+ \+ 0x[2-4][0-9a-f]\) = |pUVar\w+ = \(USBManager \*\)USBManager::GetInstance|uStack_38 = CONCAT44|^\s*stack0x\w+ =$"
