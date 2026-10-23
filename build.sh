#!/usr/bin/env bash
# Build Awake.app into dist/ and (with --install) copy it to /Applications.
# Uses swiftc directly: SwiftPM's manifest step doesn't link with these
# Command Line Tools, and a stale module.modulemap in the CLT duplicates
# SwiftBridging — the overlay hides it without touching the system.
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --show-sdk-path)"
VERSION="$(cat VERSION)"
mkdir -p .build/vfs dist
: > .build/vfs/empty.modulemap
cat > .build/vfs/overlay.yaml <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [
  { "type": "directory", "name": "/Library/Developer/CommandLineTools/usr/include/swift",
    "contents": [ { "type": "file", "name": "module.modulemap", "external-contents": "$PWD/.build/vfs/empty.modulemap" } ] } ] }
YAML
VFS=(-vfsoverlay .build/vfs/overlay.yaml -Xcc -ivfsoverlay -Xcc .build/vfs/overlay.yaml)

# a universal binary, so it runs on Apple silicon and Intel Macs
for ARCH in arm64 x86_64; do
  swiftc -O -parse-as-library -target $ARCH-apple-macosx15.0 -sdk "$SDK" "${VFS[@]}" \
    -module-cache-path .build/cache-$ARCH \
    Sources/Awake/*.swift -framework IOKit -framework ServiceManagement -o .build/Awake-$ARCH
done
lipo -create .build/Awake-arm64 .build/Awake-x86_64 -output .build/Awake

APP=dist/Awake.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/Awake "$APP/Contents/MacOS/Awake"

# icon
if [ ! -f .build/AppIcon.icns ]; then
  swiftc -O -target arm64-apple-macosx15.0 -sdk "$SDK" "${VFS[@]}" tools/icon.swift -o .build/icon
  .build/icon .build/icon-1024.png
  ICONSET=.build/AppIcon.iconset; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s .build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) .build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Awake</string>
  <key>CFBundleDisplayName</key><string>Awake</string>
  <key>CFBundleIdentifier</key><string>com.iota.awake</string>
  <key>CFBundleExecutable</key><string>Awake</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Awake asks for your admin password once to set up closed-lid mode.</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = "--package" ]; then
  # release assets: a zip and a drag-to-Applications disk image
  rm -f "dist/Awake-$VERSION.zip" "dist/Awake-$VERSION.dmg"
  ditto -c -k --keepParent "$APP" "dist/Awake-$VERSION.zip"
  STAGE=.build/dmg; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Awake $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/Awake-$VERSION.dmg" >/dev/null
  echo "packaged dist/Awake-$VERSION.zip and dist/Awake-$VERSION.dmg"
fi

if [ "${1:-}" = "--install" ]; then
  osascript -e 'tell application "Awake" to quit' >/dev/null 2>&1 || true
  pkill -x Awake 2>/dev/null || true
  rm -rf /Applications/Awake.app
  cp -R "$APP" /Applications/Awake.app
  echo "installed /Applications/Awake.app"
fi
