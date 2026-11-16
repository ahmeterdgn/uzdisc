#!/usr/bin/env bash
# UzDisc.app paketini oluşturur (Apple Silicon + Intel evrensel).
# Kullanım: VERSION=1.0.0 ./scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
ARCHS="${ARCHS:---arch arm64 --arch x86_64}"
SIGN_ID="${SIGN_ID:--}" # varsayılan: ad-hoc imza

echo "▸ Derleniyor ($VERSION)…"
# shellcheck disable=SC2086
swift build -c release $ARCHS
# shellcheck disable=SC2086
BIN="$(swift build -c release $ARCHS --show-bin-path)"

APP="build/UzDisc.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/UzDisc" "$APP/Contents/MacOS/UzDisc"
cp "$BIN/uzdisc-helper" "$APP/Contents/MacOS/uzdisc-helper"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp docs/uzmoon.png "$APP/Contents/Resources/uzmoon.png"
printf "APPL????" > "$APP/Contents/PkgInfo"

echo "▸ İmzalanıyor ($SIGN_ID)…"
codesign --force --options runtime --timestamp=none -s "$SIGN_ID" "$APP/Contents/MacOS/uzdisc-helper"
codesign --force --options runtime --timestamp=none -s "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "✓ $APP"
