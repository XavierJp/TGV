<p align="center">
  <img src="logo.png" alt="tgv" width="400" />
</p>

# tgv — Terminal à Grande Vitesse

> TGV is brought to you by the Super Naive Code Factory (SNCF). This is a side project and not production ready.

Remote AI coding sessions on your own server. Spawn isolated OpenCode containers, attach and detach resiliently. Your code keeps running even when your WiFi doesn't.

---

## Requirements

**Local machine (macOS)**

- SSH (pre-installed)
- [mosh](https://mosh.org/) (optional, for resilient connections)
- [GitHub CLI](https://cli.github.com/) (for private repos)

**Remote server (Ubuntu/Debian)**

- [Docker](https://get.docker.com)
- mosh-server (`sudo apt install mosh`)
- git

**API**

- [OpenRouter](https://openrouter.ai) API key

---

## Installation

```bash
git clone https://github.com/XavierJp/TGV.git
cd TGV
./install.sh
```

This builds the binary, installs it to `~/.cargo/bin/tgv`, and links the xbar menu bar plugin if xbar is installed.

---

## Setup

```bash
# Public repo
tgv init --host user@<server-ip> --repo https://github.com/org/repo

# Private repo
tgv init --host user@<server-ip> --repo https://github.com/org/repo --private

# Custom branch
tgv init --host user@<server-ip> --repo https://github.com/org/repo --branch develop
```

You'll be prompted for your OpenRouter API key. This builds a Docker image with OpenCode, clones your repo, and installs dependencies.

Then launch:

```bash
tgv
```

---

## Usage

The TUI lets you:

- **New session** — pick a branch (or create one), spawn a container
- **Attach** — connect to a running session via mosh/SSH
- **Rename** — label sessions for easy identification
- **Kill** — stop and clean up a session

Inside each session, OpenCode runs with Qwen 3 Coder via OpenRouter. A Zellij split gives you a shell alongside the AI.

Detach with `Ctrl+Q`. Reattach anytime — sessions persist.

### xbar plugin

A menu bar plugin is included at `xbar/tgv.30s.sh`. Symlink it to see active sessions in your macOS menu bar:

```bash
ln -s $(pwd)/xbar/tgv.30s.sh ~/Library/Application\ Support/xbar/plugins/
```

---

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
```


---

## License

MIT
