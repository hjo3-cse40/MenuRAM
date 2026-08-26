#!/bin/sh
# Build a Release MenuRAM.app and install it (no Xcode debugger).
# Usage: scripts/install-local.sh [destination]
# Default destination: $HOME/Applications
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DEST="${1:-$HOME/Applications}"
DERIVED="$ROOT/.derivedData"
APP="$DERIVED/Build/Products/Release/MenuRAM.app"

cd "$ROOT"
xcodebuild \
  -project MenuRAM.xcodeproj \
  -scheme MenuRAM \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -quiet \
  build

mkdir -p "$DEST"
killall MenuRAM 2>/dev/null || true
rm -rf "$DEST/MenuRAM.app"
cp -R "$APP" "$DEST/MenuRAM.app"
open "$DEST/MenuRAM.app"

echo "Installed $DEST/MenuRAM.app (Release, no debugger)."
echo "Quit any copy still running from Xcode. Use Launch at Login on this app."
