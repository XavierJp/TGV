"""CLI entry points: `tgv` (TUI) and `tgv init`."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import typer

from tgv.config import Config, CONFIG_FILE


def _get_oauth_token() -> str:
    """Get Claude Code OAuth token from env or stored config."""
    # Check env first
    token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    if token:
        return token
    # Check stored token from previous init
    from tgv.config import CONFIG_DIR
    token_file = CONFIG_DIR / "oauth_token"
    if token_file.exists():
        return token_file.read_text().strip()
    return ""


def _get_claude_account_info() -> dict | None:
    """Read OAuth account info from local ~/.claude.json."""
    import json
    claude_json = Path.home() / ".claude.json"
    if not claude_json.exists():
        return None
    try:
        data = json.loads(claude_json.read_text())
        account = data.get("oauthAccount")
        if account:
            return {
                "hasCompletedOnboarding": True,
                "lastOnboardingVersion": data.get("lastOnboardingVersion", "2.1.29"),
                "oauthAccount": account,
            }
    except (json.JSONDecodeError, KeyError):
        pass
    return None


def _setup_oauth_token() -> str:
    """Run `claude setup-token` interactively to generate an OAuth token."""
    typer.echo("No OAuth token found. Running `claude setup-token`...")
    typer.echo("This will open your browser to authenticate with your Max subscription.\n")

    # Run interactively (needs terminal for browser redirect)
    result = subprocess.run(["claude", "setup-token"])

    if result.returncode != 0:
        typer.echo("Token generation failed or was cancelled.")
        return ""

    # After setup-token, the token should be in env or we prompt
    token = os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "")
    if token:
        return token

    typer.echo("\nPaste your OAuth token below (starts with sk-ant-oat01-):")
    token = input("> ").strip()
    if token.startswith("sk-ant-oat"):
        return token

    return ""

app = typer.Typer(
    name="tgv",
    help="Terminal à Grande Vitesse — remote Claude Code session manager",
    invoke_without_command=True,
    no_args_is_help=False,
)


@app.callback()
def main(ctx: typer.Context) -> None:
    """Launch the TUI if no subcommand is given."""
    if ctx.invoked_subcommand is not None:
        return

    config = Config.load()
    if not config.server.host:
        typer.echo("No server configured. Run: tgv init --host user@ip")
        raise typer.Exit(1)

    from tgv.tui import TGVApp
    tui = TGVApp(config)
    tui.run()


@app.command()
def init(
    host: str = typer.Option(..., help="Server address"),
    repo: str = typer.Option(..., help="Git repository URL (e.g., https://github.com/user/repo)"),
    branch: str = typer.Option("main", help="Default branch"),
    private: bool = typer.Option(False, help="Repo is private — use gh auth token for cloning"),
    et_port: int = typer.Option(2022, help="Eternal Terminal port"),
) -> None:
    """Bootstrap a remote server for tgv sessions."""
    from tgv.banner import print_banner
    print_banner()

    # Parse user@host
    if "@" in host:
        user, hostname = host.split("@", 1)
    else:
        user = "root"
        hostname = host

    config = Config()
    config.server.host = hostname
    config.server.user = user
    config.server.et_port = et_port
    config.repo.url = repo
    config.repo.default_branch = branch

    from tgv.server import ssh_run

    # --- Local dependency checks ---
    typer.echo("Checking local dependencies...")
    local_missing = []
    for binary, name, install_hint in [
        ("ssh", "OpenSSH client", "brew install openssh"),
        ("et", "Eternal Terminal", "brew install MisterTea/et/et"),
        ("scp", "scp", "brew install openssh"),
        ("claude", "Claude Code", "npm install -g @anthropic-ai/claude-code"),
    ]:
        if not shutil.which(binary):
            local_missing.append((name, install_hint))

    if local_missing:
        typer.echo("Missing local dependencies:")
        for name, hint in local_missing:
            typer.echo(f"  ✗ {name} — install with: {hint}")
        raise typer.Exit(1)
    typer.echo("Local dependencies OK (ssh, et, scp, claude)")

    # --- OAuth token (Max subscription) ---
    oauth_token = _get_oauth_token()
    if not oauth_token:
        oauth_token = _setup_oauth_token()
    if not oauth_token:
        typer.echo("\n✗ OAuth token not found.")
        typer.echo("  Run `claude setup-token` manually, then set:")
        typer.echo("  export CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...")
        raise typer.Exit(1)
    typer.echo(f"OAuth token found ({oauth_token[:16]}...)")

    # Read local Claude account info for server setup
    account_info = _get_claude_account_info()
    if not account_info:
        typer.echo("⚠ Could not read ~/.claude.json — Claude onboarding may need to be done manually on the server")
    else:
        typer.echo(f"Claude account: {account_info['oauthAccount'].get('emailAddress', 'unknown')}")

    # --- SSH connectivity ---
    typer.echo(f"Connecting to {config.ssh_target}...")
    result = ssh_run(config, "echo ok")
    if not result.ok:
        typer.echo(f"Cannot connect: {result.stderr}")
        raise typer.Exit(1)
    typer.echo("SSH connection OK")

    # --- Remote dependency checks ---
    typer.echo("Checking remote dependencies...")
    remote_missing = []
    for cmd, name in [
        ("docker --version", "Docker"),
        ("tmux -V", "tmux"),
        ("et --version", "Eternal Terminal"),
        ("git --version", "git"),
    ]:
        result = ssh_run(config, cmd)
        if result.ok:
            version = result.stdout.splitlines()[0] if result.stdout else ""
            typer.echo(f"  ✓ {name}: {version}")
        else:
            remote_missing.append(name)
            typer.echo(f"  ✗ {name}: not found")

    if remote_missing:
        typer.echo(f"\nMissing on server: {', '.join(remote_missing)}")
        typer.echo("Install them on the server before continuing:")
        install_hints = {
            "Docker": "curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker $USER",
            "tmux": "sudo apt install -y tmux",
            "Eternal Terminal": "sudo add-apt-repository ppa:jgmath2000/et && sudo apt install -y et",
            "git": "sudo apt install -y git",
        }
        for name in remote_missing:
            if name in install_hints:
                typer.echo(f"  {name}: {install_hints[name]}")
        raise typer.Exit(1)

    # Deploy CLAUDE_CODE_OAUTH_TOKEN to a secure file on server
    typer.echo("Deploying OAuth credentials to server...")
    ssh_run(config, "mkdir -p ~/.config/tgv", check=True)
    ssh_run(
        config,
        f"echo '{oauth_token}' > ~/.config/tgv/oauth_token && chmod 600 ~/.config/tgv/oauth_token",
        check=True,
    )
    # Source it from .bashrc if not already
    source_line = 'export CLAUDE_CODE_OAUTH_TOKEN=$(cat ~/.config/tgv/oauth_token 2>/dev/null)'
    source_check = ssh_run(config, 'grep -q "config/tgv/oauth_token" ~/.bashrc && echo exists')
    if "exists" not in (source_check.stdout or ""):
        ssh_run(
            config,
            f"echo '{source_line}' >> ~/.bashrc",
            check=True,
        )
    typer.echo("  OAuth token deployed to ~/.config/tgv/oauth_token")

    # Deploy ~/.claude.json for onboarding bypass
    if account_info:
        import json
        claude_json = json.dumps(account_info)
        ssh_run(
            config,
            f"echo '{claude_json}' > ~/.claude.json && chmod 600 ~/.claude.json",
            check=True,
        )
        typer.echo("  Claude account config deployed to ~/.claude.json")

    typer.echo("Remote dependencies OK")

    # Build the tgv-session Docker image with repo baked in
    typer.echo(f"Building Docker image with {repo} ({branch})...")
    from tgv.server import scp_to
    docker_dir = Path(__file__).parent.parent.parent / "docker"

    ssh_run(config, "mkdir -p /tmp/tgv-build", check=True)
    scp_to(config, str(docker_dir / "Dockerfile"), "/tmp/tgv-build/Dockerfile")

    # Clone repo on the server (not inside Docker build) — no token in image layers
    typer.echo("  Cloning repo on server...")
    if private:
        gh_result = subprocess.run(
            ["gh", "auth", "token"], capture_output=True, text=True
        )
        if gh_result.returncode != 0 or not gh_result.stdout.strip():
            typer.echo("  ✗ --private requires gh CLI auth. Run: gh auth login")
            raise typer.Exit(1)
        gh_token = gh_result.stdout.strip()
        typer.echo("  GitHub token found (via gh auth)")
        clone_url = repo.replace("https://github.com", f"https://x-access-token:{gh_token}@github.com")
        ssh_run(config, f"git clone --branch {branch} {clone_url} /tmp/tgv-build/repo", check=True)
        # Strip token from cloned remote
        ssh_run(config, f"cd /tmp/tgv-build/repo && git remote set-url origin {repo}", check=True)
    else:
        ssh_run(config, f"git clone --branch {branch} {repo} /tmp/tgv-build/repo", check=True)

    # Append COPY + deps install to Dockerfile — no secrets leak into image layers
    repo_steps = (
        "COPY repo /workspace/repo\n"
        "WORKDIR /workspace/repo\n"
        "RUN if [ -f pnpm-lock.yaml ]; then pnpm install && "
        "(grep -q '\"prepare\"' package.json 2>/dev/null && pnpm prepare || true); "
        "elif [ -f package-lock.json ]; then npm install; "
        "elif [ -f yarn.lock ]; then npm install -g yarn && yarn install; "
        "fi\n"
    )
    ssh_run(
        config,
        f"cat >> /tmp/tgv-build/Dockerfile << 'REPO_EOF'\n{repo_steps}REPO_EOF",
        check=True,
    )

    ssh_run(config, f"docker build -t {config.docker.image} /tmp/tgv-build", check=True)
    ssh_run(config, "rm -rf /tmp/tgv-build")

    # Create Docker network with allowlist
    typer.echo("Setting up Docker network...")
    net_check = ssh_run(config, f"docker network inspect {config.docker.network}")
    if not net_check.ok:
        ssh_run(config, f"docker network create {config.docker.network}", check=True)

    # Note: network allowlist (iptables) requires sudo — apply via Ansible:
    #   ansible-playbook playbooks/claude-sessions.yml --ask-become-pass
    typer.echo("Note: network allowlist requires sudo. Apply via Ansible playbook.")

    # Save config + OAuth token
    config.oauth_token = oauth_token
    config.save()
    typer.echo(f"\nConfig saved to {CONFIG_FILE}")
    typer.echo("Server is ready. Run `tgv` to open the session manager.")
