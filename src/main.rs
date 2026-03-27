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
        let clone_url = repo.replace("https://github.com", &format!("https://x-access-token:{token}@github.com"));
        server::ssh_run(&config, &format!("git clone --branch {branch} {clone_url} /tmp/tgv-build/repo"))?;
        server::ssh_run(&config, &format!("cd /tmp/tgv-build/repo && git remote set-url origin {repo}"))?;
    } else {
        let r = server::ssh_run(&config, &format!("git clone --branch {branch} {repo} /tmp/tgv-build/repo"))?;
        if !r.success {
            return Err(format!("git clone failed: {}", r.stderr).into());
        }
    }

    // Append COPY + deps install to Dockerfile
    let extra = r#"COPY repo /workspace/repo
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
