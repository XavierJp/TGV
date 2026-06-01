package session

import (
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	mathrand "math/rand"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/XavierJp/TGV/internal/config"
	"github.com/XavierJp/TGV/internal/sshx"
)

// Session is a DTO for docker ps output — no client-side state.
type Session struct {
	Name        string
	Repo        string // short form e.g. "org/repo"
	Branch      string
	Running     bool
	DisplayName string
}

func (s Session) Label() string {
	if s.DisplayName != "" {
		return fmt.Sprintf("%s (%s)", s.DisplayName, s.Branch)
	}
	return s.Branch
}

type Manager struct {
	ssh *sshx.Manager
	cfg *config.Config

	mu             sync.Mutex
	cachedBranches []string
	cachedAt       time.Time
}

const branchesTTL = 30 * time.Second

func NewManager(ssh *sshx.Manager, cfg *config.Config) *Manager {
	return &Manager{ssh: ssh, cfg: cfg}
}

func (m *Manager) Config() *config.Config { return m.cfg }

var shellSafeRe = regexp.MustCompile(`^[A-Za-z0-9_./-]+$`)

func ShellSafe(s string) bool {
	if s == "" || len(s) > 256 {
		return false
	}
	return shellSafeRe.MatchString(s)
}

// ListSessions returns all tgv-labelled containers (running + stopped).
func (m *Manager) ListSessions(ctx context.Context) ([]Session, error) {
	cmd := `docker ps -a --filter label=tgv.repo --format '{{.Names}}	{{.Label "tgv.repo"}}	{{.Label "tgv.branch"}}	{{.Status}}	{{.Label "tgv.display_name"}}'`
	r, err := m.ssh.Exec(ctx, cmd)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(r.Stdout) == "" {
		return nil, nil
	}

	names, _ := m.fetchDisplayNames(ctx)
	var out []Session
	for _, line := range strings.Split(r.Stdout, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) < 4 || !ShellSafe(parts[0]) {
			continue
		}
		name := parts[0]
		repoURL := parts[1]
		branch := parts[2]
		status := parts[3]
		labelDisplay := ""
		if len(parts) >= 5 {
			labelDisplay = strings.TrimSpace(parts[4])
		}
		displayName := labelDisplay
		if displayName == "" {
			displayName = names[name]
		}
		out = append(out, Session{
			Name:        name,
			Repo:        repoShort(repoURL),
			Branch:      branch,
			Running:     strings.Contains(status, "Up"),
			DisplayName: displayName,
		})
	}
	return out, nil
}

func (m *Manager) fetchDisplayNames(ctx context.Context) (map[string]string, error) {
	cmd := `for f in /tmp/tgv-meta/*.name; do [ -f "$f" ] && echo "$(basename "$f" .name)=$(cat "$f")"; done 2>/dev/null`
	r, err := m.ssh.Exec(ctx, cmd)
	if err != nil {
		return nil, err
	}
	out := map[string]string{}
	for _, line := range strings.Split(r.Stdout, "\n") {
		line = strings.TrimRight(line, "\r")
		if line == "" {
			continue
		}
		i := strings.IndexByte(line, '=')
		if i <= 0 {
			continue
		}
		out[line[:i]] = line[i+1:]
	}
	return out, nil
}

func repoShort(repoURL string) string {
	s := strings.Trim(repoURL, "/")
	parts := strings.Split(s, "/")
	if len(parts) == 0 || parts[0] == "" {
		return ""
	}
	last := strings.TrimSuffix(parts[len(parts)-1], ".git")
	if len(parts) >= 2 {
		return parts[len(parts)-2] + "/" + last
	}
	return last
}

