#!/bin/bash
set -e

echo "Installing tgv..."

# Build release binary
cargo build --release

# Install to ~/.cargo/bin (already in PATH for Rust users)
cp target/release/tgv ~/.cargo/bin/tgv
echo "  Installed tgv to ~/.cargo/bin/tgv"

# xbar plugin
XBAR_DIR="$HOME/Library/Application Support/xbar/plugins"
PLUGIN_SRC="$(cd "$(dirname "$0")" && pwd)/xbar/tgv.30s.sh"

if [ -d "$XBAR_DIR" ]; then
  ln -sf "$PLUGIN_SRC" "$XBAR_DIR/tgv.30s.sh"
  echo "  xbar plugin linked"
elif [ -d "/Applications/xbar.app" ]; then
  mkdir -p "$XBAR_DIR"
  ln -sf "$PLUGIN_SRC" "$XBAR_DIR/tgv.30s.sh"
  echo "  xbar plugin linked"
else
  echo "  xbar not found, skipping menu bar plugin"
fi

echo "Done. Run: tgv init --host user@ip --repo <url>"
