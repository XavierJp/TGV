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

/// Shell scripts for tmux status bar — written as heredocs inside the container.
/// Not inside format!() so $ and " are safe.
const TMUX_SETUP: &str = r##"# tmux status bar
mkdir -p /usr/local/bin

cat > /usr/local/bin/tgv-status-left << 'SLEOF'
#!/bin/bash
cd /workspace/repo 2>/dev/null || exit 0
branch=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "?")
dirty=$(git status --porcelain 2>/dev/null)
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then state=" *"; else state=""; fi
wins=$(tmux list-windows -t tgv -F '#{window_name} #{window_active}' 2>/dev/null | while read wname wactive; do
  if [ "$wactive" = "1" ]; then printf "[%s] " "$wname"; else printf "%s " "$wname"; fi
done)
echo " $branch$state | $wins"
SLEOF
chmod +x /usr/local/bin/tgv-status-left

cat > /usr/local/bin/tgv-status-right << 'SREOF'
#!/bin/bash
cd /workspace/repo 2>/dev/null || exit 0
staged=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
modified=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
untracked=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
parts=""
staged=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
modified=$(git diff --numstat 2>/dev/null | wc -l | tr -d ' ')
untracked=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
ch=""
[ "$staged" -gt 0 ] 2>/dev/null && ch="+${staged} "
[ "$modified" -gt 0 ] 2>/dev/null && ch="${ch}~${modified} "
[ "$untracked" -gt 0 ] 2>/dev/null && ch="${ch}?${untracked}"
[ -n "$ch" ] && parts="$ch"
epoch=$(git log -1 --format=%ct 2>/dev/null)
if [ -n "$epoch" ]; then
  now=$(date +%s); d=$((now - epoch))
  if [ $d -lt 60 ]; then age="${d}s"
  elif [ $d -lt 3600 ]; then age="$((d/60))m"
  elif [ $d -lt 86400 ]; then age="$((d/3600))h"
  else age="$((d/86400))d"; fi
  [ -n "$parts" ] && parts="$parts | $age" || parts="$age"
fi
printf "%s " "$parts"
SREOF
chmod +x /usr/local/bin/tgv-status-right

cat > /root/.tmux.conf << 'TMUXEOF'
set -g mouse on
set -g terminal-overrides 'xterm*:smcup@:rmcup@'
set -g history-limit 50000
set -g default-terminal "xterm-256color"
set -g default-shell /bin/zsh
set -g status-position bottom
set -g status 2
set -g status-interval 5
set -g status-style 'bg=default,fg=white'

# Line 0: border (thin line matching tgv rounded borders)
set -g status-format[0] '#[fg=brightblack,bg=default,fill=default]────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────'

# Line 1: git info
set -g status-format[1] '#[bg=default] #(tgv-status-left)#[align=right]#(tgv-status-right) '

set -g status-left ''
set -g status-right ''
set -g status-left-length 0
set -g status-right-length 0
set -g window-status-format ''
set -g window-status-current-format ''
TMUXEOF
"##;

/// Spawn a new session container on the given branch.
pub fn spawn(config: &Config, branch: &str) -> Result<String, Box<dyn std::error::Error>> {
    validate_branch(branch).map_err(|e| -> Box<dyn std::error::Error> { e.into() })?;
    let name = session_name(&config.repo.url);

    let script = format!(
        r#"#!/bin/bash
# Load OAuth token from mounted secret
if [ -f /run/secrets/claude_token ]; then
  export CLAUDE_CODE_OAUTH_TOKEN=$(cat /run/secrets/claude_token)
fi

# Pre-configure Claude Code (skip onboarding, dark theme, trust workspace)
cat > /root/.claude.json << 'CFGEOF'
{{"theme": "dark", "hasCompletedOnboarding": true}}
CFGEOF
mkdir -p /root/.claude/projects/-workspace-repo
cat > /root/.claude/projects/-workspace-repo/settings.local.json << 'SETEOF'
{{"isTrusted": true}}
SETEOF

# Git identity
{git_config}

{tmux_setup}

cd /workspace/repo
git checkout -b {branch} 2>/dev/null || git checkout {branch} 2>&1
exec sleep infinity
"#,
        git_config = if !config.git.name.is_empty() && !config.git.email.is_empty() {
            format!(
                "git config --global user.name '{}'\ngit config --global user.email '{}'",
                config.git.name.replace('\'', "'\\''"),
                config.git.email.replace('\'', "'\\''"),
            )
        } else {
            String::new()
        },
        tmux_setup = TMUX_SETUP,
    );

    ssh_run(config, "mkdir -p /tmp/tgv-scripts")?;
    ssh_run(
        config,
        &format!(
            "cat > /tmp/tgv-scripts/{name}.sh << 'SCRIPT_EOF'\n{script}SCRIPT_EOF"
        ),
    )?;
    ssh_run(config, &format!("chmod +x /tmp/tgv-scripts/{name}.sh"))?;

    // Write token to a temp file on the server (not in docker env, avoids docker inspect leak)
    ssh_run(config, &format!(
        "echo $CLAUDE_CODE_OAUTH_TOKEN > /tmp/tgv-scripts/{name}.token && chmod 600 /tmp/tgv-scripts/{name}.token"
    ))?;

    // Named volumes persist workspace and Claude state across container restarts
    // Token mounted as a file, read by entrypoint — not visible in docker inspect
    let docker_cmd = format!(
        "docker run -d \
         --name {name} \
         --network {network} \
         --label tgv.repo={repo} \
         --label tgv.branch={branch} \
         -e TERM=xterm-256color \
         -e LANG=C.UTF-8 \
         -v tgv-workspace-{name}:/workspace/repo \
         -v tgv-claude-{name}:/root/.claude \
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
        "docker exec {name} bash -c 'cd /workspace/repo 2>/dev/null || exit 0; \
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

/// Build the docker exec command to attach to a tmux window.
/// Self-bootstraps: creates session + window if needed. Race-safe.
pub fn tmux_attach_cmd(container: &str, window: &str, command: &str) -> String {
    // All inputs are validated — container from docker ps (checked in list_sessions),
    // window is hardcoded "claude", command is hardcoded "claude".
    debug_assert!(is_shell_safe(container) && is_shell_safe(window));
    format!(
        "docker exec -it {container} bash -c '\
         tmux new-session -d -s tgv -c /workspace/repo 2>/dev/null; \
         tmux select-window -t tgv:{window} 2>/dev/null || \
           {{ tmux new-window -t tgv -n {window} -c /workspace/repo && \
              tmux send-keys -t tgv:{window} \"{command}\" Enter; }}; \
         SHELL=/bin/zsh exec tmux attach-session -t tgv:{window}'"
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
