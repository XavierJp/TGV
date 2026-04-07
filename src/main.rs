//! tgv — Terminal à Grande Vitesse
//!
//! Remote OpenCode session manager.
//! `tgv init` bootstraps a server, `tgv` lists/attaches/creates sessions.

mod banner;
mod config;
mod server;
mod session;

use clap::{Parser, Subcommand};
use config::Config;
use console::{style, Style};
use dialoguer::{theme::ColorfulTheme, FuzzySelect};
use session::Session;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

const BRAILLE_FRAMES: &[&str] = &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

/// A spinner that can update its message while running.
struct Spinner {
    msg: Arc<std::sync::Mutex<String>>,
    done: Arc<AtomicBool>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl Spinner {
    fn new(initial_msg: &str) -> Self {
        let msg = Arc::new(std::sync::Mutex::new(initial_msg.to_string()));
        let done = Arc::new(AtomicBool::new(false));
        let msg2 = msg.clone();
        let done2 = done.clone();

        let handle = std::thread::spawn(move || {
            let mut i = 0;
            while !done2.load(Ordering::Relaxed) {
                let frame = BRAILLE_FRAMES[i % BRAILLE_FRAMES.len()];
                let text = msg2.lock().unwrap().clone();
                eprint!("\r\x1b[2K{} {}", style(frame).cyan(), style(&text).dim());
                let _ = std::io::stderr().flush();
                std::thread::sleep(std::time::Duration::from_millis(80));
                i += 1;
            }
            eprint!("\r\x1b[2K");
            let _ = std::io::stderr().flush();
        });

        Self {
            msg,
            done,
            handle: Some(handle),
        }
    }

    fn set_message(&self, msg: &str) {
        *self.msg.lock().unwrap() = msg.to_string();
    }
}

impl Drop for Spinner {
    fn drop(&mut self) {
        self.done.store(true, Ordering::Relaxed);
        if let Some(h) = self.handle.take() {
            let _ = h.join();
        }
    }
}

/// Run a closure while showing a braille spinner with a message.
fn with_spinner<T, F: FnOnce() -> T>(msg: &str, f: F) -> T {
    let _spinner = Spinner::new(msg);
    f()
}

/// Terminal à Grande Vitesse — remote OpenCode session manager
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
        }) => {
            if let Err(e) = init_server(&host, &repo, &branch, private) {
                eprintln!("{} {e}", style("Error:").red().bold());
                std::process::exit(1);
            }
        }
        None => {
            let config = load_config();
            if let Err(e) = interactive(&config) {
                eprintln!("{} {e}", style("Error:").red().bold());
                std::process::exit(1);
            }
        }
    }
}

fn load_config() -> Config {
    let config = match Config::load() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{} {e}", style("Error:").red().bold());
            eprintln!("Run `tgv init --host user@ip --repo <url>` first.");
            std::process::exit(1);
        }
    };
    if config.server.host.is_empty() {
        eprintln!("No server configured. Run: tgv init --host user@ip --repo <url>");
        std::process::exit(1);
    }
    config
}

fn connect(config: &Config) -> Result<(), Box<dyn std::error::Error>> {
    let check = with_spinner("Connecting", || server::ssh_run(config, "true"))?;
    if !check.success {
        let mut msg = format!("Cannot reach {}", config.ssh_target());
        if !check.stderr.is_empty() {
            msg.push_str(&format!("\n{}", check.stderr));
        }
        return Err(msg.into());
    }
    Ok(())
}

fn fetch_sessions(config: &Config) -> Result<Vec<Session>, Box<dyn std::error::Error>> {
    let sessions = with_spinner("Fetching sessions", || session::list_sessions(config))?;
    let mut sessions: Vec<Session> = with_spinner("Loading git stats", || {
        sessions
            .into_iter()
            .map(|mut s| {
                if s.status == "running" {
                    if let Ok(m) = session::git_metrics(config, &s.name) {
                        s.insertions = m.insertions;
                        s.deletions = m.deletions;
                    }
                }
                s
            })
            .collect()
    });

    // Fetch PR info (runs locally, fast)
    // Extract repo slug from URL (e.g. "https://github.com/org/repo" → "org/repo")
    let repo_slug = config.repo.url
        .trim_end_matches('/')
        .trim_end_matches(".git")
        .rsplit("github.com/")
        .next()
        .unwrap_or("");
    if !repo_slug.is_empty() {
        with_spinner("Checking PRs", || {
            session::fetch_prs(repo_slug, &mut sessions);
        });
    }

    Ok(sessions)
}

