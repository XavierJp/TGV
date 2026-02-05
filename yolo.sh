#!/bin/bash
# Yolo Sandbox helpers
# Source this file in your .zshrc or .bashrc:
#   source ~/Documents/Code_projects/yolo-sandbox/yolo.sh

YOLO_IMAGE="yolo-sandbox"
YOLO_CONTAINER="yolo"

# Start container system if not running
yolo-system-start() {
    if ! container system info &>/dev/null; then
        echo "Starting container system..."
        container system start
    else
        echo "Container system already running"
    fi
}

# Build the yolo-sandbox image
# Usage: yolo-build [--no-firewall] [node_version] [python_version]
yolo-build() {
    local include_firewall="true"
    local node_version="22"
    local python_version="3.12"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-firewall)
                include_firewall="false"
                shift
                ;;
            *)
                if [[ -z "${node_version_set:-}" ]]; then
                    node_version="$1"
                    node_version_set=1
                else
                    python_version="$1"
                fi
                shift
                ;;
        esac
    done

    yolo-system-start

    echo "Building $YOLO_IMAGE..."
    echo "  Node: $node_version"
    echo "  Python: $python_version"
    echo "  Firewall: $include_firewall"

    container build \
        --tag "$YOLO_IMAGE" \
        --build-arg NODE_VERSION="$node_version" \
        --build-arg PYTHON_VERSION="$python_version" \
        --build-arg INCLUDE_FIREWALL="$include_firewall" \
        ~/Documents/Code_projects/yolo-sandbox
}

# Run Claude Code in sandbox with a project directory
yolo-run() {
    local project_dir="${1:-$(pwd)}"
    local enable_firewall="${YOLO_FIREWALL:-true}"

    if [[ -z "$ANTHROPIC_API_KEY" ]]; then
        echo "Error: ANTHROPIC_API_KEY not set"
        return 1
    fi

    yolo-system-start

    # Check if container already exists
    if container list --all 2>/dev/null | grep -q "$YOLO_CONTAINER"; then
        echo "Container '$YOLO_CONTAINER' already exists. Removing..."
        container rm -f "$YOLO_CONTAINER" 2>/dev/null
    fi

    echo "Starting Claude Code in sandbox..."
    echo "  Project: $project_dir"
    echo "  Firewall: $enable_firewall"

    container run \
        --name "$YOLO_CONTAINER" \
        --tty \
        --interactive \
        --volume "$project_dir:/workspace" \
        --env ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
        --env ENABLE_FIREWALL="$enable_firewall" \
        "$YOLO_IMAGE"
}

# Enter running container with bash
yolo-shell() {
    if ! container list 2>/dev/null | grep -q "$YOLO_CONTAINER"; then
        echo "Error: Container '$YOLO_CONTAINER' is not running"
        echo "Start it first with: yolo-run /path/to/project"
        return 1
    fi

    container exec --tty --interactive "$YOLO_CONTAINER" bash
}

# Stop the container
yolo-stop() {
    container stop "$YOLO_CONTAINER" 2>/dev/null && echo "Stopped $YOLO_CONTAINER"
}

# Remove the container
yolo-rm() {
    container rm -f "$YOLO_CONTAINER" 2>/dev/null && echo "Removed $YOLO_CONTAINER"
}

# Show container status
yolo-status() {
    echo "=== Container System ==="
    container system info 2>/dev/null || echo "Not running"
    echo ""
    echo "=== Yolo Container ==="
    container list --all 2>/dev/null | grep -E "(NAME|$YOLO_CONTAINER)" || echo "No container found"
}

# Main entry point - smart command that does what you need
yolo() {
    local project_dir="${1:-$(pwd)}"

    # Check if container is already running
    if container list 2>/dev/null | grep -q "$YOLO_CONTAINER"; then
        echo "Entering running container..."
        yolo-shell
    else
        # Start fresh
        yolo-run "$project_dir"
    fi
}

echo "Yolo Sandbox loaded. Commands:"
echo "  yolo [dir]        - Start Claude Code (or enter if running)"
echo "  yolo-run [dir]    - Run Claude Code with project dir"
echo "  yolo-shell        - Enter running container with bash"
echo "  yolo-build [node] [python] - Build image with versions"
echo "  yolo-stop         - Stop container"
echo "  yolo-status       - Show status"
