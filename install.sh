#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing tgv..."

# Build release binary
cargo build --release

# Install to ~/.cargo/bin (already in PATH for Rust users)
cp target/release/tgv ~/.cargo/bin/tgv
codesign -fs - ~/.cargo/bin/tgv
echo "  Installed tgv to ~/.cargo/bin/tgv"

# Menu bar app
echo "Building TGVBar menu bar app..."
cd "$SCRIPT_DIR/menubar"
if ! swift build -c release; then
  echo "  Swift build failed"
  exit 1
fi
INSTALL_DIR="$HOME/.local/bin"
mkdir -p "$INSTALL_DIR"
cp .build/release/TGVBar "$INSTALL_DIR/TGVBar"
codesign -fs - "$INSTALL_DIR/TGVBar"
echo "  Installed TGVBar to $INSTALL_DIR/TGVBar"

# Launch agent for auto-start
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
        <string>$INSTALL_DIR/TGVBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF
launchctl bootout "gui/$(id -u)/com.tgv.bar" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "  TGVBar will start on login"

cd "$SCRIPT_DIR"
echo "Done. Run: tgv init --host user@ip --repo <url>"
