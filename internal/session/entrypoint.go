package session

import (
	"fmt"
	"strings"
)

// entrypointScript returns the bash script that runs as PID 1 inside each
// TGV container. Parallel to SessionManager.makeEntrypointScript in the
// retired Swift codebase — same side effects (tgv-codex wrapper, gh creds,
// codex config, dev user checkout, readiness marker).
func (m *Manager) entrypointScript(branch string) string {
	// Git identity lines (empty-safe — skip config if a field is blank).
	var gitIdentity strings.Builder
	if m.cfg.GitName != "" {
		fmt.Fprintf(&gitIdentity, "git config --global user.name %s\n", shellEscape(m.cfg.GitName))
	}
	if m.cfg.GitEmail != "" {
		fmt.Fprintf(&gitIdentity, "git config --global user.email %s\n", shellEscape(m.cfg.GitEmail))
	}

	return fmt.Sprintf(`#!/bin/bash
# Entrypoint runs as root. Installs the static bits first (so attach commands
# waiting on /tmp/tgv-ready never race ahead), then runs the git work as dev.

mkdir -p /home/dev

# tgv-codex wrapper — reads the mounted prompt file and execs codex.
cat > /usr/local/bin/tgv-codex << 'TGVCODEXEOF'
#!/bin/bash
p=""
if [ -r /run/secrets/codex_prompt ]; then
  p=$(cat /run/secrets/codex_prompt 2>/dev/null)
fi
if [ -n "$p" ]; then
  exec codex --no-alt-screen "$p"
else
  exec codex --no-alt-screen
fi
TGVCODEXEOF
chmod +x /usr/local/bin/tgv-codex

# gh CLI credentials — chown to dev + 600 so only dev can read the token.
if [ -f /run/secrets/gh_token ] && [ -s /run/secrets/gh_token ]; then
  GH_TOKEN=$(cat /run/secrets/gh_token)
  mkdir -p /home/dev/.config/gh
  cat > /home/dev/.config/gh/hosts.yml << GHEOF
github.com:
    oauth_token: $GH_TOKEN
    user: ""
    git_protocol: https
GHEOF
  chown -R dev:dev /home/dev/.config/gh
  chmod 600 /home/dev/.config/gh/hosts.yml
fi

# Persist Codex config + auth across container restarts via shared volume.
if [ -z "$(ls -A /mnt/codex 2>/dev/null)" ] && [ -d /home/dev/.codex ]; then
  cp -a /home/dev/.codex/. /mnt/codex/
fi
chown -R dev:dev /mnt/codex
rm -rf /home/dev/.codex
ln -s /mnt/codex /home/dev/.codex
chown -h dev:dev /home/dev/.codex

# Codex YOLO config (approval_policy=never + sandbox_mode=danger-full-access).
if [ ! -f /mnt/codex/config.toml ]; then
  cat > /mnt/codex/config.toml << 'CODEXEOF'
approval_policy = "never"
sandbox_mode = "danger-full-access"
CODEXEOF
  chown dev:dev /mnt/codex/config.toml
fi

# Run git work as dev so --global lands in /home/dev/.gitconfig and any new
# .git/ objects are dev-owned from the start (skips a recursive chown).
sudo -u dev -H bash << 'DEVEOF'
git config --global credential.https://github.com.helper '!gh auth git-credential' 2>/dev/null || true
%sgit config --global --add safe.directory /workspace/repo
cd /workspace/repo
git fetch --no-tags origin main 2>/dev/null || true
git fetch --no-tags origin %s 2>/dev/null || true
if git rev-parse --verify "refs/heads/%s" >/dev/null 2>&1; then
  git checkout %s 2>/dev/null
elif git rev-parse --verify "refs/remotes/origin/%s" >/dev/null 2>&1; then
  git checkout -b %s "origin/%s" 2>/dev/null
else
  git checkout -B %s origin/main 2>/dev/null
fi
DEVEOF

# Readiness marker — attach commands wait on this before launching abduco/zsh.
touch /tmp/tgv-ready

exec su dev -c 'sleep infinity'
`, gitIdentity.String(),
		branch, // fetch
		branch, // rev-parse heads
		branch, // checkout
		branch, // rev-parse remotes
		branch, // checkout -b
		branch, // origin/<branch>
		branch, // checkout -B
	)
}

func shellEscape(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
