#!/bin/bash
set -e

echo "Uninstalling TGV..."

# Legacy LaunchAgent from the Swift app era — remove if present.
PLIST="$HOME/Library/LaunchAgents/com.tgv.bar.plist"
if [ -f "$PLIST" ]; then
  launchctl bootout "gui/$(id -u)/com.tgv.bar" 2>/dev/null || true
  rm -f "$PLIST"
  echo "  Removed legacy LaunchAgent"
fi

# Legacy Swift .app bundle.
APP_BUNDLE="$HOME/Applications/TGV.app"
if [ -d "$APP_BUNDLE" ]; then
  rm -rf "$APP_BUNDLE"
  echo "  Removed legacy $APP_BUNDLE"
fi

# Binaries + shared files
for f in \
  "$HOME/.local/bin/tgv" \
  "$HOME/.local/bin/TGV" \
  "$HOME/.local/bin/tgv-init" \
  "$HOME/.local/share/tgv/Dockerfile" \
  "$HOME/.local/share/tgv/network-allowlist.sh"; do
  if [ -e "$f" ] || [ -L "$f" ]; then
    rm -f "$f"
    echo "  Removed $f"
  fi
done
rmdir "$HOME/.local/share/tgv" 2>/dev/null || true

# Legacy Rust install (if present)
if [ -f "$HOME/.cargo/bin/tgv" ]; then
  rm -f "$HOME/.cargo/bin/tgv"
  echo "  Removed legacy ~/.cargo/bin/tgv"
fi

# Config
if [ -d "$HOME/.tgv" ]; then
  read -p "  Remove config (~/.tgv)? [y/N] " answer
  if [[ "$answer" =~ ^[Yy]$ ]]; then
    rm -rf "$HOME/.tgv"
    echo "  Removed ~/.tgv"
  else
    echo "  Kept ~/.tgv"
  fi
fi

echo "Done."
