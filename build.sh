#!/bin/bash
# Builds MiniDictate.app next to this script, or at the path given as the first argument.
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:-MiniDictate.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
cp "$BIN/MiniDictate" "$APP/Contents/MacOS/MiniDictate"
# Resource bundles from dependencies, if any.
mkdir -p "$APP/Contents/Resources"
find "$BIN" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.minidictate</string>
    <key>CFBundleName</key><string>MiniDictate</string>
    <key>CFBundleExecutable</key><string>MiniDictate</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.4.0</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSMicrophoneUsageDescription</key><string>MiniDictate records your voice while you hold the dictation key.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>MiniDictate turns your speech into text.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP"
