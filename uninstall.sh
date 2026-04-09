#!/bin/bash
set -e

echo "Uninstalling tgv..."

# Stop and remove LaunchAgent
PLIST="$HOME/Library/LaunchAgents/com.tgv.bar.plist"
if [ -f "$PLIST" ]; then
  launchctl bootout "gui/$(id -u)/com.tgv.bar" 2>/dev/null || true
  rm -f "$PLIST"
  echo "  Removed LaunchAgent"
fi

# Kill running TGVBar
pkill TGVBar 2>/dev/null && echo "  Stopped TGVBar" || true

# Remove binaries
for bin in "$HOME/.cargo/bin/tgv" "$HOME/.local/bin/TGVBar"; do
  if [ -f "$bin" ]; then
    rm -f "$bin"
    echo "  Removed $bin"
  fi
done

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
