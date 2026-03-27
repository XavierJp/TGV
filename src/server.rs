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
    let dir = std::env::temp_dir().join("tgv-ssh");
    std::fs::create_dir_all(&dir).ok();
    dir.join(format!("{}", config.ssh_target()))
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
