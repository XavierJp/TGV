# TGV development tasks

# Run the TUI
run:
    @exec go run ./cmd/tgv

# Build release binary into ~/.local/bin/tgv
build:
    go build -o ~/.local/bin/tgv ./cmd/tgv

# Install everything (binary + tgv-init + Dockerfile)
install:
    ./install.sh

# Uninstall
uninstall:
    ./uninstall.sh

# Init a remote server
init *ARGS:
    ./bin/tgv-init {{ARGS}}

# Clean Go build cache for this module
clean:
    go clean ./...

# Lint / vet
vet:
    go vet ./...
