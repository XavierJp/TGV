//! tgv — Terminal à Grande Vitesse
//!
//! Remote Claude Code session manager with embedded terminal.
//! Two commands: `tgv init` (server setup) and `tgv` (TUI).

mod app;
mod banner;
mod config;
mod server;
mod session;
mod terminal_pane;
mod ui;

use clap::{Parser, Subcommand};
use config::Config;

/// Terminal à Grande Vitesse — remote Claude Code session manager
#[derive(Parser)]
#[command(name = "tgv", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Bootstrap a remote server for tgv sessions
    Init {
        /// Server address (e.g., user@10.0.0.1)
        #[arg(long)]
        host: String,

        /// Git repository URL
        #[arg(long)]
        repo: String,

        /// Default branch
        #[arg(long, default_value = "main")]
        branch: String,

        /// Repo is private — use gh auth token for cloning
        #[arg(long, default_value_t = false)]
        private: bool,

        /// Eternal Terminal port
        #[arg(long, default_value_t = 2022)]
        et_port: u16,
    },
}

fn main() {
    let cli = Cli::parse();

    match cli.command {
        Some(Commands::Init {
            host,
            repo,
            branch,
            private,
            et_port,
        }) => {
            banner::print_banner();
            if let Err(e) = init_server(&host, &repo, &branch, private, et_port) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
        None => {
            let config = match Config::load() {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("Failed to load config: {e}");
                    eprintln!("Run `tgv init --host user@ip --repo <url>` first.");
                    std::process::exit(1);
                }
            };
            if config.server.host.is_empty() {
                eprintln!("No server configured. Run: tgv init --host user@ip --repo <url>");
                std::process::exit(1);
            }
            if let Err(e) = app::run(config) {
                eprintln!("Error: {e}");
                std::process::exit(1);
            }
        }
    }
}

