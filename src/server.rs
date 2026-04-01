//! SSH command execution on remote server
//!
//! Uses ControlMaster multiplexing so only the first connection pays the
//! TCP+SSH handshake cost. All subsequent commands reuse the socket.

use crate::config::Config;
use std::path::PathBuf;
use std::process::Command;
use std::time::Instant;

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

/// Log SSH timing if TGV_DEBUG is set
fn log_ssh(label: &str, cmd: &str, elapsed: std::time::Duration, result: &CmdResult) {
    if std::env::var("TGV_DEBUG").is_ok() {
        let status = if result.success { "ok" } else { "FAIL" };
        let ms = elapsed.as_millis();
        let short_cmd: String = cmd.chars().take(80).collect();
        eprintln!("[tgv {ms:>5}ms {status}] {label}: {short_cmd}");
        if !result.success && !result.stderr.is_empty() {
            let stderr_short: String = result.stderr.chars().take(200).collect();
            eprintln!("[tgv stderr] {stderr_short}");
        }
    }
}

/// Run a command on the remote server via SSH
pub fn ssh_run(config: &Config, command: &str) -> Result<CmdResult, Box<dyn std::error::Error>> {
    let mut args = ssh_mux_args(config);
    args.push(config.ssh_target());
    args.push(command.to_string());

    let start = Instant::now();
    let output = Command::new("ssh")
        .args(&args)
        .output()?;

    let result = CmdResult {
        success: output.status.success(),
        stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
    };
    log_ssh("ssh_run", command, start.elapsed(), &result);
    Ok(result)
}

/// Copy a local file to the remote server
pub fn scp_to(
    config: &Config,
    local_path: &str,
    remote_path: &str,
) -> Result<CmdResult, Box<dyn std::error::Error>> {
    let cp = control_path(config);
    let start = Instant::now();
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

    let result = CmdResult {
        success: output.status.success(),
        stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
    };
    log_ssh("scp_to", remote_path, start.elapsed(), &result);
    Ok(result)
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

/// Run a remote command, feeding data to its stdin (avoids heredoc quoting issues)
pub fn ssh_write_stdin(
    config: &Config,
    command: &str,
    data: &[u8],
) -> Result<CmdResult, Box<dyn std::error::Error>> {
    use std::io::Write;
    let mut args = ssh_mux_args(config);
    args.push(config.ssh_target());
    args.push(command.to_string());

    let start = Instant::now();
    let mut child = Command::new("ssh")
        .args(&args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()?;

    // Write data and close stdin immediately so remote command gets EOF
    {
        let stdin = child.stdin.take().expect("stdin was piped");
        let mut writer = std::io::BufWriter::new(stdin);
        writer.write_all(data)?;
        writer.flush()?;
        // stdin drops here, closing the pipe → remote cat gets EOF
    }

    let output = child.wait_with_output()?;
    let result = CmdResult {
        success: output.status.success(),
        stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
    };
    log_ssh("ssh_stdin", command, start.elapsed(), &result);
    Ok(result)
}

