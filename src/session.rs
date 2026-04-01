//! Docker container session management on remote server

use crate::config::Config;
use crate::server::ssh_run;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::time::{SystemTime, UNIX_EPOCH};

/// Validate a string is safe for shell interpolation (branch names, container names, etc.)
fn is_shell_safe(s: &str) -> bool {
    !s.is_empty()
        && s.len() < 256
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/'))
}

const ADJECTIVES: [&str; 16] = [
    "swift", "bright", "calm", "bold", "keen", "warm", "cool", "fast",
    "sharp", "light", "deep", "wild", "pure", "soft", "fair", "true",
];

const NOUNS: [&str; 16] = [
    "river", "spark", "cloud", "stone", "leaf", "wave", "bloom", "frost",
    "trail", "ridge", "grove", "dusk", "peak", "tide", "vale", "glow",
];

/// Generate a random branch name: tgv/<adj>-<noun>-<hex>
pub fn random_branch_name() -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let mut hasher = DefaultHasher::new();
    now.hash(&mut hasher);
    let h = hasher.finish();

    let adj = ADJECTIVES[(h as usize) % ADJECTIVES.len()];
    let noun = NOUNS[((h >> 16) as usize) % NOUNS.len()];
    let hex = format!("{:03x}", (h >> 32) & 0xFFF);

    format!("tgv/{adj}-{noun}-{hex}")
}

/// Validate a branch name, return error if unsafe
pub fn validate_branch(branch: &str) -> Result<(), String> {
    if is_shell_safe(branch) {
        Ok(())
    } else {
        Err(format!("Invalid branch name: {branch}. Use only alphanumeric, -, _, ., /"))
    }
}

/// A running or exited tgv session
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct Session {
    pub name: String,
    pub repo: String,
    pub branch: String,
    pub status: String,
    pub insertions: Option<u32>,
    pub deletions: Option<u32>,
}

fn session_name(repo_url: &str) -> String {
    let repo = repo_url
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("session")
        .replace(".git", "");

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis();
    let mut hasher = DefaultHasher::new();
    format!("{repo_url}{now}").hash(&mut hasher);
    let hash = format!("{:x}", hasher.finish());

    format!("{}-{}", repo, &hash[..8.min(hash.len())])
}

/// Zellij config + layout for Claude Code sessions.
const ZELLIJ_SETUP: &str = r##"mkdir -p /home/dev/.config/zellij/layouts
cat > /home/dev/.config/zellij/config.kdl << 'CFGEOF'
default_shell "zsh"
pane_frames false
default_layout "tgv"
mouse_mode true
scrollback_editor "nvim"
theme "default"
show_release_notes false
show_startup_tips false
CFGEOF
cat > /home/dev/.config/zellij/layouts/tgv.kdl << 'LAYEOF'
layout {
    pane command="claude" {
        args "--dangerously-skip-permissions"
    }
    pane size=1 borderless=true {
        plugin location="compact-bar"
    }
}
LAYEOF
"##;

/// Spawn a new session container on the given branch.
/// Calls `on_step` with a message before each SSH operation.
pub fn spawn(
    config: &Config,
    branch: &str,
    on_step: impl Fn(&str),
) -> Result<String, Box<dyn std::error::Error>> {
    validate_branch(branch).map_err(|e| -> Box<dyn std::error::Error> { e.into() })?;
    let name = session_name(&config.repo.url);

    let git_config = if !config.git.name.is_empty() && !config.git.email.is_empty() {
        format!(
            "git config --global user.name '{}'\ngit config --global user.email '{}'",
            config.git.name.replace('\'', "'\\''"),
            config.git.email.replace('\'', "'\\''"),
        )
    } else {
        String::new()
    };

    let script = format!(
        r#"#!/bin/bash
# OAuth token — write to .zshenv so ALL zsh processes get it (including zellij commands)
if [ -f /run/secrets/claude_token ]; then
  echo "export CLAUDE_CODE_OAUTH_TOKEN=$(cat /run/secrets/claude_token)" > /home/dev/.zshenv
  chmod 600 /home/dev/.zshenv
fi

# Claude Code settings — skip onboarding, trust workspace, allow all tools
mkdir -p /home/dev/.claude
cat > /home/dev/.claude/settings.json << 'CFGEOF'
{{"permissions":{{"allow":["*"],"deny":[]}}}}
CFGEOF
cat > /home/dev/.claude.json << 'CFGEOF'
{{"theme":"dark","hasCompletedOnboarding":true}}
CFGEOF

# Project-level settings to mark workspace as trusted
mkdir -p /workspace/repo/.claude
cat > /workspace/repo/.claude/settings.local.json << 'CFGEOF'
{{"permissions":{{"allow":["*"],"deny":[]}}}}
CFGEOF

{git_config}
{zellij_setup}
cd /workspace/repo
git checkout -b {branch} 2>/dev/null || git checkout {branch} 2>&1
exec sleep infinity
"#,
        zellij_setup = ZELLIJ_SETUP,
    );

    // Step 1: prepare scripts dir + write entrypoint via stdin (not heredoc — avoids quoting issues)
    on_step("Preparing entrypoint");
    ssh_run(config, "mkdir -p /tmp/tgv-scripts && chmod 700 /tmp/tgv-scripts")?;
    crate::server::ssh_write_stdin(
        config,
        &format!("cat > /tmp/tgv-scripts/{name}.sh && chmod +x /tmp/tgv-scripts/{name}.sh"),
        script.as_bytes(),
    )?;

    // Step 2: token (non-fatal — sessions work without it, just need manual login)
    on_step("Configuring auth token");
    let _ = ssh_run(config, &format!(
        "cat ~/.config/tgv/oauth_token > /tmp/tgv-scripts/{name}.token 2>/dev/null; chmod 600 /tmp/tgv-scripts/{name}.token 2>/dev/null; true"
    ));

    // Step 3: docker run
    on_step("Starting container");
    let docker_cmd = format!(
        "docker run -d \
         --name {name} \
         --network {network} \
         --label tgv.repo={repo} \
         --label tgv.branch={branch} \
         -e TERM=xterm-256color \
         -e COLORTERM=truecolor \
         -e LANG=C.UTF-8 \
         -v tgv-workspace-{name}:/workspace/repo \
         -v tgv-claude-{name}:/home/dev/.claude \
         -v /tmp/tgv-scripts/{name}.sh:/entrypoint.sh:ro \
         -v /tmp/tgv-scripts/{name}.token:/run/secrets/claude_token:ro \
         {image} \
         bash /entrypoint.sh",
        network = config.docker.network,
        repo = config.repo.url,
        image = config.docker.image,
    );

    let result = ssh_run(config, &docker_cmd)?;
    if !result.success {
        return Err(format!("Failed to spawn: {}", result.stderr).into());
    }
    Ok(name)
}

