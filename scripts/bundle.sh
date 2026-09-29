#!/usr/bin/env bash
# Builds GhostHerdr.app from the SwiftPM products.
#   scripts/bundle.sh [debug|release]   → build/GhostHerdr.app
set -euo pipefail

config="${1:-debug}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c "$config" --product GhostHerdr
swift build -c "$config" --product ghr
bin="$(swift build -c "$config" --show-bin-path)"

app="build/GhostHerdr.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/GhostHerdr" "$app/Contents/MacOS/GhostHerdr"
cp "$bin/ghr" "$app/Contents/MacOS/ghr"
# SwiftPM's generated Bundle.module looks next to the app bundle's root.
for bundle in "$bin"/*.bundle; do
    cp -R "$bundle" "$app/"
done

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.ghostherdr.GhostHerdr</string>
    <key>CFBundleName</key><string>GhostHerdr</string>
    <key>CFBundleExecutable</key><string>GhostHerdr</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

echo "$app"
