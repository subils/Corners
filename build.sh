#!/bin/bash
# Builds Corners.app next to this script: release build, stripped, signed locally (ad hoc).
#   ./build.sh            build only
#   ./build.sh --install  build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release -Xlinker -no_adhoc_codesign  # signed once, below, after strip
BIN="$(swift build -c release --show-bin-path)/Corners"

APP=Corners.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
strip -x -o "$APP/Contents/MacOS/Corners" "$BIN"
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Corners 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/Corners.app
  cp -R "$APP" /Applications/
  open /Applications/Corners.app
  echo "Installed /Applications/Corners.app"
fi
