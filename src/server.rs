//! SSH command execution on remote server
//!
//! Uses ControlMaster multiplexing so only the first connection pays the
//! TCP+SSH handshake cost. All subsequent commands reuse the socket.

use crate::config::Config;
use std::path::PathBuf;
use std::process::Command;

/// Result of a remote SSH command
pub struct CmdResult {
    pub success: bool,
    pub stdout: String,
    pub stderr: String,
}

/// Path to the ControlMaster socket for a given target
fn control_path(config: &Config) -> PathBuf {
    // macOS limits Unix socket paths to 104 chars — keep it short
    let dir = PathBuf::from("/tmp/tgv-s");
    if let Ok(()) = std::fs::create_dir_all(&dir) {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        }
    }
    // Use a short hash of the target instead of the full user@host string
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    config.ssh_target().hash(&mut h);
    dir.join(format!("{:x}", h.finish()))
}

/// Common SSH args including multiplexing options
fn ssh_mux_args(config: &Config) -> Vec<String> {
    let cp = control_path(config);
    vec![
        "-o".into(), "ConnectTimeout=10".into(),
        "-o".into(), "StrictHostKeyChecking=accept-new".into(),
        "-o".into(), format!("ControlPath={}", cp.display()),
        "-o".into(), "ControlMaster=auto".into(),
        "-o".into(), "ControlPersist=600".into(),
        "-o".into(), "ServerAliveInterval=5".into(),
        "-o".into(), "ServerAliveCountMax=3".into(),
    ]
}

/// Run a command on the remote server via SSH
pub fn ssh_run(config: &Config, command: &str) -> Result<CmdResult, Box<dyn std::error::Error>> {
    let mut args = ssh_mux_args(config);
    args.push(config.ssh_target());
    args.push(command.to_string());

    let output = Command::new("ssh")
        .args(&args)
        .output()?;

    Ok(CmdResult {
        success: output.status.success(),
        stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
    })
}

/// Copy a local file to the remote server
pub fn scp_to(
    config: &Config,
    local_path: &str,
    remote_path: &str,
) -> Result<CmdResult, Box<dyn std::error::Error>> {
    let cp = control_path(config);
    let output = Command::new("scp")
        .args([
            "-o", "ConnectTimeout=10",
            "-o", &format!("ControlPath={}", cp.display()),
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=600",
            local_path,
            &format!("{}:{}", config.ssh_target(), remote_path),
        ])
        .output()?;

    Ok(CmdResult {
        success: output.status.success(),
        stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
    })
}

/// Write a string to a remote file via stdin (never on command line)
pub fn scp_string_to(
    config: &Config,
    content: &str,
    remote_path: &str,
    mode: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Write;
    let mut args = ssh_mux_args(config);
    args.push(config.ssh_target());
    args.push(format!("cat > {remote_path} && chmod {mode} {remote_path}"));

    let mut child = Command::new("ssh")
        .args(&args)
        .stdin(std::process::Stdio::piped())
        .spawn()?;

    if let Some(ref mut stdin) = child.stdin {
        stdin.write_all(content.as_bytes())?;
    }
    drop(child.stdin.take());

    let status = child.wait()?;
    if !status.success() {
        return Err(format!("Failed to write to {remote_path}").into());
    }
    Ok(())
}

/// Fast SSH ping with a short 3s timeout (reuses ControlMaster if available)
pub fn ssh_ping(config: &Config) -> Result<CmdResult, Box<dyn std::error::Error>> {
    let cp = control_path(config);
    let output = Command::new("ssh")
        .args([
            "-o", "ConnectTimeout=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", &format!("ControlPath={}", cp.display()),
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=600",
            &config.ssh_target(),
            "true",
        ])
        .output()?;

    Ok(CmdResult {
        success: output.status.success(),
        stdout: String::new(),
        stderr: String::new(),
    })
}

/// Tear down the ControlMaster socket (call on exit)
pub fn close_mux(config: &Config) {
    let cp = control_path(config);
    let _ = Command::new("ssh")
        .args([
            "-o", &format!("ControlPath={}", cp.display()),
            "-O", "exit",
            &config.ssh_target(),
        ])
        .output();
}
