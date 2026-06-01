<p align="center">
  <img src="logo.png" alt="tgv" width="400" />
</p>

# TGV — Terminal à Grande Vitesse

In the AI era, a reliable internet connection should be a given. In high-latency environments, such as high-speed rail, unstable internet can make coding sessions frustrating.

Enter TGV, a tool that spawns remote sessions on your workhorse server.

TGV spins up isolated YOLO containers that run Codex with OpenRouter. They run on the remote server which keeps a stable connection even when you don't.

---

## What's in the box

- **tgv** — a bubbletea TUI that lists sessions, shows per-session git status / PR state, creates sessions (title + prompt), and launches `ssh docker exec` attach / shell in a new tab of your current terminal.
- **tgv-init** — bash script that builds the docker image (with your repo baked in) and writes the config the TUI reads.
- **docker/Dockerfile** — image with `abduco`, `nvim`, `zsh + oh-my-zsh`, `gh`, `node`, `pnpm`, `uv`, `codex` all preinstalled.

## Installation

```bash
git clone https://github.com/XavierJp/TGV.git
cd TGV
./install.sh
```

Requires Go 1.22+ locally (`brew install go`). Installs:
- `tgv` to `~/.local/bin/tgv`
- `tgv-init` to `~/.local/bin/tgv-init`
- `Dockerfile` to `~/.local/share/tgv/Dockerfile`

## Setup

```bash
# Public repo
tgv-init --host user@<server-ip> --repo https://github.com/org/repo

# Private repo (requires `gh auth login` locally)
tgv-init --host user@<server-ip> --repo https://github.com/org/repo --private

# Custom branch
tgv-init --host user@<server-ip> --repo https://github.com/org/repo --branch develop
```

`tgv-init` will:
1. Check local + remote dependencies
2. Prompt for your OpenRouter API key
3. Clone the repo on the server, build the docker image with deps installed
4. Create the docker network
5. Save `~/.tgv/config.toml`

Then run `tgv`.

## Using the TUI

```
TGV  user@host                           ●  3 sessions · 2s ago

  ●  add dark mode (tgv/add-dark-ab12)           ↑2 ↓0  mod:3  +42 -8  PR #12 open
  ●  fix login flow (tgv/fix-login-34c)          clean
  ⟳  swift-river-3a8                             Starting container

n new   a attach   s shell   x kill   ↑↓ move   q quit
```

| Key | Action |
|---|---|
| `n` | Create a new session (title + prompt) |
| `a` | Attach codex in a new terminal tab (`abduco -A`) |
| `s` | Open a plain shell in the container in a new terminal tab |
| `x` | Kill and remove the selected session |
| `↑`/`↓` or `k`/`j` | Move selection |
| `q` or `Ctrl-C` | Quit |

Attach / shell commands are launched in a **new tab of your current terminal** (Apple Terminal, iTerm2, WezTerm supported natively; Ghostty and others fall back to Terminal.app). Codex sessions survive the SSH disconnect via `abduco`, so you can close the tab and reattach any time.

The TUI polls in the background — session list every 10s, git status every 5s, PR info every 60s. The UI never blocks on SSH.

## Uninstall

```bash
./uninstall.sh
```

## Requirements

**Local machine (macOS)**

- Go 1.22+ (`brew install go`)
- SSH
- [GitHub CLI](https://cli.github.com/) (for private repos)

**Remote server (Ubuntu/Debian)**

- [Docker](https://get.docker.com)
- git
- An SSH key you can authenticate with from your Mac

**API**

- [OpenRouter](https://openrouter.ai) API key

## Configuration

Stored at `~/.tgv/config.toml`:

```toml
[server]
host = "10.0.0.1"
user = "deploy"

[docker]
image = "tgv-session:latest"
network = "tgv-net"

[repo]
url = "https://github.com/org/repo"
default_branch = "main"

[git]
name = "Your Name"
email = "you@example.com"

[ui]
# Where attach / shell open. Omit or "auto" to detect from $TERM_PROGRAM.
# Recognized: "iterm", "terminal", "wezterm", "ghostty".
terminal = "iterm"
```

## Architecture

```
┌────────────────────────────────────┐
│ tgv (bubbletea TUI)                │
│  Store ── polls via SSH every N s  │
│    │                               │
│    ▼                               │
│  List │ New session form           │
└────────────────────────────────────┘
           │   attach / shell:
           │   osascript → new tab → ssh -t host …
           ▼
┌────────────────────────────────────┐
│ Remote server                      │
│  ┌───────────┐   ┌───────────┐     │
│  │container1 │   │container2 │     │
│  │abduco+cx  │   │abduco+cx  │     │
│  └───────────┘   └───────────┘     │
└────────────────────────────────────┘
```

## License

MIT