/// Run `tgv init` to bootstrap a remote server.
fn init_server(
    host: &str,
    repo: &str,
    branch: &str,
    private: bool,
    et_port: u16,
) -> Result<(), Box<dyn std::error::Error>> {
    let (user, hostname) = if let Some(pos) = host.find('@') {
        (&host[..pos], &host[pos + 1..])
    } else {
        ("root", host)
    };

    let mut config = Config::default();
    config.server.host = hostname.to_string();
    config.server.user = user.to_string();
    config.server.et_port = et_port;
    config.repo.url = repo.to_string();
    config.repo.default_branch = branch.to_string();

    // Validate inputs before using in shell commands
    if !repo.starts_with("https://") && !repo.starts_with("git@") {
        return Err("Repo URL must start with https:// or git@".into());
    }
    session::validate_branch(branch).map_err(|e| -> Box<dyn std::error::Error> { e.into() })?;

    // Auto-detect git identity from local machine
    if let Ok(out) = std::process::Command::new("git").args(["config", "user.name"]).output() {
        if out.status.success() {
            config.git.name = String::from_utf8_lossy(&out.stdout).trim().to_string();
        }
    }
    if let Ok(out) = std::process::Command::new("git").args(["config", "user.email"]).output() {
        if out.status.success() {
            config.git.email = String::from_utf8_lossy(&out.stdout).trim().to_string();
        }
    }

    // Check local deps
    println!("Checking local dependencies...");
    for (bin, name, hint) in [
        ("ssh", "OpenSSH", "brew install openssh"),
        ("et", "Eternal Terminal", "brew install MisterTea/et/et"),
        ("scp", "scp", "brew install openssh"),
    ] {
        if which::which(bin).is_err() {
            eprintln!("  ✗ {name} — install with: {hint}");
            return Err(format!("Missing: {name}").into());
        }
    }
    println!("  Local dependencies OK");

    // SSH connectivity
    println!("Connecting to {}...", config.ssh_target());
    let result = server::ssh_run(&config, "echo ok")?;
    if !result.success {
        return Err(format!("Cannot connect: {}", result.stderr).into());
    }
    println!("  SSH OK");

    // Remote deps
    println!("Checking remote dependencies...");
    for (cmd, name, hint) in [
        ("docker --version", "Docker", "curl -fsSL https://get.docker.com | sh"),
        ("tmux -V", "tmux", "sudo apt install -y tmux"),
        ("et --version", "ET", "sudo add-apt-repository ppa:jgmath2000/et && sudo apt install -y et"),
        ("git --version", "git", "sudo apt install -y git"),
    ] {
        let r = server::ssh_run(&config, cmd)?;
        if r.success {
            println!("  ✓ {name}: {}", r.stdout.lines().next().unwrap_or(""));
        } else {
            eprintln!("  ✗ {name} — install: {hint}");
            return Err(format!("Missing on server: {name}").into());
        }
    }

    // Claude Code binary path (native installer puts it in ~/.claude/local/bin)
    let claude_bin = "PATH=$PATH:$HOME/.claude/local/bin:$HOME/.local/bin:/usr/local/bin";

    // Install Claude Code on server if missing
    let claude_check = server::ssh_run(&config, &format!("{claude_bin} claude --version 2>/dev/null"))?;
    if claude_check.success {
        println!("  ✓ Claude Code: {}", claude_check.stdout.lines().next().unwrap_or(""));
    } else {
        println!("  Installing Claude Code on server...");
        let install = server::ssh_run(&config, "bash -c 'curl -fsSL https://claude.ai/install.sh | bash'")?;
        if !install.success {
            return Err(format!("Failed to install Claude Code: {}", install.stderr).into());
        }
        // Add to PATH in bashrc
        server::ssh_run(&config,
            "grep -q '.claude/local/bin' ~/.bashrc 2>/dev/null || echo 'export PATH=$PATH:$HOME/.claude/local/bin' >> ~/.bashrc"
        )?;
        println!("  ✓ Claude Code installed");
    }

    // Setup Claude Code auth on the server
    println!("Setting up Claude Code auth on server...");
    let check = server::ssh_run(&config, &format!("{claude_bin} && echo $CLAUDE_CODE_OAUTH_TOKEN"))?;
    if check.stdout.trim().is_empty() {
        println!("  No token found on server. Running claude setup-token remotely...");
        println!("  ⚠ This will print a URL — open it in your browser to authenticate.");
        println!();
        let status = std::process::Command::new("ssh")
            .args([
                "-t",
                &config.ssh_target(),
                &format!("{claude_bin} && claude setup-token"),
            ])
            .status()?;
        if !status.success() {
            eprintln!("  ⚠ claude setup-token failed — sessions will require manual login");
        } else {
            // Save token to a dedicated secrets file (not bashrc)
            server::ssh_run(&config, &format!(
                "{claude_bin} && mkdir -p ~/.config/tgv && echo \"$CLAUDE_CODE_OAUTH_TOKEN\" > ~/.config/tgv/oauth_token && chmod 600 ~/.config/tgv/oauth_token"
            ))?;
            // Source from secrets file in bashrc (only the file read, not the token itself)
            server::ssh_run(&config,
                "grep -q 'tgv/oauth_token' ~/.bashrc 2>/dev/null || echo 'export CLAUDE_CODE_OAUTH_TOKEN=$(cat ~/.config/tgv/oauth_token 2>/dev/null)' >> ~/.bashrc"
            )?;
            println!("  Token configured on server");
        }
    } else {
        println!("  Token already configured on server");
    }

    // Build Docker image
    println!("Building Docker image with {repo} ({branch})...");
    let docker_dir = std::env::current_dir()?.join("docker");
    server::ssh_run(&config, "mkdir -p /tmp/tgv-build")?;
    server::scp_to(&config, &docker_dir.join("Dockerfile").to_string_lossy(), "/tmp/tgv-build/Dockerfile")?;

    // Clone repo on server host (not in Docker — no token leak)
    if private {
        let gh_out = std::process::Command::new("gh").args(["auth", "token"]).output()?;
        if !gh_out.status.success() {
            return Err("--private requires `gh auth login` first".into());
        }
        let token = String::from_utf8_lossy(&gh_out.stdout).trim().to_string();
        println!("  GitHub token found");
        // Write token to file (not command line), askpass script reads it
        server::ssh_run(&config, "printf '#!/bin/sh\ncat /tmp/tgv-build/.git-token' > /tmp/tgv-build/.git-askpass && chmod 700 /tmp/tgv-build/.git-askpass")?;
        server::scp_string_to(&config, &token, "/tmp/tgv-build/.git-token", "600")?;
        server::ssh_run(&config, &format!(
            "GIT_ASKPASS=/tmp/tgv-build/.git-askpass git clone --branch {branch} https://x-access-token@github.com/{} /tmp/tgv-build/repo",
            repo.trim_start_matches("https://github.com/")
        ))?;
        server::ssh_run(&config, "rm -f /tmp/tgv-build/.git-askpass /tmp/tgv-build/.git-token")?;
        server::ssh_run(&config, &format!("cd /tmp/tgv-build/repo && git remote set-url origin {repo}"))?;
    } else {
        let r = server::ssh_run(&config, &format!("git clone --branch {branch} {repo} /tmp/tgv-build/repo"))?;
        if !r.success {
            return Err(format!("git clone failed: {}", r.stderr).into());
        }
    }

    // Append shell tools + COPY + deps install to Dockerfile
    let extra = r#"# Shell tools: zsh, neovim, oh-my-zsh, utilities
RUN apt-get update && \
    apt-get install -y zsh neovim fzf bat fd-find ripgrep curl locales tmux && \
    locale-gen en_US.UTF-8 && \
    rm -rf /var/lib/apt/lists/*

# Oh My Zsh (unattended)
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended && \
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-/root/.oh-my-zsh/custom}/plugins/zsh-autosuggestions 2>/dev/null && \
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-/root/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting 2>/dev/null && \
    chsh -s /bin/zsh root

# Custom arrow theme + zshrc
RUN cat > /root/.oh-my-zsh/custom/themes/arrow-custom.zsh-theme << 'THEMEEOF'
NCOLOR="white"
ICON_GIT=$'\uf418'
ICON_TIMER=$'\uf520'
ICON_UP=$'\uf062'
ICON_DOWN=$'\uf063'
ICON_STASH=$'\uf48e'

_CMD_START_TIME=""
function preexec() { _CMD_START_TIME=$EPOCHREALTIME; }
function precmd() {
  if [[ -n "$_CMD_START_TIME" ]]; then
    local end=$EPOCHREALTIME
    _CMD_DURATION=$(printf "%.0f" $(( end - _CMD_START_TIME )))
    _CMD_START_TIME=""
  else _CMD_DURATION=0; fi
}
function cmd_duration() {
  if [[ $_CMD_DURATION -gt 3 ]]; then
    local mins=$(( _CMD_DURATION / 60 )) secs=$(( _CMD_DURATION % 60 ))
    [[ $mins -gt 0 ]] && echo " %F{yellow}${ICON_TIMER} ${mins}m${secs}s%f" || echo " %F{yellow}${ICON_TIMER} ${secs}s%f"
  fi
}
function git_info() {
  local ref=$(git symbolic-ref HEAD 2>/dev/null | cut -d'/' -f3-)
  if [[ -n "$ref" ]]; then
    local info=""
    [[ -n $(git status --porcelain 2>/dev/null) ]] && info+="%F{208}*%f"
    local ab=$(git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null)
    if [[ -n "$ab" ]]; then
      local ahead=$(echo $ab | awk '{print $1}') behind=$(echo $ab | awk '{print $2}')
      [[ $ahead -gt 0 ]] && info+=" %F{green}${ICON_UP}${ahead}%f"
      [[ $behind -gt 0 ]] && info+=" %F{red}${ICON_DOWN}${behind}%f"
    fi
    local stash=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
    [[ $stash -gt 0 ]] && info+=" %F{cyan}${ICON_STASH}${stash}%f"
    echo " %F{$NCOLOR}${ICON_GIT} ${ref}%f${info}"
  fi
}
local root_indicator=""
[ $UID -eq 0 ] && root_indicator="%F{196}[root] %f"
PROMPT='${root_indicator}%F{$NCOLOR}%c ➤ %f'
RPROMPT='$(cmd_duration)$(git_info)'
export LSCOLORS="exfxcxdxbxbxbxbxbxbxbx"
export LS_COLORS="di=34;40:ln=35;40:so=32;40:pi=33;40:ex=31;40:bd=31;40:cd=31;40:su=31;40:sg=31;40:tw=31;40:ow=31;40:"
THEMEEOF

RUN cat > /root/.zshrc << 'ZSHEOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="arrow-custom"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
source $ZSH/oh-my-zsh.sh

export EDITOR='nvim'
export LANG=en_US.UTF-8

alias vim='nvim'
alias ll='ls -la --color=auto'
command -v batcat &>/dev/null && alias cat='batcat --paging=never'
command -v fdfind &>/dev/null && alias fd='fdfind'
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
ZSHEOF

# Minimal nvim config (no plugins, no network)
RUN mkdir -p /root/.config/nvim && cat > /root/.config/nvim/init.lua << 'NVIMEOF'
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.tabstop = 2
vim.opt.shiftwidth = 2
vim.opt.expandtab = true
vim.opt.smartindent = true
vim.opt.termguicolors = true
vim.opt.signcolumn = "yes"
vim.opt.wrap = false
vim.opt.scrolloff = 8
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.clipboard = "unnamedplus"
vim.opt.mouse = "a"
vim.opt.undofile = true
vim.g.mapleader = " "
vim.keymap.set("n", "<leader>w", ":w<CR>")
vim.keymap.set("n", "<leader>q", ":q<CR>")
NVIMEOF

COPY repo /workspace/repo
WORKDIR /workspace/repo
RUN if [ -f pnpm-lock.yaml ]; then pnpm install && (grep -q '"prepare"' package.json 2>/dev/null && pnpm prepare || true); elif [ -f package-lock.json ]; then npm install; elif [ -f yarn.lock ]; then npm install -g yarn && yarn install; fi
"#;
    server::ssh_run(&config, &format!("cat >> /tmp/tgv-build/Dockerfile << 'EOF'\n{extra}EOF"))?;

    let r = server::ssh_run(&config, &format!("docker build -t {} /tmp/tgv-build", config.docker.image))?;
    if !r.success {
        return Err(format!("Docker build failed:\n{}", r.stderr).into());
    }
    server::ssh_run(&config, "rm -rf /tmp/tgv-build")?;
    println!("  Docker image built");

    // Docker network
    let net = server::ssh_run(&config, &format!("docker network inspect {}", config.docker.network))?;
    if !net.success {
        server::ssh_run(&config, &format!("docker network create {}", config.docker.network))?;
    }
    println!("  Network ready");

    config.save()?;
    println!("\nConfig saved. Run `tgv` to open the session manager.");
    Ok(())
}
