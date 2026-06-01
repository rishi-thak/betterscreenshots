#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$("$ROOT_DIR/scripts/build_app.sh" | tail -n 1)"
INSTALL_DIR="$HOME/Applications"
TARGET_APP="$INSTALL_DIR/SSClipboard.app"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_PLIST="$AGENT_DIR/com.rishi.ssclipboard.plist"

mkdir -p "$INSTALL_DIR"
mkdir -p "$AGENT_DIR"
mkdir -p "$TARGET_APP"

if [ -d "$TARGET_APP/Contents" ]; then
  rm -rf "$TARGET_APP/Contents"
fi
cp -R "$APP_PATH/Contents" "$TARGET_APP/Contents"

cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.rishi.ssclipboard</string>
  <key>ProgramArguments</key>
  <array>
    <string>$TARGET_APP/Contents/MacOS/ssclipboard</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF

launchctl unload "$AGENT_PLIST" >/dev/null 2>&1 || true
launchctl load "$AGENT_PLIST"

echo "Installed $TARGET_APP"
echo "Loaded $AGENT_PLIST"
