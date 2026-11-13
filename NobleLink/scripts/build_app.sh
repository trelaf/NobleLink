#!/bin/sh
# Build release binaries and wrap the SwiftUI executable in a minimal .app bundle.
# Works with the Command Line Tools alone (no Xcode project needed).
set -eu
cd "$(dirname "$0")/.."

VERSION="1.0.0"

# Universal binaries: Apple silicon and Intel.
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

DIST="dist"
APP="$DIST/NobleLink.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/NobleLinkApp" "$APP/Contents/MacOS/NobleLink"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/noble" "$DIST/noble"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>NobleLink</string>
    <key>CFBundleDisplayName</key><string>NobleLink</string>
    <key>CFBundleIdentifier</key><string>io.github.trelaf.NobleLink</string>
    <key>CFBundleExecutable</key><string>NobleLink</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <!-- FlySky's update catalogue is only served over plain HTTP. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSExceptionDomains</key>
        <dict>
            <key>maxhom.cn</key>
            <dict>
                <key>NSIncludesSubdomains</key><true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
            <key>flyskytech.com</key>
            <dict>
                <key>NSIncludesSubdomains</key><true/>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
            </dict>
        </dict>
    </dict>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>FlySky model backup</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>CFBundleTypeExtensions</key><array><string>fsdll</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Make Finder and the Dock pick up a changed icon.
touch "$APP"

# Ad-hoc signature so macOS will launch it locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "note: codesign failed; the app may still run"

echo "Built $APP and $DIST/noble"
