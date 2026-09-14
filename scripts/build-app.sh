#!/usr/bin/env bash
# Builds dist/Aloud.app (+ zip) from the SwiftPM package. No Xcode project needed.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/fetch-deps.sh >/dev/null
swift build -c release 2>&1 | grep -E "error|warning: unre|Build complete" || true
APP="dist/Aloud.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Aloud "$APP/Contents/MacOS/Aloud"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles (FluidAudio ships G2P data) must sit next to the executable's Resources.
for b in .build/release/*.bundle; do [ -d "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
# Dynamic frameworks from binary targets go into Contents/Frameworks.
mkdir -p "$APP/Contents/Frameworks"
for f in .build/release/*.framework; do [ -d "$f" ] && cp -R "$f" "$APP/Contents/Frameworks/"; done
echo -n "APPL????" > "$APP/Contents/PkgInfo"
# Ad-hoc signature with a stable identifier so macOS remembers Full Disk Access across rebuilds.
codesign --force --sign - --identifier com.dunebru.aloud --options runtime --entitlements packaging/Aloud.entitlements "$APP" 2>/dev/null \
  || codesign --force --sign - --identifier com.dunebru.aloud "$APP"
rm -f dist/Aloud.zip
ditto -c -k --keepParent "$APP" dist/Aloud.zip
echo "→ $APP  ($(du -sh "$APP" | cut -f1))"
