#!/bin/zsh
# Builds Mustard.app from the Swift package. Output: build/Mustard.app
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/build"
APP="$OUT/Mustard.app"

swift build -c release --package-path "$DIR"
BIN_DIR="$(swift build -c release --package-path "$DIR" --show-bin-path)"
BIN="$BIN_DIR/Mustard"
RESOURCE_BUNDLE="$BIN_DIR/Mustard_MustardKit.bundle"

# The contract sits at the bundle root under SwiftPM's native build system and
# under Contents/Resources with Swift Build (tools 6.x). Runtime lookup uses
# Bundle APIs, which resolve either; these checks must accept both too.
contract_in_bundle() {
  [[ -r "$1/MustardAgentContract.md" || -r "$1/Contents/Resources/MustardAgentContract.md" ]]
}

if ! contract_in_bundle "$RESOURCE_BUNDLE"; then
  echo "Missing MustardKit resource bundle: $RESOURCE_BUNDLE" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Mustard"
# Keep nested resources in the standard signed app location. AgentTurnContract
# checks this packaged bundle before Bundle.module's development-build lookup.
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/Mustard_MustardKit.bundle"

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
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Voice capture (F25, ADR-0011): both keys are hard-required — macOS kills
       the app on first mic/speech access without them. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>Mustard listens while you hold the capture hotkey so your spoken task can be transcribed.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Mustard transcribes your held-hotkey voice captures on this Mac to create tasks.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

if ! contract_in_bundle "$APP/Contents/Resources/Mustard_MustardKit.bundle"; then
  echo "Assembled app is missing the worker contract resource" >&2
  exit 1
fi

# Prove workerContract resolves the packaged copy, not Bundle.module's absolute
# .build fallback.
# This verifier exits before SwiftUI or MustardContainer initialization, so it cannot
# launch UI or touch the user's persistent store.
HIDDEN_RESOURCE_BUNDLE="$RESOURCE_BUNDLE.packaging-verification-hidden"
rm -rf "$HIDDEN_RESOURCE_BUNDLE"
mv "$RESOURCE_BUNDLE" "$HIDDEN_RESOURCE_BUNDLE"
restore_resource_bundle() {
  if [[ -d "$HIDDEN_RESOURCE_BUNDLE" ]]; then
    mv "$HIDDEN_RESOURCE_BUNDLE" "$RESOURCE_BUNDLE"
  fi
}
trap restore_resource_bundle EXIT
"$APP/Contents/MacOS/Mustard" --verify-worker-contract
restore_resource_bundle
trap - EXIT

echo "Built $APP"
