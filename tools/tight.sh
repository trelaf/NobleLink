#!/bin/sh
# Print a cleaned function with logging / Qt housekeeping lines removed. Usage: tight.sh FILE
LC_ALL=C /usr/bin/grep -a -v -E "QTextStream::operator<<|QDebug::|QMessageLogger|^\s*(LOCK|UNLOCK)\(\)|QArrayData::deallocate|local_\w+ = 2;$|uStack_\w+ = 0;$|local_\w+ = 0;$|= \"default\";|\+ -1;$|\+ 1;$|!= -1\) \{$|!= 0\) \{$|!= 0\) goto|___stack_chk|WARNING: Subroutine|SUB84|>> 0x20\);$|^\s*\}$|^\s*\{$|- 1U < 0xfffffffe|QTime::currentTime|DataManager::GetInstance\(\);$" "$1"