fn tgv_theme() -> ColorfulTheme {
    ColorfulTheme {
        active_item_style: Style::new().yellow().bold(),
        active_item_prefix: style("  ▸ ".to_string()).yellow().bold(),
        inactive_item_prefix: style("    ".to_string()),
        prompt_style: Style::new().magenta().bold(),
        prompt_prefix: style("  ".to_string()),
        success_prefix: style("  ▸ ".to_string()).yellow().bold(),
        ..ColorfulTheme::default()
    }
}

fn format_session(s: &Session) -> String {
    let icon = if s.status == "running" { "●" } else { "○" };
    let label = if let Some(ref dn) = s.display_name {
        format!("{dn} ({})", s.branch)
    } else {
        s.branch.clone()
    };

    let mut meta = Vec::new();
    if let Some(ins) = s.insertions {
        meta.push(format!("+{ins}"));
    }
    if let Some(del) = s.deletions {
        meta.push(format!("-{del}"));
    }
    if let Some(ref pr) = s.pr {
        meta.push(format!("PR #{} {}", pr.number, pr.title));
    }

    if meta.is_empty() {
        format!("{icon}  {label}")
    } else {
        format!("{icon}  {label}  ╌  {}", meta.join("  "))
    }
}

fn print_header(config: &Config) {
    eprint!("\x1b[2J\x1b[H"); // clear screen + cursor home
    banner::print_banner();
    let info = format!("{}  ╌  {}", config.ssh_target(), &config.repo.url);
    let term_width = console::Term::stderr().size().1 as usize;
    let pad = term_width.saturating_sub(info.chars().count()) / 2;
    eprintln!(
        "{:pad$}{}  ╌  {}",
        "",
        style(config.ssh_target()).dim(),
        style(&config.repo.url).dim(),
        pad = pad
    );
    eprintln!();
}

/// Let the user pick a remote branch or create a new one
fn pick_branch(
    config: &Config,
    theme: &dialoguer::theme::ColorfulTheme,
) -> Result<Option<String>, Box<dyn std::error::Error>> {
    let branches = with_spinner("Fetching branches", || session::list_branches(config))?;

    let mut items = Vec::new();
    items.push("⊕ New branch (random name)".to_string());
    items.push("⊕ New branch (custom name)".to_string());
    for b in &branches {
        items.push(format!("  {b}"));
    }

    let selection = FuzzySelect::with_theme(theme)
        .with_prompt("Branch")
        .items(&items)
        .default(0)
        .interact_opt()?;

    match selection {
        None => Ok(None),
        Some(0) => Ok(Some(session::random_branch_name())),
        Some(1) => {
            let name: String = dialoguer::Input::with_theme(theme)
                .with_prompt("Branch name")
                .interact_text()?;
            let name = name.trim().to_string();
            if name.is_empty() {
                Ok(Some(session::random_branch_name()))
            } else {
                Ok(Some(name))
            }
        }
        Some(i) => Ok(Some(branches[i - 2].clone())),
    }
}

