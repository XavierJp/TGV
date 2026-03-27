//! Configuration management (~/.tgv/config.toml)

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Where tgv stores its config and secrets
fn config_dir() -> PathBuf {
    dirs::home_dir().unwrap().join(".tgv")
}

pub fn config_file() -> PathBuf {
    config_dir().join("config.toml")
}

/// Server connection settings
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ServerConfig {
    pub host: String,
    pub user: String,
    #[serde(default = "default_et_port")]
    pub et_port: u16,
}

fn default_et_port() -> u16 {
    2022
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

fn default_branch() -> String {
    "main".to_string()
}

/// Top-level config
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Config {
    pub server: ServerConfig,
    pub docker: DockerConfig,
    pub repo: RepoConfig,
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
        Ok(config)
    }

    /// Save config to ~/.tgv/config.toml
    pub fn save(&self) -> Result<(), Box<dyn std::error::Error>> {
        let dir = config_dir();
        std::fs::create_dir_all(&dir)?;
        let contents = toml::to_string_pretty(self)?;
        std::fs::write(config_file(), contents)?;
        Ok(())
    }
}