// ListBranches returns remote branches from the baked-in image, cached 30s.
func (m *Manager) ListBranches(ctx context.Context) ([]string, error) {
	m.mu.Lock()
	if m.cachedBranches != nil && time.Since(m.cachedAt) < branchesTTL {
		b := m.cachedBranches
		m.mu.Unlock()
		return b, nil
	}
	m.mu.Unlock()

	cmd := fmt.Sprintf("docker run --rm %s bash -c 'cd /workspace/repo 2>/dev/null && git branch -r 2>/dev/null'", m.cfg.DockerImage)
	r, err := m.ssh.Exec(ctx, cmd)
	if err != nil {
		return nil, err
	}
	var branches []string
	for _, line := range strings.Split(r.Stdout, "\n") {
		t := strings.TrimSpace(line)
		if t == "" || strings.Contains(t, "->") {
			continue
		}
		if strings.HasPrefix(t, "origin/") {
			branches = append(branches, strings.TrimPrefix(t, "origin/"))
		}
	}
	m.mu.Lock()
	m.cachedBranches = branches
	m.cachedAt = time.Now()
	m.mu.Unlock()
	return branches, nil
}

// Spawn creates a new session container. `onStep` receives human-readable
// progress strings (nil-safe). The name must come from MakeSessionName so
// the client-side store can show a row before this returns.
func (m *Manager) Spawn(ctx context.Context, name, branch, prompt string, onStep func(string)) error {
	if onStep == nil {
		onStep = func(string) {}
	}
	if !ShellSafe(name) {
		return fmt.Errorf("invalid container name: %s", name)
	}
	if !ShellSafe(branch) {
		return fmt.Errorf("invalid branch: %s", branch)
	}

	script := m.entrypointScript(branch)

	onStep("Preparing entrypoint")
	if _, err := m.ssh.Exec(ctx, "mkdir -p /tmp/tgv-scripts && chmod 700 /tmp/tgv-scripts"); err != nil {
		return err
	}
	if _, err := m.ssh.Exec(ctx, "mkdir -p /tmp/tgv-meta && chmod 700 /tmp/tgv-meta"); err != nil {
		return err
	}
	if err := m.ssh.WriteFile(ctx, "/tmp/tgv-scripts/"+name+".sh", []byte(script), 0o700); err != nil {
		return err
	}

	onStep("Configuring credentials")
	if token := localGHToken(); token != "" {
		if err := m.ssh.WriteFile(ctx, "/tmp/tgv-scripts/"+name+".gh", []byte(token), 0o600); err != nil {
			onStep(fmt.Sprintf("Warning: gh token copy failed — %v", err))
		}
	} else {
		// Empty file so the read-only bind mount still has a target.
		_ = m.ssh.WriteFile(ctx, "/tmp/tgv-scripts/"+name+".gh", nil, 0o600)
	}

	if prompt != "" {
		onStep("Recording prompt")
		if err := m.ssh.WriteFile(ctx, "/tmp/tgv-scripts/"+name+".prompt", []byte(prompt), 0o644); err != nil {
			return err
		}
	} else {
		_ = m.ssh.WriteFile(ctx, "/tmp/tgv-scripts/"+name+".prompt", nil, 0o644)
	}

	onStep("Starting container")
	dockerCmd := strings.Join([]string{
		"docker run -d",
		"--name " + name,
		"--user root",
		"--network " + m.cfg.DockerNetwork,
		"--label tgv.repo=" + m.cfg.RepoURL,
		"--label tgv.branch=" + branch,
		"-e TERM=xterm-256color",
		"-e COLORTERM=truecolor",
		"-e LANG=C.UTF-8",
		"-v tgv-codex-auth:/mnt/codex",
		"-v /tmp/tgv-scripts/" + name + ".sh:/entrypoint.sh:ro",
		"-v /tmp/tgv-scripts/" + name + ".gh:/run/secrets/gh_token:ro",
		"-v /tmp/tgv-scripts/" + name + ".prompt:/run/secrets/codex_prompt:ro",
		m.cfg.DockerImage,
		"bash /entrypoint.sh",
	}, " ")
	r, err := m.ssh.Exec(ctx, dockerCmd)
	if err != nil {
		return err
	}
	if !r.Success() {
		return fmt.Errorf("spawn failed: %s", strings.TrimSpace(r.Stderr))
	}
	return nil
}

