#!/bin/zsh
# Builds Yell.app from the Swift package. Output: build/Yell.app
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/build"
APP="$OUT/Yell.app"

swift build -c release --package-path "$DIR"
BIN_DIR="$(swift build -c release --package-path "$DIR" --show-bin-path)"
BIN="$BIN_DIR/Yell"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Yell"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Yell</string>
  <key>CFBundleIdentifier</key><string>com.cavehole.yell</string>
  <key>CFBundleName</key><string>Yell</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Yell listens while you hold the dictation hotkey and during meeting capture.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Yell transcribes speech on device for dictation and meetings.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "Built $APP"
