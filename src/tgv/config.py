"""Configuration management for tgv (~/.tgv/config.toml)."""

from __future__ import annotations

import sys
from pathlib import Path
from dataclasses import dataclass, field

if sys.version_info >= (3, 11):
    import tomllib
else:
    import tomli as tomllib

import tomli_w


CONFIG_DIR = Path.home() / ".tgv"
CONFIG_FILE = CONFIG_DIR / "config.toml"

ALLOWED_DOMAINS = [
    "api.anthropic.com",
    "github.com",
    "*.githubusercontent.com",
    "registry.npmjs.org",
]


@dataclass
class ServerConfig:
    host: str = ""
    user: str = ""
    et_port: int = 2022


@dataclass
class RepoConfig:
    url: str = ""
    default_branch: str = "main"


@dataclass
class DockerConfig:
    image: str = "tgv-session:latest"
    network: str = "tgv-net"
    allowed_domains: list[str] = field(default_factory=lambda: list(ALLOWED_DOMAINS))


@dataclass
class Config:
    server: ServerConfig = field(default_factory=ServerConfig)
    docker: DockerConfig = field(default_factory=DockerConfig)
    repo: RepoConfig = field(default_factory=RepoConfig)
    oauth_token: str = ""

    def save(self) -> None:
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        data = {
            "server": {
                "host": self.server.host,
                "user": self.server.user,
                "et_port": self.server.et_port,
            },
            "docker": {
                "image": self.docker.image,
                "network": self.docker.network,
                "allowed_domains": self.docker.allowed_domains,
            },
            "repo": {
                "url": self.repo.url,
                "default_branch": self.repo.default_branch,
            },
        }
        CONFIG_FILE.write_bytes(tomli_w.dumps(data).encode())
        # Store OAuth token separately with restricted permissions
        token_file = CONFIG_DIR / "oauth_token"
        if self.oauth_token:
            token_file.write_text(self.oauth_token)
            token_file.chmod(0o600)

    @classmethod
    def load(cls) -> Config:
        if not CONFIG_FILE.exists():
            return cls()
        data = tomllib.loads(CONFIG_FILE.read_text())
        server = ServerConfig(**data.get("server", {}))
        docker = DockerConfig(**data.get("docker", {}))
        repo = RepoConfig(**data.get("repo", {}))
        # Load OAuth token from separate file
        token_file = CONFIG_DIR / "oauth_token"
        oauth_token = token_file.read_text().strip() if token_file.exists() else ""
        return cls(server=server, docker=docker, repo=repo, oauth_token=oauth_token)

    @property
    def ssh_target(self) -> str:
        return f"{self.server.user}@{self.server.host}"
