import AppKit
import Core
import SwiftTerm

/// A NSView that hosts a SwiftTerm TerminalView wired to a remote session.
/// Supports two transport modes:
///   - **Mosh** (default for interactive terminals): UDP, local echo, roaming.
///   - **SSH PTY** (Citadel): used when mosh is unavailable.
final class TerminalTabView: NSView, TerminalViewDelegate {
    enum Transport {
        case mosh(sshTarget: String, args: [String])
        case sshPTY(ssh: SSHManager, command: String)
    }

    private let terminalView: TerminalView
    private var ptySession: PTYSession?
    private var moshSession: MoshSession?
    private let transport: Transport
    private var scrollMonitor: Any?
    private var scrollAccumulator: CGFloat = 0

    /// Create a terminal tab using mosh transport (recommended for interactive use).
    /// `args` is the argv of the remote command (first element is the program).
    init(sshTarget: String, args: [String]) {
        self.transport = .mosh(sshTarget: sshTarget, args: args)
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
        // SwiftTerm defaults to 500 lines of scrollback; bump it so long codex
        // conversations don't roll off the top during a session.
        terminalView.changeScrollback(10_000)
        // Disable mouse reporting so remote TUIs can't hijack mouse events —
        // ensures click+drag selection and Cmd+C work. Scroll wheel falls
        // through to SwiftTerm's native handler (scrolls the main-buffer
        // scrollback); see the comment at the bottom of the file.
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

        // SwiftTerm 1.2.0's scrollWheel silently drops events when
        // event.deltaY == 0 — the normal case for macOS trackpad precision
        // scrolls (the real delta is in scrollingDeltaY). Intercept with a
        // local event monitor so our handler runs before SwiftTerm's broken
        // default consumes the event, and scroll the main-buffer scrollback.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self, let window = self.window,
                  event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            self.handleScrollEvent(event)
            return nil
        }
    }

    deinit {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func handleScrollEvent(_ event: NSEvent) {
        let raw = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        guard raw != 0 else { return }
        let linesDelta: CGFloat = event.hasPreciseScrollingDeltas ? raw / 16 : raw
        scrollAccumulator += linesDelta
        let whole = Int(scrollAccumulator.rounded(.towardZero))
        guard whole != 0 else { return }
        scrollAccumulator -= CGFloat(whole)
        if whole > 0 {
            terminalView.scrollUp(lines: whole)
        } else {
            terminalView.scrollDown(lines: -whole)
        }
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
        case .mosh(let target, let args):
            let debug = "[\(cols)x\(rows)] mosh \(target) -- \(args.joined(separator: " "))\r\n"
            terminalView.feed(byteArray: [UInt8](debug.utf8)[...])
            let session = MoshSession(onData: dataHandler)
            self.moshSession = session
            session.start(sshTarget: target, commandArgs: args, cols: cols, rows: rows)

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

    /// Route first-responder status to the inner SwiftTerm view so keystrokes
    /// land in the terminal after view-hierarchy swaps (tab switches, side
    /// panel animations, panel dismissals).
    func focusTerminal() {
        window?.makeFirstResponder(terminalView)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-grab focus after being re-parented (switchMainTab removes/re-adds).
        if window != nil {
            DispatchQueue.main.async { [weak self] in self?.focusTerminal() }
        }
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

    // Scroll wheel is handled by ScrollableTerminalView (the inner view)
    // because events hit the innermost view first and aren't forwarded when
    // SwiftTerm's default scrollWheel bails on deltaY == 0.
}