/// List all tgv sessions on the server
pub fn list_sessions(config: &Config) -> Result<Vec<Session>, Box<dyn std::error::Error>> {
    let cmd = "docker ps -a --filter label=tgv.repo \
               --format '{{.Names}}\t{{.Label \"tgv.repo\"}}\t{{.Label \"tgv.branch\"}}\t{{.Status}}\t{{.CreatedAt}}'";

    let result = ssh_run(config, cmd)?;
    if !result.success {
        return Err(format!("Failed to list sessions: {}", result.stderr).into());
    }
    if result.stdout.is_empty() {
        return Ok(Vec::new());
    }

    let mut sessions = Vec::new();
    for line in result.stdout.lines() {
        let parts: Vec<&str> = line.split('\t').collect();
        if parts.len() >= 4 && is_shell_safe(parts[0]) {
            let status = if parts[3].contains("Up") {
                "running"
            } else {
                "exited"
            };

            let repo_url = parts[1];
            let repo_parts: Vec<&str> = repo_url.trim_end_matches('/').rsplit('/').collect();
            let repo_name = repo_parts[0].replace(".git", "");
            let repo = if repo_parts.len() > 1 {
                format!("{}/{}", repo_parts[1], repo_name)
            } else {
                repo_name
            };

            sessions.push(Session {
                name: parts[0].to_string(),
                repo,
                branch: parts[2].to_string(),
                status: status.to_string(),
                insertions: None,
                deletions: None,
            });
        }
    }
    Ok(sessions)
}

/// Git metrics result
pub struct GitMetricsResult {
    pub insertions: Option<u32>,
    pub deletions: Option<u32>,
}

/// Fetch git metrics for a running session (single docker exec for speed)
pub fn git_metrics(
    config: &Config,
    name: &str,
) -> Result<GitMetricsResult, Box<dyn std::error::Error>> {
    if !is_shell_safe(name) {
        return Err(format!("Invalid container name: {name}").into());
    }
    let cmd = format!(
        "docker exec -u dev {name} bash -c 'cd /workspace/repo 2>/dev/null || exit 0; \
         git diff --shortstat 2>/dev/null; git diff --cached --shortstat 2>/dev/null'"
    );
    let result = ssh_run(config, &cmd)?;

    let mut insertions: u32 = 0;
    let mut deletions: u32 = 0;

    // Parse all "N files changed, X insertions(+), Y deletions(-)" lines
    for line in result.stdout.lines() {
        for part in line.split(',') {
            let part = part.trim();
            if part.contains("insertion") {
                insertions += part.split_whitespace().next()
                    .and_then(|n| n.parse::<u32>().ok())
                    .unwrap_or(0);
            } else if part.contains("deletion") {
                deletions += part.split_whitespace().next()
                    .and_then(|n| n.parse::<u32>().ok())
                    .unwrap_or(0);
            }
        }
    }

    Ok(GitMetricsResult {
        insertions: if insertions > 0 { Some(insertions) } else { None },
        deletions: if deletions > 0 { Some(deletions) } else { None },
    })
}

/// Build the docker exec command to attach to a zellij session.
/// Creates the session on first attach (uses the tgv layout which starts claude).
/// On subsequent attaches, reattaches to the existing session.
pub fn attach_cmd(container: &str) -> String {
    debug_assert!(is_shell_safe(container));
    format!(
        "docker exec -u dev -it -w /workspace/repo {container} \
         zellij attach tgv --create"
    )
}

/// Stop and remove a session container + its volumes
pub fn stop(config: &Config, name: &str) -> Result<(), Box<dyn std::error::Error>> {
    if !is_shell_safe(name) {
        return Err(format!("Invalid container name: {name}").into());
    }
    ssh_run(config, &format!("docker rm -f {name}"))?;
    ssh_run(config, &format!("docker volume rm -f tgv-workspace-{name} tgv-claude-{name}"))?;
    ssh_run(config, &format!("rm -f /tmp/tgv-scripts/{name}.sh /tmp/tgv-scripts/{name}.token"))?;
    Ok(())
}
