#!/bin/bash
# Build the release .app bundle and wrap it in a drag-to-Applications DMG.
# Usage: ./scripts/package-dmg.sh [version]   (default 1.0.0)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
APP_NAME="Bennett Usage"
DIST="dist"
ROOT="$DIST/dmg-root"

swift build -c release --product BennettUsageApp
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$DIST"
mkdir -p "$ROOT/$APP_NAME.app/Contents/MacOS"
cp "$BIN_DIR/BennettUsageApp" "$ROOT/$APP_NAME.app/Contents/MacOS/"
sed "s/__VERSION__/$VERSION/g" packaging/Info.plist > "$ROOT/$APP_NAME.app/Contents/Info.plist"
printf 'APPL????' > "$ROOT/$APP_NAME.app/Contents/PkgInfo"

# Ad-hoc signature (no Developer ID): first launch needs right-click -> Open.
codesign --force --deep --sign - "$ROOT/$APP_NAME.app"
codesign --verify --strict "$ROOT/$APP_NAME.app"

ln -s /Applications "$ROOT/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$ROOT" -ov -format UDZO "$DIST/BennettUsage-$VERSION.dmg"
ls -lh "$DIST"
