import Foundation
import Citadel
import NIOCore
import NIOSSH

/// A long-lived PTY session wrapping Citadel's `withPTY`.
///
/// `withPTY` is a structured-concurrency closure that lasts until the channel
/// closes. We wrap it in a Task and expose `write`/`resize`/`close` so the
/// terminal view can drive it from outside.
public final class PTYSession: @unchecked Sendable {
    private let onData: @Sendable (Data) -> Void
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Error>?

    public init(onData: @escaping @Sendable (Data) -> Void) {
        self.onData = onData
    }

    /// Open a PTY shell and exec the given command in place of the shell.
    /// The channel stays open until the command exits (e.g. zellij detach).
    @available(macOS 15.0, *)
    public func start(
        client: SSHClient,
        cols: Int,
        rows: Int,
        command: String
    ) async throws {
        let req = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        // Wait for the writer to be available before returning
        let (stream, continuation) = AsyncStream<TTYStdinWriter>.makeStream()

        self.task = Task { [self] in
            try await client.withPTY(req) { inbound, outbound in
                continuation.yield(outbound)
                continuation.finish()

                // `exec` replaces the shell with the command, so when the command
                // exits the channel closes cleanly.
                try await outbound.write(ByteBuffer(string: "exec \(command)\n"))

                for try await output in inbound {
                    let buf: ByteBuffer
                    switch output {
                    case .stdout(let b): buf = b
                    case .stderr(let b): buf = b
                    }
                    let data = Data(buf.readableBytesView)
                    self.onData(data)
                }
            }
        }

        for await w in stream {
            self.writer = w
            break
        }
    }

    public func write(_ data: Data) async throws {
        guard let writer = writer else { return }
        try await writer.write(ByteBuffer(data: data))
    }

    public func resize(cols: Int, rows: Int) async throws {
        // Defensive: WindowChangeRequest converts to UInt32 and traps on negative ints.
        let safeCols = max(1, cols)
        let safeRows = max(1, rows)
        try await writer?.changeSize(cols: safeCols, rows: safeRows, pixelWidth: 0, pixelHeight: 0)
    }

    public func close() {
        task?.cancel()
    }
}
