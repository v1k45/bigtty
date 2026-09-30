#!/usr/bin/env bash
# Builds a distributable GhostHerdr.app (Intel + Apple Silicon) and zips it.
#   scripts/release.sh <version>   → build/release/GhostHerdr-<version>.{dmg,zip}
#
# Built with xcodebuild rather than `swift build`: Xcode's resource lookup
# for package resources checks the app's Contents/Resources, so the
# bundles can live there and the app can be signed. (SwiftPM's own lookup
# only tries the .app root, which signing forbids, and this machine's
# .build folder.)
set -euo pipefail

version="${1:?usage: scripts/release.sh <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
derived="build/xc"
out="build/release"

for scheme in GhostHerdr ghr; do
    xcodebuild -scheme "$scheme" -configuration Release -destination 'generic/platform=macOS' \
        -derivedDataPath "$derived" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet
done
products="$derived/Build/Products/Release"

app="$out/GhostHerdr.app"
rm -rf "$out"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$products/GhostHerdr" "$app/Contents/MacOS/GhostHerdr"
cp "$products/ghr" "$app/Contents/MacOS/ghr"
for bundle in "$products"/*.bundle; do
    cp -R "$bundle" "$app/Contents/Resources/"
done
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.ghostherdr.GhostHerdr</string>
    <key>CFBundleName</key><string>GhostHerdr</string>
    <key>CFBundleDisplayName</key><string>GhostHerdr</string>
    <key>CFBundleExecutable</key><string>GhostHerdr</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>${version}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signed (no Developer ID): a stable identity for notifications.
codesign --force --sign - --identifier dev.ghostherdr.ghr "$app/Contents/MacOS/ghr"
codesign --force --sign - --identifier dev.ghostherdr.GhostHerdr "$app"
codesign --verify --strict "$app"

zip="$out/GhostHerdr-${version}.zip"
ditto -c -k --keepParent "$app" "$zip"

# A disk image to drag the app into Applications from.
staging="$out/dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
dmg="$out/GhostHerdr-${version}.dmg"
hdiutil create -volname "GhostHerdr ${version}" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" -quiet
rm -rf "$staging"
codesign --force --sign - "$dmg"

echo "$zip"
echo "$dmg"
