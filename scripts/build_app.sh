#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SSClipboard.app"
APP_DIR="$ROOT_DIR/dist/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
SIGNING_IDENTITY="${SSC_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development:|Developer ID Application:/{print $2; exit}')}"

cd "$ROOT_DIR"
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$CONTENTS_DIR/Resources"

cp "$ROOT_DIR/App/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BUILD_DIR/ssclipboard" "$MACOS_DIR/ssclipboard"
chmod +x "$MACOS_DIR/ssclipboard"

if [[ -n "$SIGNING_IDENTITY" ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_DIR"
fi

echo "$APP_DIR"
