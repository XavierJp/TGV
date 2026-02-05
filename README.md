# Yolo Sandbox

Run Claude Code in an isolated Apple Container with VM-level isolation and optional network restrictions.

## Naming Convention

| Name | Type | Description |
|------|------|-------------|
| `yolo-sandbox` | **Image** | The built container image (template) |
| `yolo` | **Container** | A running instance of the image |

## Requirements

- Mac with Apple Silicon (M1/M2/M3/M4)
- macOS 26 (Tahoe) or later
- [Apple Container CLI](https://github.com/apple/container/releases)
- Anthropic API key

## Quick Start

```bash
# Start the container system
container system start

# Build the image
container build --tag yolo-sandbox .

# Run Claude Code with your project mounted
container run \
    --name yolo \
    --tty \
    --interactive \
    --volume /path/to/your/project:/workspace \
    --env ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY \
    yolo-sandbox
```

## Build Arguments

Customize versions at build time:

| Argument | Default | Description |
|----------|---------|-------------|
| `NODE_VERSION` | `22` | Node.js version (installed via nvm) |
| `PYTHON_VERSION` | `3.12` | Python version (installed via uv) |
| `INCLUDE_FIREWALL` | `true` | Include firewall capability (`false` to exclude entirely) |

Example with custom versions:

```bash
container build \
    --tag yolo-sandbox \
    --build-arg NODE_VERSION=20 \
    --build-arg PYTHON_VERSION=3.11 \
    .
```

Example without firewall capability:

```bash
container build \
    --tag yolo-sandbox \
    --build-arg INCLUDE_FIREWALL=false \
    .
```

## Environment Variables

Configure runtime behavior:

| Variable | Default | Description |
|----------|---------|-------------|
| `ANTHROPIC_API_KEY` | (required) | Your Anthropic API key |
| `ENABLE_FIREWALL` | `true` | Enable network restrictions (`false` to disable) |

Example with firewall disabled:

```bash
container run \
    --name yolo \
    --tty \
    --interactive \
    --volume /path/to/project:/workspace \
    --env ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY \
    --env ENABLE_FIREWALL=false \
    yolo-sandbox
```

## Network Restrictions

When `ENABLE_FIREWALL=true` (default), outbound traffic is limited to:

| Domain | Purpose |
|--------|---------|
| `api.anthropic.com` | Claude API calls |
| `registry.npmjs.org` | npm package installs |
| `github.com` | Git operations |
| `api.github.com` | GitHub API |
| `raw.githubusercontent.com` | Raw file access |

All other outbound connections are blocked.

## Security Benefits

Apple Containers provide **VM-level isolation**:

- Each container runs in its own lightweight virtual machine
- Filesystem isolation from host (only mounted volumes accessible)
- No shared kernel with other containers
- Optional network restrictions limit attack surface
- Non-root user (`agent`) runs Claude Code

## Useful Commands

```bash
# List running containers
container list

# Stop the container
container stop yolo

# Remove the container
container rm yolo

# Execute a shell in running container
container exec --tty --interactive yolo bash

# View resource usage
container stats yolo

# Test network restrictions (from inside container)
curl -I https://api.anthropic.com  # Should work
curl -I https://google.com          # Should fail (if firewall enabled)
```

## Shell Helpers

Add to your `.zshrc` or `.bashrc`:

```bash
source ~/Documents/Code_projects/yolo-sandbox/yolo.sh
```

Available commands:

| Command | Description |
|---------|-------------|
| `yolo [dir]` | Start Claude Code or enter if already running |
| `yolo-run [dir]` | Run Claude Code with project directory |
| `yolo-shell` | Enter running container with bash |
| `yolo-build [--no-firewall] [node] [python]` | Build image with custom versions |
| `yolo-stop` | Stop container |
| `yolo-rm` | Remove container |
| `yolo-status` | Show container status |

Examples:

```bash
# Build with defaults (Node 22, Python 3.12, firewall enabled)
yolo-build

# Build without firewall, Node 20, Python 3.11
yolo-build --no-firewall 20 3.11

# Run Claude Code in current directory
yolo

# Run Claude Code in specific project
yolo ~/projects/my-app

# Disable firewall at runtime
YOLO_FIREWALL=false yolo ~/projects/my-app
```

## Files

| File | Description |
|------|-------------|
| `Containerfile` | Container image definition |
| `setup-firewall.sh` | iptables rules for network restrictions |
| `entrypoint.sh` | Startup script (firewall setup + claude launch) |
| `yolo.sh` | Shell helper functions |

## Customization

### Adding more allowed domains

Edit `setup-firewall.sh` to allow additional domains:

```bash
# Allow PyPI
iptables -A OUTPUT -d pypi.org -j ACCEPT
iptables -A OUTPUT -d files.pythonhosted.org -j ACCEPT
```

### Using Vertex AI instead of Anthropic API

Uncomment in `setup-firewall.sh`:

```bash
iptables -A OUTPUT -d us-east5-aiplatform.googleapis.com -j ACCEPT
```

## License

MIT
