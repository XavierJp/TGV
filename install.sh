#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.local/bin"
SHARE_DIR="$HOME/.local/share/tgv"

mkdir -p "$INSTALL_DIR" "$SHARE_DIR"

if ! command -v go >/dev/null 2>&1; then
  echo "✕ Go toolchain not found. Install it first (brew install go)."
  exit 1
fi

echo "Installing TGV..."

# 1. Build and install the TUI binary
echo "  Building tgv..."
cd "$SCRIPT_DIR"
go build -o "$INSTALL_DIR/tgv" ./cmd/tgv
echo "  Installed tgv to $INSTALL_DIR/tgv"

# 2. tgv-init bash script
install -m 0755 "$SCRIPT_DIR/bin/tgv-init" "$INSTALL_DIR/tgv-init"
echo "  Installed tgv-init to $INSTALL_DIR/tgv-init"

# 3. Dockerfile (referenced by tgv-init via TGV_DOCKERFILE)
install -m 0644 "$SCRIPT_DIR/docker/Dockerfile" "$SHARE_DIR/Dockerfile"
echo "  Installed Dockerfile to $SHARE_DIR/Dockerfile"

# 4. network-allowlist.sh (tgv-init applies it to restrict container egress)
install -m 0755 "$SCRIPT_DIR/docker/network-allowlist.sh" "$SHARE_DIR/network-allowlist.sh"
echo "  Installed network-allowlist.sh to $SHARE_DIR/network-allowlist.sh"

echo
echo "Done."
echo "Next: tgv-init --host user@ip --repo https://github.com/org/repo"
echo "Then: tgv"
