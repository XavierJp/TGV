package main

import (
	"context"
	"fmt"
	"os"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/XavierJp/TGV/internal/config"
	"github.com/XavierJp/TGV/internal/session"
	"github.com/XavierJp/TGV/internal/sshx"
	"github.com/XavierJp/TGV/internal/ui"
)

func main() {
	if len(os.Args) >= 2 {
		switch os.Args[1] {
		case "ls":
			runList()
			return
		case "-h", "--help", "help":
			printHelp()
			return
		case "-v", "--version", "version":
			fmt.Println("tgv (dev)")
			return
		}
	}
	runTUI()
}

func printHelp() {
	fmt.Println(`usage: tgv [command]

Commands:
  (default)  Launch the session TUI
  ls         List sessions once and exit (debug; no TUI)
  help       Show this help
  version    Show version`)
}

func loadConfigOrDie() *config.Config {
	cfg, err := config.Load()
	if err != nil {
		fmt.Fprintln(os.Stderr, "tgv: config error:", err)
		fmt.Fprintln(os.Stderr, "run `tgv-init --host user@ip --repo <url>` first")
		os.Exit(1)
	}
	return cfg
}

func runTUI() {
	cfg := loadConfigOrDie()

	ssh := sshx.New(cfg.Host, 22, cfg.User)
	defer ssh.Close()

	manager := session.NewManager(ssh, cfg)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	store := session.NewStore(manager, cfg.RepoURL)
	store.Start(ctx)
	defer store.Stop()

	model := ui.NewApp(ctx, store, manager, cfg)
	prog := tea.NewProgram(model, tea.WithAltScreen())

	if _, err := prog.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "tgv: tui error:", err)
		os.Exit(1)
	}
}

// runList is a debug helper — prints sessions once, no TUI. Useful for
// smoke-testing the SSH path without needing a TTY.
func runList() {
	cfg := loadConfigOrDie()

	ssh := sshx.New(cfg.Host, 22, cfg.User)
	defer ssh.Close()

	manager := session.NewManager(ssh, cfg)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	sessions, err := manager.ListSessions(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, "tgv ls:", err)
		os.Exit(1)
	}
	if len(sessions) == 0 {
		fmt.Println("(no sessions)")
		return
	}
	for _, s := range sessions {
		state := "stopped"
		if s.Running {
			state = "running"
		}
		fmt.Printf("%-10s %-40s %s\n", state, s.Name, s.Label())
	}
}
