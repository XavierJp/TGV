"""Docker container session management on remote server."""

from __future__ import annotations

import hashlib
import time
from dataclasses import dataclass

from tgv.config import Config
from tgv.server import ssh_run


@dataclass
class Session:
    name: str
    repo: str
    branch: str
    status: str  # "running" or "exited"
    created: str  # ISO timestamp or relative


def _short_id(repo: str) -> str:
    """Generate a short hash suffix for session names."""
    return hashlib.sha1(f"{repo}{time.time()}".encode()).hexdigest()[:4]


def session_name(repo_url: str) -> str:
    """Generate a session name from repo URL."""
    repo = repo_url.rstrip("/").split("/")[-1].replace(".git", "")
    return f"{repo}-{_short_id(repo_url)}"


def spawn(
    config: Config,
    branch: str = "",
    prompt: str = "",
) -> str:
    """Spawn a new Claude Code session in a Docker container.

    The repo and deps are already baked into the Docker image.
    Just start Claude Code in a tmux session.
    """
    branch = branch or config.repo.default_branch
    name = session_name(config.repo.url)

    claude_cmd = "claude --dangerously-skip-permissions"
    if prompt:
        safe_prompt = prompt.replace("'", "'\\''")
        claude_cmd += f" -p '{safe_prompt}'"

    # Repo is at /workspace/repo in the image; just pull latest + start Claude
    entrypoint = (
        f"cd /workspace/repo && "
        f"git fetch origin && git checkout {branch} && git pull origin {branch} 2>&1; "
        f"tmux new-session -d -s claude '{claude_cmd}' && "
        f"sleep infinity"
    )

    docker_cmd = (
        f"docker run -d "
        f"--name {name} "
        f"--network {config.docker.network} "
        f"--label tgv.repo={config.repo.url} "
        f"--label tgv.branch={branch} "
        f"-e CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN "
        f"{config.docker.image} "
        f"bash -c '{entrypoint}'"
    )

    result = ssh_run(config, docker_cmd, check=True)
    return name


def list_sessions(config: Config) -> list[Session]:
    """List all tgv sessions on the remote server."""
    cmd = (
        'docker ps -a --filter "label=tgv.repo" '
        '--format "{{.Names}}\\t{{.Label \\"tgv.repo\\"}}\\t{{.Label \\"tgv.branch\\"}}\\t{{.Status}}\\t{{.CreatedAt}}"'
    )
    result = ssh_run(config, cmd)
    if not result.stdout:
        return []

    sessions = []
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 4:
            status = "running" if "Up" in parts[3] else "exited"
            # Extract repo name from URL
            repo = parts[1].rstrip("/").split("/")[-1].replace(".git", "")
            if "/" in parts[1]:
                org = parts[1].rstrip("/").split("/")[-2]
                repo = f"{org}/{repo}"
            sessions.append(Session(
                name=parts[0],
                repo=repo,
                branch=parts[2],
                status=status,
                created=parts[3],
            ))
    return sessions


def attach_command(name: str) -> str:
    """Return the tmux attach command to run inside docker exec."""
    return f"docker exec -it {name} tmux attach-session -t claude"


def stop(config: Config, name: str) -> None:
    """Stop and remove a session container."""
    ssh_run(config, f"docker rm -f {name}")


def logs(config: Config, name: str) -> str:
    """Get logs from a session container."""
    result = ssh_run(config, f"docker logs --tail 50 {name}")
    return result.stdout or result.stderr
