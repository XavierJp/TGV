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
    pub display_name: Option<String>,
    pub insertions: Option<u32>,
    pub deletions: Option<u32>,
    pub pr: Option<PrInfo>,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct PrInfo {
    pub number: u32,
    pub title: String,
    pub url: String,
}

/// Fetch PR info for sessions by branch name (runs `gh` locally)
pub fn fetch_prs(repo: &str, sessions: &mut [Session]) {
    // Get all open PRs in one call
    let output = std::process::Command::new("gh")
        .args([
            "pr", "list",
            "--repo", repo,
            "--state", "open",
            "--json", "number,title,url,headRefName",
        ])
        .output();

    let Ok(output) = output else { return };
    if !output.status.success() { return; }

    let json = String::from_utf8_lossy(&output.stdout);
    // Simple JSON parsing without serde_json — each PR is {number, title, url, headRefName}
    for s in sessions.iter_mut() {
        // Find PR matching this session's branch
        // Look for "headRefName":"<branch>" in the JSON
        let needle = format!("\"headRefName\":\"{}\"", s.branch);
        if let Some(pos) = json.find(&needle) {
            // Find the enclosing object
            let obj_start = json[..pos].rfind('{').unwrap_or(0);
            let obj_end = json[pos..].find('}').map(|p| pos + p + 1).unwrap_or(json.len());
            let obj = &json[obj_start..obj_end];

            let number = extract_json_u32(obj, "number");
            let title = extract_json_str(obj, "title");
            let url = extract_json_str(obj, "url");

            if let (Some(number), Some(title), Some(url)) = (number, title, url) {
                s.pr = Some(PrInfo { number, title, url });
            }
        }
    }
}

fn extract_json_str<'a>(obj: &'a str, key: &str) -> Option<String> {
    let needle = format!("\"{}\":\"", key);
    let start = obj.find(&needle)? + needle.len();
    let end = obj[start..].find('"')? + start;
    Some(obj[start..end].to_string())
}

