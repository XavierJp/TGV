//! Docker container session management on remote server

use crate::config::Config;
use crate::server::ssh_run;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::time::{SystemTime, UNIX_EPOCH};

/// A running or exited tgv session
#[derive(Debug, Clone)]
pub struct Session {
    pub name: String,
    pub repo: String,
    pub branch: String,
    pub status: String, // "running" or "exited"
    pub created: String,
}

/// Generate a short unique session name
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

    format!("{}-{}", repo, &hash[..4])
}

/// Spawn a new session container. Repo + deps are already in the image.
pub fn spawn(config: &Config) -> Result<String, Box<dyn std::error::Error>> {
    let name = session_name(&config.repo.url);
    let branch = &config.repo.default_branch;

    // Write entrypoint script on server (avoids quoting issues)
    let script = format!(
        "#!/bin/bash\ncd /workspace/repo\ngit checkout {branch} 2>&1\nexec sleep infinity\n"
    );

    ssh_run(config, "mkdir -p /tmp/tgv-scripts")?;
    ssh_run(
        config,
        &format!(
            "cat > /tmp/tgv-scripts/{name}.sh << 'SCRIPT_EOF'\n{script}SCRIPT_EOF"
        ),
    )?;
    ssh_run(config, &format!("chmod +x /tmp/tgv-scripts/{name}.sh"))?;

    let docker_cmd = format!(
        "docker run -d \
         --name {name} \
         --network {network} \
         --label tgv.repo={repo} \
         --label tgv.branch={branch} \
         -e CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN \
         -v /tmp/tgv-scripts/{name}.sh:/entrypoint.sh:ro \
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
        if parts.len() >= 4 {
            let status = if parts[3].contains("Up") {
                "running"
            } else {
                "exited"
            };

            // Extract short repo name from URL
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
                created: parts[3].to_string(),
            });
        }
    }
    Ok(sessions)
}

/// Stop and remove a session container
pub fn stop(config: &Config, name: &str) -> Result<(), Box<dyn std::error::Error>> {
    ssh_run(config, &format!("docker rm -f {name}"))?;
    ssh_run(config, &format!("rm -f /tmp/tgv-scripts/{name}.sh"))?;
    Ok(())
}

/// Get container logs
pub fn logs(config: &Config, name: &str) -> Result<String, Box<dyn std::error::Error>> {
    let result = ssh_run(config, &format!("docker logs --tail 100 {name}"))?;
    Ok(if result.stdout.is_empty() {
        result.stderr
    } else {
        result.stdout
    })
}