func (m *Manager) Stop(ctx context.Context, name string) error {
	if !ShellSafe(name) {
		return fmt.Errorf("invalid container name: %s", name)
	}
	_, _ = m.ssh.Exec(ctx, "docker rm -f "+name)
	// Best-effort cleanup for old volume-based sessions.
	_, _ = m.ssh.Exec(ctx, "docker volume rm -f tgv-workspace-"+name)
	_, _ = m.ssh.Exec(ctx, fmt.Sprintf(
		"rm -f /tmp/tgv-scripts/%s.sh /tmp/tgv-scripts/%s.gh /tmp/tgv-scripts/%s.prompt /tmp/tgv-meta/%s.name",
		name, name, name, name,
	))
	return nil
}

func (m *Manager) Rename(ctx context.Context, name, displayName string) error {
	if !ShellSafe(name) {
		return fmt.Errorf("invalid container name: %s", name)
	}
	safe := strings.ReplaceAll(displayName, "'", `'\''`)
	_, err := m.ssh.Exec(ctx, fmt.Sprintf("mkdir -p /tmp/tgv-meta && echo '%s' > /tmp/tgv-meta/%s.name", safe, name))
	return err
}

// GitMetrics returns insertion/deletion counts across working tree + index.
func (m *Manager) GitMetrics(ctx context.Context, name string) (ins, del int, err error) {
	if !ShellSafe(name) {
		return 0, 0, fmt.Errorf("invalid container name: %s", name)
	}
	cmd := fmt.Sprintf(`docker exec -u dev %s bash -c 'cd /workspace/repo 2>/dev/null || exit 0; git diff --numstat 2>/dev/null; git diff --cached --numstat 2>/dev/null'`, name)
	r, err := m.ssh.Exec(ctx, cmd)
	if err != nil {
		return 0, 0, err
	}
	for _, line := range strings.Split(r.Stdout, "\n") {
		parts := strings.Split(line, "\t")
		if len(parts) < 2 {
			continue
		}
		var added, removed int
		fmt.Sscanf(parts[0], "%d", &added)
		fmt.Sscanf(parts[1], "%d", &removed)
		ins += added
		del += removed
	}
	return ins, del, nil
}

func (m *Manager) GitStatusRaw(ctx context.Context, container string) (string, error) {
	if !ShellSafe(container) {
		return "", fmt.Errorf("invalid container name: %s", container)
	}
	r, err := m.ssh.Exec(ctx, fmt.Sprintf("docker exec -u dev -w /workspace/repo %s git status --porcelain=v1 -b 2>/dev/null", container))
	if err != nil {
		return "", err
	}
	return r.Stdout, nil
}

// PRInfo is a single PR summary from `gh pr list`.
type PRInfo struct {
	Number int    `json:"number"`
	URL    string `json:"url"`
	Title  string `json:"title"`
	State  string `json:"state"`
}

// PRForBranch asks gh (inside the container, where the token already lives)
// for any PR on the given branch. Returns (nil, nil) when no PR matches.
func (m *Manager) PRForBranch(ctx context.Context, container, branch string) (*PRInfo, error) {
	if !ShellSafe(container) || !ShellSafe(branch) {
		return nil, fmt.Errorf("invalid arg")
	}
	cmd := fmt.Sprintf(`docker exec -u dev -w /workspace/repo %s gh pr list --head %s --state all --limit 1 --json number,url,title,state 2>/dev/null`, container, branch)
	r, err := m.ssh.Exec(ctx, cmd)
	if err != nil {
		return nil, err
	}
	out := strings.TrimSpace(r.Stdout)
	if out == "" || out == "[]" {
		return nil, nil
	}
	var list []PRInfo
	if err := json.Unmarshal([]byte(out), &list); err != nil {
		return nil, nil // gh output garbled / gh missing — treat as no PR
	}
	if len(list) == 0 {
		return nil, nil
	}
	return &list[0], nil
}

// AttachArgs returns the docker exec argv that re-attaches to the session's
// codex via abduco. Waits on /tmp/tgv-ready so it doesn't race the entrypoint.
func (m *Manager) AttachArgs(container string) []string {
	return []string{
		"docker", "exec", "-u", "dev", "-it",
		"-e", "COLORTERM=truecolor",
		"-w", "/workspace/repo", container,
		"bash", "-lc",
		"until [ -e /tmp/tgv-ready ]; do sleep 0.2; done; exec abduco -e '^q' -A tgv /usr/local/bin/tgv-codex",
	}
}

