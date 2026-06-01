package config

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

type Config struct {
	Host          string
	User          string
	RepoURL       string
	DockerImage   string
	DockerNetwork string
	DefaultBranch string
	GitName       string
	GitEmail      string
	// Terminal overrides where attach/shell open. Empty / "auto" → detect
	// from env ($CMUX_WORKSPACE_ID, then $TERM_PROGRAM). Recognized: "cmux"
	// (new vertical split), "terminal", "iterm", "wezterm", "ghostty".
	Terminal string
	// Connection selects the protocol used to open interactive terminal tabs.
	// "ssh" (default) or "et" (Eternal Terminal — preserves scrollback on reconnect).
	Connection string
}

type tomlShape struct {
	Server struct {
		Host string `toml:"host"`
		User string `toml:"user"`
	} `toml:"server"`
	Docker struct {
		Image   string `toml:"image"`
		Network string `toml:"network"`
	} `toml:"docker"`
	Repo struct {
		URL           string `toml:"url"`
		DefaultBranch string `toml:"default_branch"`
	} `toml:"repo"`
	Git struct {
		Name  string `toml:"name"`
		Email string `toml:"email"`
	} `toml:"git"`
	UI struct {
		Terminal   string `toml:"terminal"`
		Connection string `toml:"connection"`
	} `toml:"ui"`
}

func Path() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".tgv", "config.toml")
}

func Load() (*Config, error) {
	p := Path()
	data, err := os.ReadFile(p)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", p, err)
	}
	var t tomlShape
	if _, err := toml.Decode(string(data), &t); err != nil {
		return nil, fmt.Errorf("parse %s: %w", p, err)
	}
	if t.Server.Host == "" || t.Server.User == "" {
		return nil, fmt.Errorf("config missing server.host / server.user — run tgv-init")
	}
	c := &Config{
		Host:          t.Server.Host,
		User:          t.Server.User,
		RepoURL:       t.Repo.URL,
		DockerImage:   t.Docker.Image,
		DockerNetwork: t.Docker.Network,
		DefaultBranch: t.Repo.DefaultBranch,
		GitName:       t.Git.Name,
		GitEmail:      t.Git.Email,
		Terminal:      t.UI.Terminal,
		Connection:    t.UI.Connection,
	}
	if c.DockerImage == "" {
		c.DockerImage = "tgv-session:latest"
	}
	if c.DockerNetwork == "" {
		c.DockerNetwork = "tgv-net"
	}
	if c.DefaultBranch == "" {
		c.DefaultBranch = "main"
	}
	return c, nil
}

func (c *Config) SSHTarget() string {
	return fmt.Sprintf("%s@%s", c.User, c.Host)
}
