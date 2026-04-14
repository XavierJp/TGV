# TGV development tasks

# Build and run the macOS app (kills any running instance first)
run:
    @pkill -f .build/debug/TGV 2>/dev/null || true
    @sleep 0.5
    @mkdir -p ~/.local/share/tgv && cp docker/Dockerfile ~/.local/share/tgv/Dockerfile
    cd app && swift build 2>&1 | tail -5 && .build/debug/TGV &

# Build release binary
build:
    cd app && swift build -c release 2>&1 | tail -5

# Install everything (app + tgv-init + LaunchAgent)
install:
    ./install.sh

# Init a remote server
init *ARGS:
    ./bin/tgv-init {{ARGS}}

# Kill running app
kill:
    @pkill -f .build/debug/TGV 2>/dev/null || true
    @pkill -f .build/release/TGV 2>/dev/null || true
    @echo "killed"

# Clean build artifacts
clean:
    cd app && rm -rf .build .swiftpm