// ShellArgs returns the docker exec argv for a plain zsh in the workspace.
func (m *Manager) ShellArgs(container string) []string {
	return []string{
		"docker", "exec", "-u", "dev", "-it",
		"-e", "COLORTERM=truecolor",
		"-w", "/workspace/repo", container,
		"bash", "-lc",
		"until [ -e /tmp/tgv-ready ]; do sleep 0.2; done; exec zsh",
	}
}

// RemoteSSHCommand wraps the given remote argv in an `ssh -t` invocation.
func (m *Manager) RemoteSSHCommand(argv []string) string {
	inner := joinShellCommand(argv)
	return fmt.Sprintf("ssh -t %s %s", m.cfg.SSHTarget(), shellEscape(inner))
}

// RemoteETCommand wraps the given remote argv in an `et -c` invocation.
// ET preserves terminal scrollback across reconnects, which matters when
// codex runs in --no-alt-screen mode and its output lives in the buffer.
func (m *Manager) RemoteETCommand(argv []string) string {
	inner := joinShellCommand(argv)
	return fmt.Sprintf("et %s -c %s", m.cfg.SSHTarget(), shellEscape(inner))
}

// RemoteCommand returns either an SSH or ET command depending on config.
func (m *Manager) RemoteCommand(argv []string) string {
	if m.cfg.Connection == "et" {
		return m.RemoteETCommand(argv)
	}
	return m.RemoteSSHCommand(argv)
}

func joinShellCommand(argv []string) string {
	out := make([]string, len(argv))
	for i, a := range argv {
		out[i] = shellEscape(a)
	}
	return strings.Join(out, " ")
}

// MakeSessionName returns a container name like "myrepo-3f8a9b21".
func MakeSessionName(repoURL string) string {
	cleaned := strings.Trim(repoURL, "/")
	parts := strings.Split(cleaned, "/")
	last := "session"
	if len(parts) > 0 && parts[len(parts)-1] != "" {
		last = parts[len(parts)-1]
	}
	last = strings.TrimSuffix(last, ".git")

	h := fnv.New64a()
	h.Write([]byte(repoURL))
	h.Write([]byte(fmt.Sprintf("%d", time.Now().UnixNano())))
	return fmt.Sprintf("%s-%08x", last, uint32(h.Sum64()))
}

// BranchFromTitle slugifies a user title into "tgv/add-dark-mode-a3b2".
func BranchFromTitle(title string) string {
	lower := strings.ToLower(title)
	var out []rune
	lastDash := true
	for _, ch := range lower {
		if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') {
			out = append(out, ch)
			lastDash = false
		} else if !lastDash {
			out = append(out, '-')
			lastDash = true
		}
	}
	slug := strings.TrimRight(string(out), "-")
	if len(slug) > 40 {
		slug = strings.TrimRight(slug[:40], "-")
	}
	if slug == "" {
		return RandomBranchName()
	}
	h := fnv.New64a()
	h.Write([]byte(fmt.Sprintf("%d", time.Now().UnixNano())))
	h.Write([]byte(title))
	hex := fmt.Sprintf("%x", h.Sum64()&0xFFFF)
	return fmt.Sprintf("tgv/%s-%s", slug, hex)
}

func RandomBranchName() string {
	adj := []string{"swift", "bright", "calm", "bold", "keen", "warm", "cool", "fast",
		"sharp", "light", "deep", "wild", "pure", "soft", "fair", "true"}
	noun := []string{"river", "spark", "cloud", "stone", "leaf", "wave", "bloom", "frost",
		"trail", "ridge", "grove", "dusk", "peak", "tide", "vale", "glow"}
	r := mathrand.New(mathrand.NewSource(time.Now().UnixNano()))
	return fmt.Sprintf("tgv/%s-%s-%03x", adj[r.Intn(len(adj))], noun[r.Intn(len(noun))], r.Intn(0x1000))
}

// localGHToken reads a GitHub token from the local `gh` CLI. Empty string
// on any failure (no gh, not logged in, …).
func localGHToken() string {
	cmd := exec.Command("gh", "auth", "token")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
