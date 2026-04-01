//! Configuration management (~/.tgv/config.toml)

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Where tgv stores its config and secrets
fn config_dir() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join(".tgv")
}

fn config_file() -> PathBuf {
    config_dir().join("config.toml")
}

/// Server connection settings
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ServerConfig {
    pub host: String,
    pub user: String,
}

/// Docker image and network settings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DockerConfig {
    #[serde(default = "default_image")]
    pub image: String,
    #[serde(default = "default_network")]
    pub network: String,
}

fn default_image() -> String {
    "tgv-session:latest".to_string()
}
fn default_network() -> String {
    "tgv-net".to_string()
}

impl Default for DockerConfig {
    fn default() -> Self {
        Self {
            image: default_image(),
            network: default_network(),
        }
    }
}

/// Git repository settings (baked into Docker image)
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct RepoConfig {
    pub url: String,
    #[serde(default = "default_branch")]
    pub default_branch: String,
}

/// Git user identity for commits inside containers
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct GitConfig {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub email: String,
}

fn default_branch() -> String {
    "main".to_string()
}

/// Top-level config
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Config {
    pub server: ServerConfig,
    pub docker: DockerConfig,
    pub repo: RepoConfig,
    #[serde(default)]
    pub git: GitConfig,
}

impl Config {
    /// SSH target string: user@host
    pub fn ssh_target(&self) -> String {
        format!("{}@{}", self.server.user, self.server.host)
    }

    /// Load config from ~/.tgv/config.toml
    pub fn load() -> Result<Self, Box<dyn std::error::Error>> {
        let path = config_file();
        if !path.exists() {
            return Err("Config not found. Run `tgv init` first.".into());
        }
        let contents = std::fs::read_to_string(&path)?;
        let config: Config = toml::from_str(&contents)?;
        // Validate config values that end up in shell commands
        let safe = |s: &str| !s.is_empty() && s.len() < 256
            && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | ':'));
        if !safe(&config.docker.image) {
            return Err(format!("Invalid docker.image: {}", config.docker.image).into());
        }
        if !safe(&config.docker.network) {
            return Err(format!("Invalid docker.network: {}", config.docker.network).into());
        }
        Ok(config)
    }

    /// Save config to ~/.tgv/config.toml
    pub fn save(&self) -> Result<(), Box<dyn std::error::Error>> {
        let dir = config_dir();
        std::fs::create_dir_all(&dir)?;
        let contents = toml::to_string_pretty(self)?;
        let path = config_file();
        std::fs::write(&path, contents)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
        Ok(())
    }
}
