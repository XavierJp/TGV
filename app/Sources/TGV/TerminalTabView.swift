import AppKit
import Core
import SwiftTerm

/// A NSView that hosts a SwiftTerm TerminalView wired to a remote session.
/// Supports two transport modes:
///   - **Mosh** (default for interactive terminals): UDP, local echo, roaming.
///   - **SSH PTY** (Citadel): used when mosh is unavailable.
final class TerminalTabView: NSView, TerminalViewDelegate {
    enum Transport {
        case mosh(sshTarget: String, command: String)
        case sshPTY(ssh: SSHManager, command: String)
    }

    private let terminalView: TerminalView
    private var ptySession: PTYSession?
    private var moshSession: MoshSession?
    private let transport: Transport

    /// Create a terminal tab using mosh transport (recommended for interactive use).
    init(sshTarget: String, command: String) {
        self.transport = .mosh(sshTarget: sshTarget, command: command)
        self.terminalView = TerminalView(frame: .zero)
        super.init(frame: .zero)
        setupView()
    }

    /// Create a terminal tab using Citadel SSH PTY (fallback when mosh unavailable).
    init(ssh: SSHManager, command: String) {
        self.transport = .sshPTY(ssh: ssh, command: command)
        self.terminalView = TerminalView(frame: .zero)
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = TerminalTheme.tokyoNight.background.cgColor

        terminalView.applyTheme(TerminalTheme.tokyoNight)
        terminalView.font = AppFont.regular(12)
        // Disable mouse reporting so remote apps (tmux, claude, etc.) can't
        // hijack mouse events — ensures click+drag selection and Cmd+C work.
        terminalView.allowMouseReporting = false
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.terminalDelegate = self
        addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// Open the session and start streaming.
    func connect() {
        let cols = max(Int(terminalView.getTerminal().cols), 80)
        let rows = max(Int(terminalView.getTerminal().rows), 24)

        let dataHandler: @Sendable (Data) -> Void = { [weak self] data in
            let bytes = [UInt8](data)
            Task { @MainActor in
                self?.terminalView.feed(byteArray: bytes[...])
            }
        }

        switch transport {
        case .mosh(let target, let command):
            let debug = "[\(cols)x\(rows)] mosh \(target) -- \(command)\r\n"
            terminalView.feed(byteArray: [UInt8](debug.utf8)[...])
            let session = MoshSession(onData: dataHandler)
            self.moshSession = session
            session.start(sshTarget: target, command: command, cols: cols, rows: rows)

        case .sshPTY(let ssh, let command):
            guard #available(macOS 15.0, *) else {
                let msg = "\r\n*** macOS 15+ required for SSH PTY channels\r\n"
                terminalView.feed(byteArray: [UInt8](msg.utf8)[...])
                return
            }
            Task { [weak self] in
                do {
                    let session = try await ssh.openPTY(
                        cols: cols, rows: rows,
                        command: command,
                        onData: dataHandler
                    )
                    self?.ptySession = session
                } catch {
                    let msg = "\r\n*** Connection failed: \(error)\r\n"
                    await MainActor.run {
                        self?.terminalView.feed(byteArray: [UInt8](msg.utf8)[...])
                    }
                }
            }
        }
    }

    func close() {
        ptySession?.close()
        ptySession = nil
        moshSession?.close()
        moshSession = nil
    }

    /// Send raw bytes to the terminal session (used for forwarding key combos).
    func sendBytes(_ bytes: [UInt8]) {
        let data = Data(bytes)
        if let mosh = moshSession {
            mosh.write(data)
        } else if let pty = ptySession {
            Task { try? await pty.write(data) }
        }
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let payload = Data(data)
        if let mosh = moshSession {
            mosh.write(payload)
        } else if let pty = ptySession {
            Task { try? await pty.write(payload) }
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        let cols = max(1, newCols)
        let rows = max(1, newRows)
        if let mosh = moshSession {
            mosh.resize(cols: cols, rows: rows)
        } else if let pty = ptySession {
            Task { try? await pty.resize(cols: cols, rows: rows) }
        }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // Could propagate to window title; ignored for now.
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Optional OSC 7 / shell integration; ignored.
    }

    func scrolled(source: TerminalView, position: Double) {
        // Optional scrollbar updates.
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        // Optional viewport tracking.
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    // MARK: - Scroll forwarding to tmux
    // Since allowMouseReporting is false, SwiftTerm doesn't forward mouse events
    // to the terminal. But we still need scroll wheel to reach tmux so it can
    // scroll its scrollback (especially for alt-screen apps like Claude Code).
    // We send raw SGR mouse wheel sequences directly via term.sendResponse.

    override func scrollWheel(with event: NSEvent) {
        guard event.deltaY != 0 else {
            return super.scrollWheel(with: event)
        }
        let term = terminalView.getTerminal()
        let cols = max(1, term.cols)
        let rows = max(1, term.rows)
        let point = terminalView.convert(event.locationInWindow, from: nil)
        let cellW = terminalView.bounds.width / CGFloat(cols)
        let cellH = terminalView.bounds.height / CGFloat(rows)
        let col = max(1, min(cols, Int(point.x / cellW) + 1))
        let row = max(1, min(rows, Int((terminalView.bounds.height - point.y) / cellH) + 1))

        // SGR mouse encoding: button 64 = wheel up, 65 = wheel down
        let button = event.deltaY > 0 ? 64 : 65
        let count = max(1, min(5, Int(abs(event.deltaY))))
        for _ in 0..<count {
            term.sendResponse(text: "\u{1b}[<\(button);\(col);\(row)M")
        }
    }
}
