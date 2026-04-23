import Foundation
import SwiftTerm

/// A terminal session backed by a local `mosh` child process.
///
/// Uses SwiftTerm's `LocalProcess` to spawn mosh in a real PTY.
/// Mosh provides UDP transport, local echo, and roaming — significantly
/// lower latency than raw SSH for interactive terminal use.
///
/// Keep Citadel SSH for non-interactive exec commands (git status, session
/// management, host metrics). Use MoshSession for the interactive terminals.
public final class MoshSession: @unchecked Sendable {
    private let localProcess: LocalProcess
    private let onData: @Sendable (Data) -> Void
    private let dataHandler: DataHandler

    public init(onData: @escaping @Sendable (Data) -> Void) {
        self.onData = onData
        self.dataHandler = DataHandler(onData: onData)
        self.localProcess = LocalProcess(delegate: dataHandler)
    }

    /// Start a mosh session running `commandArgs` (argv) on `sshTarget`.
    /// Passing argv as a list — not a single string — preserves arguments
    /// that contain spaces (e.g. file paths). The caller is responsible for
    /// splitting the remote command into its argv elements.
    public func start(sshTarget: String, commandArgs: [String], cols: Int, rows: Int) {
        // Resolve mosh to an absolute path. When the app launches from Finder,
        // PATH is whatever launchd set (typically just /usr/bin:/bin:/usr/sbin:/sbin)
        // — it doesn't include /opt/homebrew/bin, so `/usr/bin/env mosh` would
        // fail with "env: mosh: No such file or directory".
        guard let moshPath = Self.resolveMosh() else {
            let msg = "\r\n*** mosh binary not found — install with `brew install mosh`.\r\n"
            onData(Data(msg.utf8))
            return
        }

        // mosh spawns its own ssh child, which needs a PATH with ssh reachable.
        // Prepend the homebrew prefixes in case the launchd PATH is missing them.
        var pathComponents = ["/opt/homebrew/bin", "/usr/local/bin"]
        let parent = ProcessInfo.processInfo.environment
        if let parentPath = parent["PATH"], !parentPath.isEmpty {
            pathComponents.append(parentPath)
        } else {
            pathComponents.append(contentsOf: ["/usr/bin", "/bin"])
        }

        var env = [
            "TERM=xterm-256color",
            "COLORTERM=truecolor",
            "LANG=en_US.UTF-8",
            "PATH=\(pathComponents.joined(separator: ":"))",
        ]
        // Pass through the auth/identity vars mosh's inner SSH handshake needs.
        // Without SSH_AUTH_SOCK the agent can't be reached and pubkey auth fails,
        // which makes the remote shell die and mosh print "[mosh is exiting.]".
        for key in ["HOME", "USER", "LOGNAME", "SSH_AUTH_SOCK"] {
            if let value = parent[key] {
                env.append("\(key)=\(value)")
            }
        }

        // LocalProcess prepends `execName` as argv[0] internally (see SwiftTerm
        // LocalProcess.swift). So `args` here must NOT repeat "mosh" — otherwise
        // mosh parses argv[1] as the target and tries to resolve "mosh" as a host.
        let args = [sshTarget, "--"] + commandArgs

        localProcess.startProcess(
            executable: moshPath,
            args: args,
            environment: env,
            execName: "mosh"
        )

        resize(cols: cols, rows: rows)
    }

    /// Search common install locations for the `mosh` binary and return the first
    /// executable match. Independent of the launched process's PATH.
    private static func resolveMosh() -> String? {
        let candidates = [
            "/opt/homebrew/bin/mosh",
            "/usr/local/bin/mosh",
            "/opt/local/bin/mosh",      // MacPorts
            "/usr/bin/mosh",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Last resort: honor PATH if the app was launched from a shell that has mosh.
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            for dir in envPath.split(separator: ":") {
                let candidate = "\(dir)/mosh"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    public func write(_ data: Data) {
        localProcess.send(data: Array(data)[...])
    }

    public func resize(cols: Int, rows: Int) {
        let safeCols = max(1, cols)
        let safeRows = max(1, rows)
        let fd = localProcess.childfd
        guard fd >= 0 else { return }
        var ws = winsize(
            ws_row: UInt16(safeRows),
            ws_col: UInt16(safeCols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: fd, windowSize: &ws)
    }

    public func close() {
        localProcess.terminate()
    }

    /// Bridge between LocalProcessDelegate (which needs a class) and the onData closure.
    private final class DataHandler: NSObject, LocalProcessDelegate {
        let onData: @Sendable (Data) -> Void

        init(onData: @escaping @Sendable (Data) -> Void) {
            self.onData = onData
        }

        func dataReceived(slice: ArraySlice<UInt8>) {
            let data = Data(slice)
            onData(data)
        }

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            // Session ended — the UI will notice the channel is dead
        }

        func getWindowSize() -> winsize {
            // Initial size — actual resize is handled via ioctl in MoshSession.resize()
            return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }
    }
}
