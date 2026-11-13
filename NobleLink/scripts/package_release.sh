#!/bin/sh
# Build universal release binaries and package them for a GitHub release:
#   dist/release/NobleLink-<version>-macOS.zip   the app
#   dist/release/noble-<version>-macOS.zip       the command-line tool
#   dist/release/SHA256SUMS.txt
# Publish with:  gh release create v<version> dist/release/* --title ... --notes-file ...
set -eu
cd "$(dirname "$0")/.."

./scripts/build_app.sh
VERSION="$(plutil -extract CFBundleShortVersionString raw dist/NobleLink.app/Contents/Info.plist)"

OUT="dist/release"
rm -rf "$OUT"
mkdir -p "$OUT"

# ditto keeps the bundle's structure, permissions and signature intact.
ditto -c -k --sequesterRsrc --keepParent dist/NobleLink.app "$OUT/NobleLink-$VERSION-macOS.zip"

codesign --force --sign - dist/noble >/dev/null 2>&1 || true
STAGE="$(mktemp -d)"
cp dist/noble "$STAGE/noble"
ditto -c -k --sequesterRsrc "$STAGE" "$OUT/noble-$VERSION-macOS.zip"
rm -rf "$STAGE"

( cd "$OUT" && shasum -a 256 *.zip > SHA256SUMS.txt )

echo "Release files for $VERSION in $OUT:"
ls -l "$OUT"
