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

hdiutil create -volname "MiniDictate" -srcfolder "$STAGE" -ov -format UDZO dist/MiniDictate.dmg >/dev/null
rm -rf "$STAGE"
echo "Created $PWD/dist/MiniDictate.dmg"