/// Interactive session picker
fn interactive(config: &Config) -> Result<(), Box<dyn std::error::Error>> {
    print_header(config);
    connect(config)?;

    let theme = tgv_theme();

    loop {
        print_header(config);

        let sessions = fetch_sessions(config)?;
        let mut items: Vec<String> = sessions.iter().map(format_session).collect();
        items.push("＋ New session".to_string());

        let selection = FuzzySelect::with_theme(&theme)
            .with_prompt("Session")
            .items(&items)
            .default(0)
            .interact_opt()?;

        let Some(selection) = selection else {
            return Ok(());
        };

        if selection == sessions.len() {
            let branch = pick_branch(config, &theme)?;
            let Some(branch) = branch else {
                continue;
            };

            let name = {
                let spinner = Spinner::new(&format!("Spawning on {branch}"));
                session::spawn(config, &branch, |step| {
                    spinner.set_message(&format!("Spawning on {branch} · {step}"));
                })?
            };
            eprintln!("  {} {name}", style("Created").green());
            attach(config, &name)?;
            continue;
        }

        // Action picker
        print_header(config);
        let s = &sessions[selection];
        let action_label = if s.status == "running" { "▶ Attach" } else { "▶ Restart & attach" };
        let actions = &[action_label, "✎ Rename", "✕ Kill", "‹ Back"];

        let action = FuzzySelect::with_theme(&theme)
            .with_prompt(&format_session(s))
            .items(actions)
            .default(0)
            .interact_opt()?;

        match action {
            Some(0) => {
                if s.status != "running" {
                    with_spinner(&format!("Restarting {}", s.name), || {
                        let _ = server::ssh_run(config, &format!("docker start {}", s.name));
                        std::thread::sleep(std::time::Duration::from_secs(1));
                    });
                }
                attach(config, &s.name)?;
                continue;
            }
            Some(1) => {
                let new_name: String = dialoguer::Input::with_theme(&theme)
                    .with_prompt("Display name")
                    .with_initial_text(s.display_name.as_deref().unwrap_or(""))
                    .interact_text()?;
                let new_name = new_name.trim().to_string();
                if !new_name.is_empty() {
                    session::rename(config, &s.name, &new_name)?;
                }
                continue;
            }
            Some(2) => {
                let name = s.name.clone();
                let branch = s.branch.clone();
                with_spinner(&format!("Killing {name}"), || {
                    let _ = session::stop(config, &name);
                });
                eprintln!("  {} {branch}", style("Killed").red());
                continue;
            }
            _ => continue,
        }
    }
}

/// Attach to a session — tries mosh (local echo), falls back to SSH
fn attach(config: &Config, container: &str) -> Result<(), Box<dyn std::error::Error>> {
    let docker_cmd = session::attach_cmd(container);
    let has_mosh = std::process::Command::new("which")
        .arg("mosh")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    let status = if has_mosh {
        eprintln!(
            "{}",
            style(format!("Attaching via mosh to {container}...")).dim()
        );
        // mosh --ssh="ssh options" user@host -- command
        let result = std::process::Command::new("mosh")
            .args([
                &format!("{}@{}", config.server.user, config.server.host),
                "--",
                "bash", "-c", &docker_cmd,
            ])
            .status()?;

        if result.success() {
            return Ok(());
        }
        eprintln!("{}", style("mosh failed, falling back to SSH...").yellow());
        std::process::Command::new("ssh")
            .args(["-t", &config.ssh_target(), &docker_cmd])
            .status()?
    } else {
        eprintln!(
            "{}",
            style(format!("Attaching via SSH to {container}...")).dim()
        );
        std::process::Command::new("ssh")
            .args(["-t", &config.ssh_target(), &docker_cmd])
            .status()?
    };

    if !status.success() {
        return Err("Connection closed".into());
    }
    Ok(())
}


