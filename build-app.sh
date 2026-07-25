#!/bin/zsh
# Builds Mustard.app from the Swift package. Output: build/Mustard.app
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/build"
APP="$OUT/Mustard.app"

swift build -c release --package-path "$DIR"
BIN_DIR="$(swift build -c release --package-path "$DIR" --show-bin-path)"
BIN="$BIN_DIR/Mustard"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mustard"

# MustardKit's Assets.xcassets (brand-mark logos) compile into a resource bundle
# next to the binary; Bundle.module looks for it under Contents/Resources.
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Mustard</string>
  <key>CFBundleIdentifier</key><string>com.cavehole.mustard</string>
  <key>CFBundleName</key><string>Mustard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
