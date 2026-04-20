#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
APPS_DIR="$HOME/Applications"
SHARE_DIR="$HOME/.local/share/tgv"
APP_BUNDLE="$APPS_DIR/TGV.app"

mkdir -p "$INSTALL_DIR" "$SHARE_DIR" "$APPS_DIR"

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
BIN="$SCRIPT_DIR/app/.build/release/TGV"

# 4. Render app icon into an .icns
echo "Rendering app icon..."
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
"$BIN" --export-iconset "$ICONSET_DIR" >/dev/null
ICNS="$(mktemp -d)/AppIcon.icns"
iconutil -c icns -o "$ICNS" "$ICONSET_DIR"

# 5. Assemble .app bundle
echo "Assembling $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN" "$APP_BUNDLE/Contents/MacOS/TGV"
cp "$ICNS" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TGV</string>
    <key>CFBundleDisplayName</key>
    <string>TGV</string>
    <key>CFBundleIdentifier</key>
    <string>com.tgv.bar</string>
    <key>CFBundleExecutable</key>
    <string>TGV</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
codesign -fs - "$APP_BUNDLE"
echo "  Installed $APP_BUNDLE"

# Legacy symlink so `tgv` / existing callers keep working.
ln -sf "$APP_BUNDLE/Contents/MacOS/TGV" "$INSTALL_DIR/TGV"

# 6. LaunchAgent for auto-start (points at the bundled binary so the Dock icon shows)
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
        <string>$APP_BUNDLE/Contents/MacOS/TGV</string>
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
