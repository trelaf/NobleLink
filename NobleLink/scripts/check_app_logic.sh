#!/bin/sh
# Headless checks of the app's restore-plan and firmware-install logic (no window, no transmitter).
# Usage: scripts/check_app_logic.sh [backup.fsdll]
set -eu
cd "$(dirname "$0")/.."
swift build >/dev/null
NOBLELINK_PLAN_CHECK="${1:-../samples/models/NoblePlus_Dec21.fsdll}" "$(swift build --show-bin-path)/NobleLinkApp" || exit 1
NEW="../samples/firmware/NoblePlusEN_1.0.31-4FCC.exe"
OLD="../samples/firmware/Flysky_Noble+_EN_UpdateFirmware_1.0.22FCC.exe"
if [ -f "$NEW" ] && [ -f "$OLD" ]; then
    NOBLELINK_INSTALL_CHECK="$NEW:$OLD" "$(swift build --show-bin-path)/NobleLinkApp"
fi
