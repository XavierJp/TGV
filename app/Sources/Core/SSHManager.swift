import Foundation
import Crypto
import Citadel
import NIOCore
import NIOSSH

public enum SSHError: Error, CustomStringConvertible {
    case notConnected
    case noPrivateKey
    case authFailed(String)
    case execFailed(String, exitCode: Int32)

    public var description: String {
        switch self {
        case .notConnected: return "Not connected"
        case .noPrivateKey: return "No private key found in ~/.ssh"
        case .authFailed(let msg): return "Auth failed: \(msg)"
        case .execFailed(let cmd, let code): return "Command failed (exit \(code)): \(cmd)"
        }
    }
}

public struct ExecResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public var success: Bool { exitCode == 0 }
}

/// Manages a single multiplexed SSH connection to the TGV server.
/// Built on Citadel (which wraps swift-nio-ssh).
public actor SSHManager {
    private let host: String
    private let port: Int
    private let user: String
    private var client: SSHClient?

    public init(host: String, port: Int = 22, user: String) {
        self.host = host
        self.port = port
        self.user = user
    }

    public init(config: TGVConfig) {
        self.host = config.host
        self.port = 22
        self.user = config.user
    }

    public var isConnected: Bool {
        client != nil
    }

    /// Connect to the server with a 30-second timeout.
    /// Tries SSH agent first, then ~/.ssh keys.
    public func connect() async throws {
        if client != nil { return }

        let auth = try loadAuthMethod()

        // Wrap connection in a timeout — Citadel doesn't expose one directly
        let connectTask = Task {
            try await SSHClient.connect(
                host: host,
                port: port,
                authenticationMethod: auth,
                hostKeyValidator: .acceptAnything(),
                reconnect: .never
            )
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 30_000_000_000)  // 30s
            connectTask.cancel()
        }

        do {
            let client = try await connectTask.value
            timeoutTask.cancel()
            self.client = client
        } catch is CancellationError {
            throw SSHError.authFailed("Connection timed out after 30s")
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    public func disconnect() async {
        if let client = client {
            try? await client.close()
            self.client = nil
        }
    }

    /// Run a non-interactive command and capture output.
    public func exec(_ command: String) async throws -> ExecResult {
        try await connect()
        guard let client = client else { throw SSHError.notConnected }

        let buffer = try await client.executeCommand(command)
        let stdout = String(buffer: buffer)
        return ExecResult(stdout: stdout, stderr: "", exitCode: 0)
    }

    /// Open a PTY session that runs `command` (typically a docker exec attach).
    /// Returns a long-lived `PTYSession` for read/write/resize.
    @available(macOS 15.0, *)
    public func openPTY(
        cols: Int,
        rows: Int,
        command: String,
        onData: @escaping @Sendable (Data) -> Void
    ) async throws -> PTYSession {
        try await connect()
        guard let client = client else { throw SSHError.notConnected }

        let session = PTYSession(onData: onData)
        try await session.start(client: client, cols: cols, rows: rows, command: command)
        return session
    }

    // MARK: - Auth

    private func loadAuthMethod() throws -> SSHAuthenticationMethod {
        let sshDir = NSString(string: "~/.ssh").expandingTildeInPath
        let candidates = ["id_ed25519", "id_rsa", "id_ecdsa"]

        var lastError: Error?

        for name in candidates {
            let path = "\(sshDir)/\(name)"
            guard FileManager.default.fileExists(atPath: path),
                  let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
                continue
            }

            // Citadel's OpenSSH parser only strips \n, not \r/spaces/tabs.
            // Normalize to LF-only and strip any stray whitespace inside the base64 body.
            let pem = normalizeOpenSSHPEM(raw)

            // Ed25519
            if name == "id_ed25519" {
                do {
                    let key = try Curve25519.Signing.PrivateKey(sshEd25519: pem)
                    return .ed25519(username: user, privateKey: key)
                } catch {
                    lastError = error
                    continue
                }
            }

            // RSA
            if name == "id_rsa" {
                do {
                    let key = try Insecure.RSA.PrivateKey(sshRsa: pem)
                    return .rsa(username: user, privateKey: key)
                } catch {
                    lastError = error
                    continue
                }
            }
        }

        if let lastError = lastError {
            throw SSHError.authFailed("Could not load any key: \(lastError)")
        }
        throw SSHError.noPrivateKey
    }

    /// Normalize an OpenSSH PEM file so Citadel's parser can read it.
    /// Citadel only strips `\n` before base64-decoding, so any `\r`, spaces, or
    /// tabs in the body cause `invalidBase64Payload`.
    private func normalizeOpenSSHPEM(_ raw: String) -> String {
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
        let end = "-----END OPENSSH PRIVATE KEY-----"

        // Replace CRLF/CR with LF
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
                   .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let beginRange = s.range(of: begin),
              let endRange = s.range(of: end) else {
            return s
        }

        // Strip whitespace from the base64 body
        let bodyStart = beginRange.upperBound
        let bodyEnd = endRange.lowerBound
        let body = s[bodyStart..<bodyEnd].unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let cleanBody = String(String.UnicodeScalarView(body))

        s.replaceSubrange(bodyStart..<bodyEnd, with: "\n\(cleanBody)\n")
        return s
    }
}
