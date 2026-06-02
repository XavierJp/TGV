package term

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// OpenInNewTab runs `cmd` in a new terminal tab/window/split. `override`
// forces a specific terminal — case-insensitive: "cmux", "iterm", "terminal",
// "wezterm", "ghostty", or "" / "auto" to detect from env. Detection prefers
// $CMUX_WORKSPACE_ID over $TERM_PROGRAM so cmux wins even though it sets
// TERM_PROGRAM=ghostty. Unknown / failed detection falls back to Terminal.app.
//
// Returns a label describing which path was taken.
func OpenInNewTab(cmd, override string) (string, error) {
	choice := strings.ToLower(strings.TrimSpace(override))
	if choice == "" || choice == "auto" {
		choice = detectFromEnv()
	}

	switch choice {
	case "cmux":
		if err := openCmux(cmd); err == nil {
			return "cmux", nil
		}
	case "iterm", "iterm2":
		if err := openITerm(cmd); err == nil {
			return "iTerm", nil
		}
	case "wezterm":
		if err := openWezTerm(cmd); err == nil {
			return "WezTerm", nil
		}
	case "ghostty":
		// No stable CLI yet — falls through to Terminal.app.
	case "terminal", "apple_terminal":
		// Handled below.
	}
	if err := openAppleTerminal(cmd); err != nil {
		return "", err
	}
	return "Terminal.app", nil
}

func detectFromEnv() string {
	// cmux sets TERM_PROGRAM=ghostty, so check its own marker first.
	if os.Getenv("CMUX_WORKSPACE_ID") != "" {
		return "cmux"
	}
	switch os.Getenv("TERM_PROGRAM") {
	case "iTerm.app":
		return "iterm"
	case "WezTerm":
		return "wezterm"
	case "ghostty":
		return "ghostty"
	case "Apple_Terminal":
		return "terminal"
	}
	return "terminal"
}

func openAppleTerminal(cmd string) error {
	script := fmt.Sprintf(`tell application "Terminal"
	activate
	do script %q
end tell`, cmd)
	return exec.Command("osascript", "-e", script).Run()
}

func openITerm(cmd string) error {
	script := fmt.Sprintf(`tell application "iTerm"
	activate
	if (count of windows) = 0 then
		create window with default profile
		tell current session of current window to write text %q
	else
		tell current window
			set newTab to (create tab with default profile)
			tell current session of newTab to write text %q
		end tell
	end if
end tell`, cmd, cmd)
	return exec.Command("osascript", "-e", script).Run()
}

func openWezTerm(cmd string) error {
	// wezterm cli spawn runs a program in a new tab. `bash -lc <cmd>` keeps
	// the semantics matching the other terminals (login shell, PATH loaded).
	return exec.Command("wezterm", "cli", "spawn", "--", "bash", "-lc", cmd).Run()
}

// openCmux runs `cmd` in a new cmux surface ("tab") stacked inside TGV's
// dedicated right-side pane for the current cmux workspace. The pane's UUID
// is persisted in ~/.tgv/cmux-pane-<workspace-uuid>: first call (or if the
// remembered pane is gone) creates it via `new-pane --direction right`;
// subsequent calls add a surface via `new-surface --pane <uuid>` and focus it.
// Both cmux subcommands return `OK <surface-uuid> <pane-uuid> <workspace-uuid>`.
func openCmux(cmd string) error {
	ws := os.Getenv("CMUX_WORKSPACE_ID")
	if ws == "" {
		return fmt.Errorf("cmux: $CMUX_WORKSPACE_ID not set")
	}

	pane := readCmuxPaneState(ws)
	if pane != "" && !cmuxPaneAlive(pane) {
		pane = ""
	}

	var surface string
	var err error
	if pane != "" {
		surface, _, err = cmuxNewSurface("--id-format", "uuids", "new-surface", "--pane", pane)
	} else {
		surface, pane, err = cmuxNewSurface("--id-format", "uuids", "new-pane", "--direction", "right")
		if err == nil {
			_ = writeCmuxPaneState(ws, pane)
		}
	}
	if err != nil {
		return err
	}

	if err := exec.Command("cmux", "send", "--surface", surface, cmd).Run(); err != nil {
		return err
	}
	if err := exec.Command("cmux", "send-key", "--surface", surface, "enter").Run(); err != nil {
		return err
	}
	// New surfaces are auto-selected within their pane, so focusing the pane
	// is enough — there is no `focus-surface` CLI command.
	return exec.Command("cmux", "focus-pane", "--pane", pane).Run()
}

// cmuxNewSurface runs a cmux surface-creating subcommand and parses its
// `OK <surface> <pane> <workspace>` ack into (surface, pane).
func cmuxNewSurface(args ...string) (surface, pane string, err error) {
	out, err := exec.Command("cmux", args...).Output()
	if err != nil {
		return "", "", err
	}
	fields := strings.Fields(string(out))
	if len(fields) < 4 || fields[0] != "OK" {
		return "", "", fmt.Errorf("cmux: unexpected output %q", string(out))
	}
	return fields[1], fields[2], nil
}

func cmuxPaneAlive(pane string) bool {
	return exec.Command("cmux", "list-pane-surfaces", "--pane", pane).Run() == nil
}

func cmuxStatePath(workspace string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, ".tgv")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return filepath.Join(dir, "cmux-pane-"+workspace), nil
}

func readCmuxPaneState(workspace string) string {
	p, err := cmuxStatePath(workspace)
	if err != nil {
		return ""
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func writeCmuxPaneState(workspace, pane string) error {
	p, err := cmuxStatePath(workspace)
	if err != nil {
		return err
	}
	return os.WriteFile(p, []byte(pane), 0o600)
}
