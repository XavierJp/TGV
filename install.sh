#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
SHARE_DIR="$HOME/.local/share/tgv"

mkdir -p "$INSTALL_DIR" "$SHARE_DIR"

echo "Installing TGV..."

# 1. tgv-init bash script
install -m 0755 "$SCRIPT_DIR/bin/tgv-init" "$INSTALL_DIR/tgv-init"
echo "  Installed tgv-init to $INSTALL_DIR/tgv-init"

# 2. Dockerfile (referenced by tgv-init via TGV_DOCKERFILE)
install -m 0644 "$SCRIPT_DIR/docker/Dockerfile" "$SHARE_DIR/Dockerfile"
echo "  Installed Dockerfile to $SHARE_DIR/Dockerfile"

# 3. Build the Swift menu bar / GUI app
echo "Building TGV macOS app..."
cd "$SCRIPT_DIR/app"
if ! swift build -c release; then
  echo "  Swift build failed"
  exit 1
fi
cp .build/release/TGV "$INSTALL_DIR/TGV"
codesign -fs - "$INSTALL_DIR/TGV"
echo "  Installed TGV to $INSTALL_DIR/TGV"

# 4. LaunchAgent for auto-start
PLIST="$HOME/Library/LaunchAgents/com.tgv.bar.plist"
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tgv.bar</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/TGV</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>TGV_DOCKERFILE</key>
        <string>$SHARE_DIR/Dockerfile</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/com.tgv.bar" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "  TGV will start on login"

cd "$SCRIPT_DIR"
echo
echo "Done."
echo "Next: tgv-init --host user@ip --repo https://github.com/org/repo"