/// Run `tgv init` to bootstrap a remote server.
fn init_server(
    host: &str,
    repo: &str,
    branch: &str,
    private: bool,
) -> Result<(), Box<dyn std::error::Error>> {
    let (user, hostname) = if let Some(pos) = host.find('@') {
        (&host[..pos], &host[pos + 1..])
    } else {
        ("root", host)
    };

    let mut config = Config::default();
    config.server.host = hostname.to_string();
    config.server.user = user.to_string();
    config.repo.url = repo.to_string();
    config.repo.default_branch = branch.to_string();

    // Validate inputs before using in shell commands
    if !repo.starts_with("https://") && !repo.starts_with("git@") {
        return Err("Repo URL must start with https:// or git@".into());
    }
    if repo.chars().any(|c| {
        matches!(
            c,
            ';' | '|' | '&' | '`' | '$' | '(' | ')' | '{' | '}' | '<' | '>' | '\n' | '\0'
        )
    }) {
        return Err("Repo URL contains invalid characters".into());
    }
    session::validate_branch(branch).map_err(|e| -> Box<dyn std::error::Error> { e.into() })?;

    // Auto-detect git identity from local machine
    if let Ok(out) = std::process::Command::new("git")
        .args(["config", "user.name"])
        .output()
    {
        if out.status.success() {
            config.git.name = String::from_utf8_lossy(&out.stdout).trim().to_string();
        }
    }
    if let Ok(out) = std::process::Command::new("git")
        .args(["config", "user.email"])
        .output()
    {
        if out.status.success() {
            config.git.email = String::from_utf8_lossy(&out.stdout).trim().to_string();
        }
    }

    // Check local deps
    println!("Checking local dependencies...");
    for (bin, name, hint) in [
        ("ssh", "OpenSSH", "brew install openssh"),
        ("scp", "scp", "brew install openssh"),
    ] {
        if std::process::Command::new("which").arg(bin).output().map(|o| !o.status.success()).unwrap_or(true) {
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
        (
            "docker --version",
            "Docker",
            "curl -fsSL https://get.docker.com | sh",
        ),
        (
            "mosh-server --version",
            "mosh",
            "sudo apt install -y mosh",
        ),
        ("git --version", "git", "sudo apt install -y git"),
    ] {
        let r = server::ssh_run(&config, cmd)?;
        if r.success {
            println!(
                "  ✓ {name}: {}",
                r.stdout.lines().next().unwrap_or("")
            );
        } else {
            eprintln!("  ✗ {name} — install: {hint}");
            return Err(format!("Missing on server: {name}").into());
        }
    }

    // Setup OpenRouter API key on the server
    println!("Setting up OpenRouter auth on server...");
    let has_key = server::ssh_run(&config, "test -f ~/.config/tgv/openrouter_key")?;
    if !has_key.success {
        println!("  No API key found on server.");
        let api_key: String = dialoguer::Password::with_theme(&tgv_theme())
            .with_prompt("OpenRouter API key")
            .interact()?;

        let api_key = api_key.trim().to_string();
        if api_key.is_empty() {
            eprintln!("  ⚠ No API key provided — sessions will need manual configuration");
        } else {
            server::ssh_run(&config,
                "mkdir -p ~/.config/tgv && chmod 700 ~/.config/tgv"
            )?;
            server::scp_string_to(&config, &api_key, "~/.config/tgv/openrouter_key", "600")?;
            println!("  API key configured on server");
        }
    } else {
        println!("  API key already configured on server");
    }

    // Build Docker image
    println!("Building Docker image with {repo} ({branch})...");
    let docker_dir = std::env::current_dir()?.join("docker");
    server::ssh_run(&config, "mkdir -p /tmp/tgv-build")?;
    server::scp_to(
        &config,
        &docker_dir.join("Dockerfile").to_string_lossy(),
        "/tmp/tgv-build/Dockerfile",
    )?;

    // Clone repo on server host (not in Docker — no token leak)
    if private {
        let gh_out = std::process::Command::new("gh")
            .args(["auth", "token"])
            .output()?;
        if !gh_out.status.success() {
            return Err("--private requires `gh auth login` first".into());
        }
        let token = String::from_utf8_lossy(&gh_out.stdout).trim().to_string();
        println!("  GitHub token found");
        server::ssh_run(&config, "printf '#!/bin/sh\ncat /tmp/tgv-build/.git-token' > /tmp/tgv-build/.git-askpass && chmod 700 /tmp/tgv-build/.git-askpass")?;
        server::scp_string_to(&config, &token, "/tmp/tgv-build/.git-token", "600")?;
        server::ssh_run(
            &config,
            &format!(
                "GIT_ASKPASS=/tmp/tgv-build/.git-askpass git clone --branch {branch} https://x-access-token@github.com/{} /tmp/tgv-build/repo",
                repo.trim_start_matches("https://github.com/")
            ),
        )?;
        server::ssh_run(&config, "rm -f /tmp/tgv-build/.git-askpass /tmp/tgv-build/.git-token")?;
        server::ssh_run(
            &config,
            &format!("cd /tmp/tgv-build/repo && git remote set-url origin {repo}"),
        )?;
    } else {
        let r = server::ssh_run(
            &config,
            &format!("git clone --branch {branch} {repo} /tmp/tgv-build/repo"),
        )?;
        if !r.success {
            return Err(format!("git clone failed: {}", r.stderr).into());
        }
    }

    // Append shell tools + COPY + deps install to Dockerfile
    let extra = r#"# Shell tools: zsh, neovim, oh-my-zsh, utilities
RUN apt-get update && \
    apt-get install -y zsh neovim fzf bat fd-find ripgrep curl locales sudo ncurses-term && \
    locale-gen en_US.UTF-8 && \
    rm -rf /var/lib/apt/lists/*

# Zellij (session persistence)
RUN curl -L https://github.com/zellij-org/zellij/releases/latest/download/zellij-x86_64-unknown-linux-musl.tar.gz | tar xz -C /usr/local/bin

# Create non-root user with sudo access
RUN useradd -m -s /bin/zsh -G sudo dev && \
    echo 'dev ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

# Oh My Zsh for dev user
USER dev
ENV HOME=/home/dev
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended && \
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions 2>/dev/null && \
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting 2>/dev/null

# Custom arrow theme + zshrc
RUN cat > /home/dev/.oh-my-zsh/custom/themes/arrow-custom.zsh-theme << 'THEMEEOF'
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
PROMPT='${root_indicator}%F{yellow}tgv%f %F{$NCOLOR}%c ➤ %f'
RPROMPT='$(cmd_duration)$(git_info)'
export LSCOLORS="exfxcxdxbxbxbxbxbxbxbx"
export LS_COLORS="di=34;40:ln=35;40:so=32;40:pi=33;40:ex=31;40:bd=31;40:cd=31;40:su=31;40:sg=31;40:tw=31;40:ow=31;40:"
THEMEEOF

RUN cat > /home/dev/.zshrc << 'ZSHEOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="arrow-custom"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
source $ZSH/oh-my-zsh.sh

export EDITOR='nvim'
export LANG=en_US.UTF-8
export COLORTERM=truecolor
export PATH="$HOME/.local/bin:$PATH"

alias vim='nvim'
alias ll='ls -la --color=auto'
command -v batcat &>/dev/null && alias cat='batcat --paging=never'
command -v fdfind &>/dev/null && alias fd='fdfind'
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
ZSHEOF

# Minimal nvim config (no plugins, no network)
RUN mkdir -p /home/dev/.config/nvim && cat > /home/dev/.config/nvim/init.lua << 'NVIMEOF'
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

USER root
COPY repo /workspace/repo
RUN chown -R dev:dev /workspace/repo
USER dev
WORKDIR /workspace/repo
RUN if [ -f pnpm-lock.yaml ]; then pnpm install && (grep -q '"prepare"' package.json 2>/dev/null && pnpm prepare || true); elif [ -f package-lock.json ]; then npm install; elif [ -f yarn.lock ]; then npm install -g yarn && yarn install; fi
# Python deps — install uv projects found in subdirectories
RUN find . -name "pyproject.toml" -maxdepth 2 -exec sh -c 'cd "$(dirname "{}")" && uv sync 2>/dev/null' \; || true
"#;
    server::ssh_run(
        &config,
        &format!("cat >> /tmp/tgv-build/Dockerfile << 'EOF'\n{extra}EOF"),
    )?;

    let r = server::ssh_run(
        &config,
        &format!("docker build -t {} /tmp/tgv-build", config.docker.image),
    )?;
    if !r.success {
        return Err(format!("Docker build failed:\n{}", r.stderr).into());
    }
    server::ssh_run(&config, "rm -rf /tmp/tgv-build")?;
    println!("  Docker image built");

    // Docker network
    let net = server::ssh_run(
        &config,
        &format!("docker network inspect {}", config.docker.network),
    )?;
    if !net.success {
        server::ssh_run(
            &config,
            &format!("docker network create {}", config.docker.network),
        )?;
    }
    println!("  Network ready");

    config.save()?;
    println!(
        "\n{} Run `tgv` to open the session manager.",
        style("Config saved.").green()
    );
    Ok(())
}