fn extract_json_u32(obj: &str, key: &str) -> Option<u32> {
    let needle = format!("\"{}\":", key);
    let start = obj.find(&needle)? + needle.len();
    let num_str: String = obj[start..].chars().take_while(|c| c.is_ascii_digit()).collect();
    num_str.parse().ok()
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

/// Zellij config + layout for OpenCode sessions.
const ZELLIJ_SETUP: &str = r##"mkdir -p /home/dev/.config/zellij/layouts
cat > /home/dev/.config/zellij/config.kdl << 'CFGEOF'
default_shell "zsh"
default_layout "tgv"
default_mode "locked"
pane_frames true
simplified_ui true
mouse_mode true
copy_on_select true
mirror_session true
on_force_close "detach"
session_serialization true
scrollback_lines_to_serialize 5000
scrollback_editor "nvim"
theme "default"
show_release_notes false
show_startup_tips false
keybinds {
    locked {
        bind "Ctrl q" { Detach; }
    }
}
CFGEOF
cat > /home/dev/.config/zellij/layouts/tgv.kdl << 'LAYEOF'
layout {
    pane split_direction="vertical" {
        pane command="/usr/local/bin/opencode" size="70%" focus=true
        pane size="30%"
    }
    pane size=1 borderless=true {
        plugin location="status-bar"
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
# Entrypoint runs as root — copies secrets, writes config, then drops to dev

# OpenRouter API key — export for OpenCode
if [ -f /run/secrets/openrouter_key ]; then
  export OPENROUTER_API_KEY=$(cat /run/secrets/openrouter_key)
fi

# OpenCode config — write opencode.json to workspace
cat > /workspace/repo/opencode.json << 'CFGEOF'
{{
  "$schema": "https://opencode.ai/config.json",
  "provider": {{
    "openrouter": {{
      "models": {{
        "qwen/qwen3-coder": {{}},
        "qwen/qwen3-coder:free": {{}}
      }}
    }}
  }}
}}
CFGEOF

# OpenCode TUI theme — inherit terminal colors
cat > /workspace/repo/tui.json << 'CFGEOF'
{{
  "$schema": "https://opencode.ai/tui.json",
  "theme": "tokyonight"
}}
CFGEOF

# GitHub auth — configure git to use gh for HTTPS credentials
if [ -f /run/secrets/gh_token ]; then
  GH_TOKEN=$(cat /run/secrets/gh_token)
  mkdir -p /home/dev/.config/gh
  cat > /home/dev/.config/gh/hosts.yml << GHEOF
github.com:
    oauth_token: $GH_TOKEN
    user: ""
    git_protocol: https
GHEOF
  chmod 600 /home/dev/.config/gh/hosts.yml
  # Configure git credential helper to use gh
  git config --global credential.https://github.com.helper '!gh auth git-credential'
fi

# Git identity
{git_config}

# Zellij
{zellij_setup}

# Branch
cd /workspace/repo
git config --global --add safe.directory /workspace/repo
git fetch --all 2>/dev/null
git checkout {branch} 2>/dev/null || git checkout -b {branch} origin/{branch} 2>/dev/null || git checkout -b {branch} 2>/dev/null

# Fix ownership — volume is mounted at /mnt/opencode
chown -R dev:dev /mnt/opencode
mkdir -p /home/dev/.local/share
ln -sfn /mnt/opencode /home/dev/.local/share/opencode
chown -R dev:dev /home/dev /workspace/repo
exec su dev -c 'export OPENROUTER_API_KEY=$(cat /run/secrets/openrouter_key 2>/dev/null); sleep infinity'
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

    // Step 2: OpenRouter API key (non-fatal — sessions work without it, just need manual config)
    on_step("Configuring credentials");
    let _ = ssh_run(config, &format!(
        "cp ~/.config/tgv/openrouter_key /tmp/tgv-scripts/{name}.key 2>/dev/null; chmod 644 /tmp/tgv-scripts/{name}.key 2>/dev/null; true"
    ));

    // Step 2b: GitHub token from local machine (non-fatal)
    if let Some(token) = local_gh_token() {
        let _ = crate::server::ssh_write_stdin(
            config,
            &format!("cat > /tmp/tgv-scripts/{name}.gh && chmod 644 /tmp/tgv-scripts/{name}.gh"),
            token.as_bytes(),
        );
    }

    // Step 3: docker run
    on_step("Starting container");
    let docker_cmd = format!(
        "docker run -d \
         --name {name} \
         --user root \
         --network {network} \
         --label tgv.repo={repo} \
         --label tgv.branch={branch} \
         -e TERM=xterm-256color \
         -e COLORTERM=truecolor \
         -e LANG=C.UTF-8 \
         -v tgv-workspace-{name}:/workspace/repo \
         -v tgv-opencode-{name}:/mnt/opencode \
         -v /tmp/tgv-scripts/{name}.sh:/entrypoint.sh:ro \
         -v /tmp/tgv-scripts/{name}.key:/run/secrets/openrouter_key:ro \
         -v /tmp/tgv-scripts/{name}.gh:/run/secrets/gh_token:ro \
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

/// List remote git branches from the repo inside a running container (or from server clone)
pub fn list_branches(config: &Config) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    // Try to get branches from the Docker image's baked-in repo
    let cmd = format!(
        "docker run --rm {} bash -c 'cd /workspace/repo 2>/dev/null && git branch -r 2>/dev/null'",
        config.docker.image
    );
    let result = ssh_run(config, &cmd)?;
    if !result.success || result.stdout.is_empty() {
        return Ok(Vec::new());
    }

    let branches: Vec<String> = result
        .stdout
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim();
            // Skip HEAD pointer
            if trimmed.contains("->") {
                return None;
            }
            // Strip "origin/" prefix
            trimmed.strip_prefix("origin/").map(|s| s.to_string())
        })
        .collect();

    Ok(branches)
}

/// List all tgv sessions on the server
pub fn list_sessions(config: &Config) -> Result<Vec<Session>, Box<dyn std::error::Error>> {
    let cmd = "docker ps -a --filter label=tgv.repo \
               --format '{{.Names}}\t{{.Label \"tgv.repo\"}}\t{{.Label \"tgv.branch\"}}\t{{.Status}}\t{{.Label \"tgv.display_name\"}}'";

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

            let display_name = parts.get(4)
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .or_else(|| read_display_name(config, parts[0]));

            sessions.push(Session {
                name: parts[0].to_string(),
                repo,
                branch: parts[2].to_string(),
                status: status.to_string(),
                display_name,
                insertions: None,
                deletions: None,
                pr: None,
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

/// Rename a session's display name (stored as a Docker label via container recreate)
/// Docker doesn't support changing labels on a running container, so we use a label file instead.
pub fn rename(config: &Config, name: &str, display_name: &str) -> Result<(), Box<dyn std::error::Error>> {
    if !is_shell_safe(name) {
        return Err(format!("Invalid container name: {name}").into());
    }
    // Store display name by updating the container's label — requires stop/commit/recreate
    // Simpler approach: use docker container update doesn't support labels either.
    // Simplest: store in a file on the host, keyed by container name.
    // But cleanest for Docker: stop, commit, rm, re-run with new label.
    //
    // Actually simplest: just re-label by creating a small sidecar file.
    // We'll write to a known location on the server.
    let safe_display = display_name.replace('\'', "'\\''");
    ssh_run(config, &format!(
        "mkdir -p /tmp/tgv-meta && echo '{safe_display}' > /tmp/tgv-meta/{name}.name"
    ))?;
    Ok(())
}

/// Read display name from sidecar file (fallback for containers without the label)
pub fn read_display_name(config: &Config, name: &str) -> Option<String> {
    if !is_shell_safe(name) {
        return None;
    }
    ssh_run(config, &format!("cat /tmp/tgv-meta/{name}.name 2>/dev/null"))
        .ok()
        .and_then(|r| {
            let s = r.stdout.trim().to_string();
            if s.is_empty() { None } else { Some(s) }
        })
}

/// Get GitHub token from local machine's `gh` CLI
pub fn local_gh_token() -> Option<String> {
    std::process::Command::new("gh")
        .args(["auth", "token"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|s| !s.is_empty())
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
    ssh_run(config, &format!("docker volume rm -f tgv-workspace-{name} tgv-opencode-{name}"))?;
    ssh_run(config, &format!("rm -f /tmp/tgv-scripts/{name}.sh /tmp/tgv-scripts/{name}.key /tmp/tgv-scripts/{name}.gh"))?;
    Ok(())
}
