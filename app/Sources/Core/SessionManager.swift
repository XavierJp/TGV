import Foundation

public enum SessionError: Error, CustomStringConvertible {
    case invalidName(String)
    case invalidBranch(String)
    case spawnFailed(String)
    case sshError(String)

    public var description: String {
        switch self {
        case .invalidName(let n): return "Invalid container name: \(n)"
        case .invalidBranch(let b): return "Invalid branch name: \(b). Use only alphanumeric, -, _, ., /"
        case .spawnFailed(let msg): return "Spawn failed: \(msg)"
        case .sshError(let msg): return "SSH error: \(msg)"
        }
    }
}

/// High-level operations on TGV sessions (Docker containers on remote server).
/// All operations go through SSHManager.exec.
public actor SessionManager {
    private let ssh: SSHManager
    private let config: TGVConfig

    public init(ssh: SSHManager, config: TGVConfig) {
        self.ssh = ssh
        self.config = config
    }

    // MARK: - List

    /// List all tgv sessions on the server (running + stopped).
    public func listSessions() async throws -> [Session] {
        let cmd = #"docker ps -a --filter label=tgv.repo --format '{{.Names}}\t{{.Label "tgv.repo"}}\t{{.Label "tgv.branch"}}\t{{.Status}}\t{{.Label "tgv.display_name"}}'"#
        let result = try await ssh.exec(cmd)
        guard !result.stdout.isEmpty else { return [] }

        // Fetch all display names in one call
        let displayNames = (try? await fetchDisplayNames()) ?? [:]

        var sessions: [Session] = []
        for line in result.stdout.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4, Self.isShellSafe(parts[0]) else { continue }

            let name = parts[0]
            let repoURL = parts[1]
            let branch = parts[2]
            let status = parts[3]
            let labelDisplay = parts.count >= 5 ? parts[4].trimmingCharacters(in: .whitespaces) : ""

            // Repo short name (e.g. "org/repo")
            let cleaned = repoURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let repoComponents = cleaned.split(separator: "/").map(String.init)
            let repoShort: String = {
                guard let last = repoComponents.last else { return "" }
                let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
                if repoComponents.count >= 2 {
                    return "\(repoComponents[repoComponents.count - 2])/\(name)"
                }
                return name
            }()

            let displayName: String? = !labelDisplay.isEmpty
                ? labelDisplay
                : displayNames[name]

            sessions.append(Session(
                name: name,
                repo: repoShort,
                branch: branch,
                running: status.contains("Up"),
                displayName: displayName
            ))
        }
        return sessions
    }

    /// Fetch all display names from /tmp/tgv-meta/*.name in one call.
    private func fetchDisplayNames() async throws -> [String: String] {
        let cmd = #"for f in /tmp/tgv-meta/*.name; do [ -f "$f" ] && echo "$(basename "$f" .name)=$(cat "$f")"; done 2>/dev/null"#
        let result = try await ssh.exec(cmd)
        var map: [String: String] = [:]
        for line in result.stdout.components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                map[String(parts[0])] = String(parts[1])
            }
        }
        return map
    }

    // MARK: - Branches

    /// List remote branches from the baked-in image's repo.
    public func listBranches() async throws -> [String] {
        let cmd = "docker run --rm \(config.dockerImage) bash -c 'cd /workspace/repo 2>/dev/null && git branch -r 2>/dev/null'"
        let result = try await ssh.exec(cmd)
        guard !result.stdout.isEmpty else { return [] }

        return result.stdout.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("->") { return nil }  // skip HEAD pointer
            if trimmed.hasPrefix("origin/") {
                return String(trimmed.dropFirst("origin/".count))
            }
            return nil
        }
    }

    // MARK: - Spawn

    /// Spawn a new session container on the given branch.
    /// onStep is called with progress messages.
    public func spawn(branch: String, onStep: @Sendable (String) -> Void = { _ in }) async throws -> String {
        guard Self.isShellSafe(branch) else { throw SessionError.invalidBranch(branch) }
        let name = Self.makeSessionName(repoURL: config.repoURL)

        let script = makeEntrypointScript(branch: branch)
        let scriptB64 = Data(script.utf8).base64EncodedString()

        // Step 1: write entrypoint via base64 (avoids quoting hell)
        onStep("Preparing entrypoint")
        _ = try await ssh.exec("mkdir -p /tmp/tgv-scripts && chmod 700 /tmp/tgv-scripts")
        _ = try await ssh.exec("echo '\(scriptB64)' | base64 -d > /tmp/tgv-scripts/\(name).sh && chmod +x /tmp/tgv-scripts/\(name).sh")

        // Step 2: copy OpenRouter API key (non-fatal but logged)
        onStep("Configuring credentials")
        do {
            _ = try await ssh.exec("cp ~/.config/tgv/openrouter_key /tmp/tgv-scripts/\(name).key 2>/dev/null; chmod 644 /tmp/tgv-scripts/\(name).key 2>/dev/null; true")
        } catch {
            onStep("Warning: OpenRouter key copy failed — \(error)")
        }

        // Step 2b: GitHub token from local gh CLI (non-fatal but logged)
        if let token = Self.localGHToken() {
            let tokenB64 = Data(token.utf8).base64EncodedString()
            do {
                _ = try await ssh.exec("echo '\(tokenB64)' | base64 -d > /tmp/tgv-scripts/\(name).gh && chmod 644 /tmp/tgv-scripts/\(name).gh")
            } catch {
                onStep("Warning: GitHub token copy failed — \(error)")
            }
        } else {
            // Touch empty file so the volume mount doesn't fail
            do {
                _ = try await ssh.exec("touch /tmp/tgv-scripts/\(name).gh")
            } catch {
                onStep("Warning: could not create empty gh token file — \(error)")
            }
        }

        // Step 3: docker run
        onStep("Starting container")
        let dockerCmd = """
        docker run -d \
        --name \(name) \
        --user root \
        --network \(config.dockerNetwork) \
        --label tgv.repo=\(config.repoURL) \
        --label tgv.branch=\(branch) \
        -e TERM=xterm-256color \
        -e COLORTERM=truecolor \
        -e LANG=C.UTF-8 \
        -v tgv-workspace-\(name):/workspace/repo \
        -v tgv-opencode-\(name):/mnt/opencode \
        -v /tmp/tgv-scripts/\(name).sh:/entrypoint.sh:ro \
        -v /tmp/tgv-scripts/\(name).key:/run/secrets/openrouter_key:ro \
        -v /tmp/tgv-scripts/\(name).gh:/run/secrets/gh_token:ro \
        \(config.dockerImage) \
        bash /entrypoint.sh
        """

        let result = try await ssh.exec(dockerCmd)
        if !result.success {
            throw SessionError.spawnFailed(result.stderr)
        }
        return name
    }

    // MARK: - Stop

    public func stop(name: String) async throws {
        guard Self.isShellSafe(name) else { throw SessionError.invalidName(name) }
        _ = try await ssh.exec("docker rm -f \(name)")
        _ = try await ssh.exec("docker volume rm -f tgv-workspace-\(name) tgv-opencode-\(name)")
        _ = try await ssh.exec("rm -f /tmp/tgv-scripts/\(name).sh /tmp/tgv-scripts/\(name).key /tmp/tgv-scripts/\(name).gh /tmp/tgv-meta/\(name).name")
    }

    // MARK: - Rename

    public func rename(name: String, displayName: String) async throws {
        guard Self.isShellSafe(name) else { throw SessionError.invalidName(name) }
        // Sanitize: only quote-safe characters allowed
        let safe = displayName.replacingOccurrences(of: "'", with: "'\\''")
        _ = try await ssh.exec("mkdir -p /tmp/tgv-meta && echo '\(safe)' > /tmp/tgv-meta/\(name).name")
    }

    // MARK: - Git metrics

    public func gitMetrics(name: String) async throws -> (insertions: Int, deletions: Int) {
        guard Self.isShellSafe(name) else { throw SessionError.invalidName(name) }
        // --numstat outputs machine-readable "added\tremoved\tfile" per line, locale-independent
        let cmd = "docker exec -u dev \(name) bash -c 'cd /workspace/repo 2>/dev/null || exit 0; git diff --numstat 2>/dev/null; git diff --cached --numstat 2>/dev/null'"
        let result = try await ssh.exec(cmd)

        var insertions = 0
        var deletions = 0
        for line in result.stdout.components(separatedBy: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 2 else { continue }
            // Binary files show "-" instead of a number
            if let added = Int(parts[0]) { insertions += added }
            if let removed = Int(parts[1]) { deletions += removed }
        }
        return (insertions, deletions)
    }

    // MARK: - Host metrics

    public struct HostMetrics: Sendable {
        public let cpuPercent: Double   // 0..1, actual CPU utilization from /proc/stat delta
        public let cpuCount: Int
        public let load1: Double        // loadavg 1-minute (secondary info)
        public let memUsed: UInt64      // bytes
        public let memTotal: UInt64
        public let diskUsed: UInt64     // bytes (root filesystem)
        public let diskTotal: UInt64
        public let cpuTemp: Double?     // °C, nil if unavailable
        public let gpuUtil: Double?     // 0..1, nil if no GPU
        public let gpuMemUsed: UInt64?  // bytes
        public let gpuMemTotal: UInt64?
        public let gpuTemp: Double?     // °C
        public let gpuWatts: Double?    // W

        public var memFraction: Double {
            memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0
        }

        public var diskFraction: Double {
            diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) : 0
        }

        public var gpuMemFraction: Double? {
            guard let used = gpuMemUsed, let total = gpuMemTotal, total > 0 else { return nil }
            return Double(used) / Double(total)
        }
    }

    /// Read host metrics in a single SSH call. Uses prefixed lines for robust parsing.
    /// CPU utilization is computed from /proc/stat deltas (0.5s interval).
    public func hostMetrics() async throws -> HostMetrics {
        let cmd = #"""
        echo "CPUSTAT1:$(grep '^cpu ' /proc/stat | head -1)"
        sleep 0.5
        echo "CPUSTAT2:$(grep '^cpu ' /proc/stat | head -1)"
        echo "LOAD:$(cat /proc/loadavg 2>/dev/null)"
        echo "CPUS:$(nproc 2>/dev/null)"
        grep -E '^(MemTotal|MemAvailable):' /proc/meminfo 2>/dev/null | sed 's/^/MEM:/'
        df -B1 / 2>/dev/null | tail -1 | awk '{print "DISK:"$2" "$3}'
        # CPU temperature (try thermal_zone0, common on Linux)
        if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
          echo "CPUTEMP:$(cat /sys/class/thermal/thermal_zone0/temp)"
        elif command -v sensors >/dev/null 2>&1; then
          echo "CPUTEMP:$(sensors 2>/dev/null | grep -i 'package\|tctl\|cpu' | head -1 | grep -oP '\+\K[0-9.]+'| head -1)000"
        fi
        # GPU: utilization, memory, temperature, power
        if command -v nvidia-smi >/dev/null 2>&1; then
          nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits 2>/dev/null | head -1 | sed 's/^/GPU:/'
        fi
        """#
        let result = try await ssh.exec(cmd)

        var load1: Double = 0
        var cpuCount: Int = 1
        var memTotalKB: UInt64 = 0
        var memAvailKB: UInt64 = 0
        var diskTotal: UInt64 = 0
        var diskUsed: UInt64 = 0
        var cpuTemp: Double?
        var gpuUtil: Double?
        var gpuMemUsed: UInt64?
        var gpuMemTotal: UInt64?
        var gpuTemp: Double?
        var gpuWatts: Double?
        var cpuStat1: [UInt64] = []
        var cpuStat2: [UInt64] = []

        for raw in result.stdout.components(separatedBy: "\n") {
            let whitespace = CharacterSet.whitespacesAndNewlines
            let line = raw.trimmingCharacters(in: whitespace)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("CPUSTAT1:") {
                cpuStat1 = parseCPUStatLine(String(line.dropFirst("CPUSTAT1:".count)))
            } else if line.hasPrefix("CPUSTAT2:") {
                cpuStat2 = parseCPUStatLine(String(line.dropFirst("CPUSTAT2:".count)))
            } else if line.hasPrefix("LOAD:") {
                let payload = String(line.dropFirst("LOAD:".count))
                if let first = payload.split(separator: " ").first {
                    load1 = Double(first) ?? 0
                }
            } else if line.hasPrefix("CPUS:") {
                cpuCount = Int(line.dropFirst("CPUS:".count)) ?? 1
            } else if line.hasPrefix("MEM:") {
                let payload = line.dropFirst("MEM:".count)
                let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let fieldSpace = CharacterSet.whitespaces
                let key = parts[0].trimmingCharacters(in: fieldSpace)
                let value = parts[1].trimmingCharacters(in: fieldSpace)
                    .replacingOccurrences(of: " kB", with: "")
                guard let kb = UInt64(value) else { continue }
                if key == "MemTotal" { memTotalKB = kb }
                if key == "MemAvailable" { memAvailKB = kb }
            } else if line.hasPrefix("DISK:") {
                let parts = line.dropFirst("DISK:".count).split(separator: " ").map(String.init)
                if parts.count == 2 {
                    diskTotal = UInt64(parts[0]) ?? 0
                    diskUsed = UInt64(parts[1]) ?? 0
                }
            } else if line.hasPrefix("CPUTEMP:") {
                let raw = String(line.dropFirst("CPUTEMP:".count))
                if let val = Double(raw) {
                    cpuTemp = val > 1000 ? val / 1000.0 : val
                }
            } else if line.hasPrefix("GPU:") {
                let fieldSpace = CharacterSet.whitespaces
                let parts = line.dropFirst("GPU:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: fieldSpace) }
                if parts.count >= 1, let util = Double(parts[0]) {
                    gpuUtil = max(0, min(1, util / 100.0))
                }
                if parts.count >= 3,
                   let usedMB = UInt64(parts[1]),
                   let totalMB = UInt64(parts[2]) {
                    gpuMemUsed = usedMB * 1024 * 1024
                    gpuMemTotal = totalMB * 1024 * 1024
                }
                if parts.count >= 4, let temp = Double(parts[3]) {
                    gpuTemp = temp
                }
                if parts.count >= 5, let watts = Double(parts[4]) {
                    gpuWatts = watts
                }
            }
        }

        // Compute CPU % from /proc/stat delta.
        // Fields: user nice system idle iowait irq softirq steal guest guest_nice
        // idle time = idle + iowait
        var cpuPercent: Double = 0
        if cpuStat1.count >= 5 && cpuStat2.count >= 5 {
            let total1 = cpuStat1.reduce(0, +)
            let total2 = cpuStat2.reduce(0, +)
            let idle1 = cpuStat1[3] + (cpuStat1.count > 4 ? cpuStat1[4] : 0)
            let idle2 = cpuStat2[3] + (cpuStat2.count > 4 ? cpuStat2[4] : 0)
            let totalDelta = total2 > total1 ? total2 - total1 : 0
            let idleDelta = idle2 > idle1 ? idle2 - idle1 : 0
            if totalDelta > 0 {
                let busyDelta = totalDelta > idleDelta ? totalDelta - idleDelta : 0
                cpuPercent = Double(busyDelta) / Double(totalDelta)
                cpuPercent = max(0, min(1, cpuPercent))
            }
        }

        let memTotal = memTotalKB * 1024
        let memUsed = (memTotalKB > memAvailKB) ? (memTotalKB - memAvailKB) * 1024 : 0

        return HostMetrics(
            cpuPercent: cpuPercent,
            cpuCount: cpuCount,
            load1: load1,
            memUsed: memUsed,
            memTotal: memTotal,
            diskUsed: diskUsed,
            diskTotal: diskTotal,
            cpuTemp: cpuTemp,
            gpuUtil: gpuUtil,
            gpuMemUsed: gpuMemUsed,
            gpuMemTotal: gpuMemTotal,
            gpuTemp: gpuTemp,
            gpuWatts: gpuWatts
        )
    }

    /// Parse a /proc/stat `cpu` line (the aggregate one) into [user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice].
    private func parseCPUStatLine(_ line: String) -> [UInt64] {
        // "cpu 123456 100 45678 9876543 ..." or "123456 100 ..." if "cpu " was stripped
        let parts = line.split(separator: " ").compactMap { UInt64($0) }
        return parts
    }

    // MARK: - Git status (native)

    /// Run `git status --porcelain=v1 -b` inside a running container and return the raw output.
    public func gitStatusRaw(container: String) async throws -> String {
        guard Self.isShellSafe(container) else { throw SessionError.invalidName(container) }
        let cmd = "docker exec -u dev -w /workspace/repo \(container) git status --porcelain=v1 -b 2>/dev/null"
        let result = try await ssh.exec(cmd)
        return result.stdout
    }

    /// List files in the repo workspace. Uses `git ls-files` for tracked files
    /// plus `git ls-files --others --exclude-standard` for untracked.
    public func fileListRaw(container: String) async throws -> String {
        guard Self.isShellSafe(container) else { throw SessionError.invalidName(container) }
        let cmd = "docker exec -u dev -w /workspace/repo \(container) bash -c 'git ls-files 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null' 2>/dev/null"
        let result = try await ssh.exec(cmd)
        return result.stdout
    }

    /// Stage all and commit with the given message.
    public func gitCommit(container: String, message: String) async throws {
        guard Self.isShellSafe(container) else { throw SessionError.invalidName(container) }
        let safeMsg = message.replacingOccurrences(of: "'", with: "'\\''")
        let cmd = "docker exec -u dev -w /workspace/repo \(container) bash -c 'git add -A && git commit -m '\"'\"'\(safeMsg)'\"'\"''"
        _ = try await ssh.exec(cmd)
    }

    /// Push the current branch.
    public func gitPush(container: String) async throws {
        guard Self.isShellSafe(container) else { throw SessionError.invalidName(container) }
        let cmd = "docker exec -u dev -w /workspace/repo \(container) git push 2>&1"
        _ = try await ssh.exec(cmd)
    }

    /// Run `git log` inside a running container and return the raw output.
    public func gitLogRaw(container: String, count: Int = 20) async throws -> String {
        guard Self.isShellSafe(container) else { throw SessionError.invalidName(container) }
        let cmd = "docker exec -u dev -w /workspace/repo \(container) git log --format='%h|%s|%an|%ar' -\(count) 2>/dev/null"
        let result = try await ssh.exec(cmd)
        return result.stdout
    }

    // MARK: - Attach command

    /// Tools (tmux, tree, etc.) are baked into the docker image at `tgv-init` time,
    /// so this is a no-op for new containers. Kept for backward-compat with old
    /// containers built before the bake-in: writes a fresh tmux.conf and installs
    /// tmux on-demand if missing.
    public func ensureTools(container: String) async throws {
        guard Self.isShellSafe(container) else { throw SessionError.invalidName(container) }

        let script = #"""
        set -e
        # Old containers may not have tmux — best-effort install
        if ! command -v tmux >/dev/null 2>&1; then
          apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y tmux
        fi
        # Always (re)write tmux config so changes apply
        mkdir -p /home/dev
        cat > /home/dev/.tmux.conf << 'TMUXEOF'
        set -g status off
        set -g mouse on
        set -g history-limit 50000
        set -g default-terminal "xterm-256color"
        set -ga terminal-overrides ",*256col*:Tc"
        set -g set-clipboard on
        bind-key -n C-q detach
        TMUXEOF
        chown dev:dev /home/dev/.tmux.conf
        """#

        let encoded = Data(script.utf8).base64EncodedString()
        let cmd = "docker exec -u root \(container) bash -c 'echo \(encoded) | base64 -d | bash'"
        let result = try await ssh.exec(cmd)
        if !result.success {
            throw SessionError.sshError("ensureTools failed: \(result.stderr.isEmpty ? result.stdout : result.stderr)")
        }
    }

    /// Build the docker exec command to attach to a session's tmux.
    /// `new-session -A` creates the session if it doesn't exist, else attaches.
    /// tmux is baked into the docker image at `tgv-init` time.
    public nonisolated func attachCommand(container: String) -> String {
        precondition(Self.isShellSafe(container), "unsafe container name")
        return "docker exec -u dev -it -w /workspace/repo \(container) tmux new-session -A -s tgv opencode"
    }

    // MARK: - Helpers

    static func isShellSafe(_ s: String) -> Bool {
        guard !s.isEmpty, s.count < 256 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./"))
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Generate a session name like "myrepo-3f8a9b21"
    static func makeSessionName(repoURL: String) -> String {
        let cleaned = repoURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let last = cleaned.split(separator: "/").last.map(String.init) ?? "session"
        let repo = last.hasSuffix(".git") ? String(last.dropLast(4)) : last

        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var hasher = Hasher()
        hasher.combine(repoURL)
        hasher.combine(now)
        let hash = String(UInt64(bitPattern: Int64(hasher.finalize())), radix: 16)
        let suffix = String(hash.prefix(8))

        return "\(repo)-\(suffix)"
    }

    /// Generate a random branch name like "tgv/swift-river-3a8"
    public static func randomBranchName() -> String {
        let adjectives = ["swift", "bright", "calm", "bold", "keen", "warm", "cool", "fast",
                          "sharp", "light", "deep", "wild", "pure", "soft", "fair", "true"]
        let nouns = ["river", "spark", "cloud", "stone", "leaf", "wave", "bloom", "frost",
                     "trail", "ridge", "grove", "dusk", "peak", "tide", "vale", "glow"]

        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        var hasher = Hasher()
        hasher.combine(now)
        let h = UInt64(bitPattern: Int64(hasher.finalize()))

        let adj = adjectives[Int(h % UInt64(adjectives.count))]
        let noun = nouns[Int((h >> 16) % UInt64(nouns.count))]
        let hex = String((h >> 32) & 0xFFF, radix: 16)
        return "tgv/\(adj)-\(noun)-\(hex)"
    }

    /// Read a GitHub token from the local `gh` CLI.
    static func localGHToken() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["gh", "auth", "token"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (token?.isEmpty ?? true) ? nil : token
        } catch {
            return nil
        }
    }

    // MARK: - Entrypoint script

    private func makeEntrypointScript(branch: String) -> String {
        let gitConfig: String
        // We don't have git name/email in TGVConfig yet — skip for now.
        // TODO: read from config.toml [git] section if needed.
        gitConfig = ""

        return #"""
        #!/bin/bash
        # Entrypoint runs as root — copies secrets, writes config, then drops to dev

        if [ -f /run/secrets/openrouter_key ]; then
          export OPENROUTER_API_KEY=$(cat /run/secrets/openrouter_key)
        fi

        cat > /workspace/repo/opencode.json << 'CFGEOF'
        {
          "$schema": "https://opencode.ai/config.json",
          "provider": {
            "openrouter": {
              "models": {
                "qwen/qwen3-coder": {},
                "qwen/qwen3-coder:free": {}
              }
            }
          }
        }
        CFGEOF

        cat > /workspace/repo/tui.json << 'CFGEOF'
        {
          "$schema": "https://opencode.ai/tui.json",
          "theme": "tokyonight"
        }
        CFGEOF

        if [ -f /run/secrets/gh_token ] && [ -s /run/secrets/gh_token ]; then
          GH_TOKEN=$(cat /run/secrets/gh_token)
          mkdir -p /home/dev/.config/gh
          cat > /home/dev/.config/gh/hosts.yml << GHEOF
        github.com:
            oauth_token: $GH_TOKEN
            user: ""
            git_protocol: https
        GHEOF
          chmod 600 /home/dev/.config/gh/hosts.yml
          git config --global credential.https://github.com.helper '!gh auth git-credential'
        fi

        \#(gitConfig)

        cd /workspace/repo
        git config --global --add safe.directory /workspace/repo
        git fetch --all 2>/dev/null
        if git checkout \#(branch) 2>/dev/null; then
          git pull --ff-only 2>/dev/null
        elif git checkout -b \#(branch) origin/\#(branch) 2>/dev/null; then
          true
        else
          git checkout origin/main 2>/dev/null
          git checkout -b \#(branch) 2>/dev/null
        fi

        chown -R dev:dev /mnt/opencode
        mkdir -p /home/dev/.local/share
        ln -sfn /mnt/opencode /home/dev/.local/share/opencode
        chown -R dev:dev /home/dev /workspace/repo
        exec su dev -c 'export OPENROUTER_API_KEY=$(cat /run/secrets/openrouter_key 2>/dev/null); sleep infinity'
        """#
    }
}
