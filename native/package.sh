#!/usr/bin/env bash
# Build LocalVideo.app — a real, double-clickable macOS app bundle from the SPM
# executable. Ad-hoc code-signed (fine for personal/local use; distribution
# would need a Developer ID + notarization).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/LocalVideo.app"
BIN_NAME="LocalVideo"

echo "==> Building release binary…"
swift build -c release --package-path "$ROOT"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/LocalVideoNative" "$APP/Contents/MacOS/$BIN_NAME"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> Code signing (ad-hoc)…"
codesign --force --sign - "$APP"

# Seed the user's config on first install (never overwrite existing data).
SUPPORT="$HOME/Library/Application Support/LocalVideo"
mkdir -p "$SUPPORT"
if [ ! -f "$SUPPORT/cameras.json" ] && [ -f "$ROOT/../cameras.json" ]; then
    cp "$ROOT/../cameras.json" "$SUPPORT/cameras.json"
    echo "==> Seeded $SUPPORT/cameras.json from the project config"
fi

echo "==> Done: $APP"
echo "    Launch with:  open \"$APP\""
