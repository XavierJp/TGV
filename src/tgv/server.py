"""SSH command execution on remote server."""

from __future__ import annotations

import subprocess
from dataclasses import dataclass

from tgv.config import Config


@dataclass
class CommandResult:
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0


def ssh_run(config: Config, command: str, check: bool = False) -> CommandResult:
    """Run a command on the remote server via SSH."""
    ssh_cmd = [
        "ssh",
        "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=accept-new",
        config.ssh_target,
        command,
    ]
    result = subprocess.run(ssh_cmd, capture_output=True, text=True)
    cmd_result = CommandResult(
        returncode=result.returncode,
        stdout=result.stdout.strip(),
        stderr=result.stderr.strip(),
    )
    if check and not cmd_result.ok:
        raise RuntimeError(f"SSH command failed: {command}\n{cmd_result.stderr}")
    return cmd_result


def ssh_exec(config: Config, command: str) -> None:
    """Replace current process with an SSH/ET session (interactive)."""
    import os
    os.execvp("et", [
        "et",
        f"-p {config.server.et_port}",
        config.ssh_target,
        "-c", command,
    ])


def scp_to(config: Config, local_path: str, remote_path: str) -> CommandResult:
    """Copy a file to the remote server."""
    scp_cmd = [
        "scp",
        "-o", "ConnectTimeout=10",
        local_path,
        f"{config.ssh_target}:{remote_path}",
    ]
    result = subprocess.run(scp_cmd, capture_output=True, text=True)
    return CommandResult(
        returncode=result.returncode,
        stdout=result.stdout.strip(),
        stderr=result.stderr.strip(),
    )
