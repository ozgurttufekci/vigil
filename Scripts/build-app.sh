#!/usr/bin/env bash
#
# Assembles Vigil.app from the SwiftPM executable.
#
# Building the bundle by hand rather than with Xcode keeps the whole app buildable with only the
# Command Line Tools. Xcode is needed later for the Control Center extension, not for this.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-debug}"
APP_NAME="Vigil"
BUNDLE_ID="dev.vigil.app"
VERSION="0.1.0"

echo "Building VigilApp ($CONFIGURATION)…"
swift build --product VigilApp -c "$CONFIGURATION"

BINARY="$(swift build --product VigilApp -c "$CONFIGURATION" --show-bin-path)/VigilApp"
[[ -f "$BINARY" ]] || { echo "error: binary not found at $BINARY" >&2; exit 1; }

APP_DIR="build/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Agent app: lives in the menu bar, with no Dock icon and no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key>
    <string>GNU General Public License v3.0 or later</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Enough to run locally and to keep UserNotifications and UserDefaults working;
# distribution needs a real Developer ID signature and notarization.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR" 2>/dev/null \
    || echo "warning: ad-hoc signing failed; the app will still run" >&2

echo "Built $APP_DIR"
