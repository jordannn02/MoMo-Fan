#!/bin/bash
set -euo pipefail
export TMPDIR="${TMPDIR:-/tmp}"
if [[ ! -d "$TMPDIR" ]]; then export TMPDIR=/tmp; fi
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-$TASK_ROOT/../../outputs}"
SIGNING_IDENTITY="${MOMOFAN_SIGNING_IDENTITY:-Developer ID Application: YUKAI WANG (F8222FBL22)}"
cd "$TASK_ROOT"
BUILD_DIR="${MOMOFAN_BUILD_DIR:-/tmp/MoMoFan-build-$UID}"
swift build -c release --scratch-path "$BUILD_DIR"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)"
# Sign outside File Provider folders, which may reattach Finder metadata mid-sign.
APP_DIR="$BUILD_DIR/bundle/MoMo Fan.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Library/LaunchDaemons"
cp "$BIN_DIR/MoMoFan" "$APP_DIR/Contents/MacOS/MoMoFan"
cp "$BIN_DIR/MoMoFanHelper" "$APP_DIR/Contents/MacOS/MoMoFanHelper"
# Exclude local source paths and debug symbols from distributable binaries.
strip -S "$APP_DIR/Contents/MacOS/MoMoFan" "$APP_DIR/Contents/MacOS/MoMoFanHelper"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$APP_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp Resources/tw.momo.MoMoFan.helper.plist "$APP_DIR/Contents/Library/LaunchDaemons/"
swift scripts/make-icon.swift "$BUILD_DIR/AppIcon.iconset"
iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
xattr -cr "$APP_DIR"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --identifier tw.momo.MoMoFan.helper "$APP_DIR/Contents/MacOS/MoMoFanHelper"
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" --identifier tw.momo.MoMoFan "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
mkdir -p "$OUTPUT_DIR"
# Keep the signed bundle in a ZIP when delivering into iCloud/File Provider folders.
ditto -c -k --keepParent --norsrc --noextattr "$APP_DIR" "$BUILD_DIR/MoMo Fan.zip"
cp "$BUILD_DIR/MoMo Fan.zip" "$OUTPUT_DIR/MoMo Fan.zip"
printf 'Built: %s\nPackaged: %s\n' "$APP_DIR" "$OUTPUT_DIR/MoMo Fan.zip"
