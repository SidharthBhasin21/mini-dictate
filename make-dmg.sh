#!/bin/bash
# Packages a fresh build as dist/MiniDictate.dmg for installing on other Macs.
# Builds into dist/, so the MiniDictate.app you run from this folder is left untouched.
set -euo pipefail
cd "$(dirname "$0")"

STAGE="dist/dmg"
rm -rf dist
mkdir -p "$STAGE"

./build.sh "$STAGE/MiniDictate.app"
ln -s /Applications "$STAGE/Applications"

# Build a writable image first so the mounted volume can be given the app's icon, then compress it.
hdiutil create -volname "MiniDictate" -srcfolder "$STAGE" -ov -format UDRW dist/rw.dmg >/dev/null
MOUNT="$(mktemp -d)"
hdiutil attach dist/rw.dmg -nobrowse -noautoopen -mountpoint "$MOUNT" >/dev/null
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
if command -v SetFile >/dev/null; then
    SetFile -c icnC "$MOUNT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT"
fi
hdiutil detach "$MOUNT" >/dev/null
hdiutil convert dist/rw.dmg -format UDZO -o dist/MiniDictate.dmg >/dev/null
rm -rf dist/rw.dmg "$STAGE"
echo "Created $PWD/dist/MiniDictate.dmg"