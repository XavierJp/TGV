import AppKit
import Core
import SwiftTerm

/// Terminals attached to a session container.
private struct SessionPanes {
    let main: TerminalTabView      // tmux + opencode (center area, "Agent" tab)
    let shell: TerminalTabView     // zsh in /workspace/repo (side: Terminal tab)
    var edit: TerminalTabView?     // nvim or delta diff (center, "Edit" tab)

    var all: [TerminalTabView] {
        [main, shell] + (edit.map { [$0] } ?? [])
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!

    private var splash: SplashView?
    private var sidebar: SidebarView!
    private var centerHeader: CenterHeaderView!
    private var mainContainer: NSView!
    private var emptyStateSplash: SplashView?
    private var sidePanel: SidePanelView!
    private var split: NSSplitView!
    private var centerColumn: NSView!
    private var sidePanelVisible = false

    private var config: TGVConfig?
    private var ssh: SSHManager?
    private var sessionManager: SessionManager?

    private var panes: [String: SessionPanes] = [:]   // session.name -> pair
    private var activeSession: String?
    private var currentFilePaths: [String] = []       // flat file list for fuzzy finder
    private var fuzzyFinder: FuzzyFinderPanel?

    private var refreshTimer: Timer?
    private var metricsTimer: Timer?
    private var gitStatusTimer: Timer?
    private var newSessionSheet: NewSessionSheet?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        setupMenuBar()
        setupWindow()
        installScrollWheelMonitor()
        installCmdPMonitor()
        Task { await bootstrap() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        metricsTimer?.invalidate()
        gitStatusTimer?.invalidate()
    }

    /// Global scroll-wheel interceptor.
    /// SwiftTerm's scrollWheel always scrolls its own buffer — it never forwards
    /// wheel events to the application (tmux). This monitor intercepts scroll events
    /// on any TerminalView with mouseMode on, sends SGR mouse sequences, and
    /// consumes the event so SwiftTerm doesn't fight tmux for the scroll.
    private func installScrollWheelMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { (event: NSEvent) -> NSEvent? in
            guard event.deltaY != 0 else { return event }

            // Walk up from the hit view to find a TerminalView
            var candidate = event.window?.contentView?.hitTest(event.locationInWindow)
            var termView: TerminalView?
            while let v = candidate {
                if let tv = v as? TerminalView { termView = tv; break }
                candidate = v.superview
            }
            guard let tv = termView else { return event }

            // Always send SGR mouse wheel events to the terminal.
            // We skip the mouseMode check because mosh doesn't forward mouse
            // mode enable sequences (\e[?1000h) — SwiftTerm never sees them,
            // so mouseMode stays .off even though tmux has `mouse on`.
            // Since all our terminals run tmux with mouse on, this is safe.
            let term = tv.getTerminal()
            let point = tv.convert(event.locationInWindow, from: nil)
            let cols = max(1, term.cols)
            let rows = max(1, term.rows)
            let cellW = tv.bounds.width / CGFloat(cols)
            let cellH = tv.bounds.height / CGFloat(rows)
            let col = max(1, min(cols, Int(point.x / cellW) + 1))
            let row = max(1, min(rows, Int((tv.bounds.height - point.y) / cellH) + 1))

            // SGR mouse encoding: button 64 = wheel up, 65 = wheel down
            let button = event.deltaY > 0 ? 64 : 65
            let count = max(1, min(5, Int(abs(event.deltaY))))
            for _ in 0..<count {
                term.sendResponse(text: "\u{1b}[<\(button);\(col);\(row)M")
            }

            return nil  // consume — don't let SwiftTerm scroll its own buffer
        }
    }

    /// Intercept Cmd+P to show the native fuzzy file finder.
    private func installCmdPMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "p" else { return event }
            guard let self = self, self.activeSession != nil else { return event }
            self.showFuzzyFinder()
            return nil  // consume the event
        }
    }

    private func showFuzzyFinder() {
        // Dismiss if already showing
        if let existing = fuzzyFinder {
            existing.dismiss()
            fuzzyFinder = nil
            return
        }

        let panel = FuzzyFinderPanel(files: currentFilePaths, relativeTo: window)
        panel.onSelect = { [weak self] path in
            self?.fuzzyFinder = nil
            self?.openFileTab(path: path)
        }
        panel.onDismiss = { [weak self] in
            self?.fuzzyFinder = nil
        }
        panel.show()
        fuzzyFinder = panel
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = TrainIcon.make()
            button.imagePosition = .imageLeading
            button.action = #selector(toggleWindow)
            button.target = self
        }
    }

    private func setupWindow() {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = "TGV"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 500)

        let splash = SplashView(frame: .zero)
        splash.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(splash)
        NSLayoutConstraint.activate([
            splash.topAnchor.constraint(equalTo: container.topAnchor),
            splash.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splash.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splash.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        self.splash = splash

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Build the 3-pane split layout: sidebar | (center header + main terminal) | side panel
    private func installMainLayout() {
        split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        sidebar = SidebarView(frame: .zero)
        sidebar.onSelectSession = { [weak self] s in self?.openSessionPair(s) }
        sidebar.onKillSession = { [weak self] s in Task { await self?.killSession(s) } }
        sidebar.onNewSession = { [weak self] in self?.showNewSessionSheet() }

        // Center column: header + content (terminal OR empty-state splash)
        centerColumn = NSView()
        centerColumn.wantsLayer = true
        centerColumn.layer?.backgroundColor = NSColor(srgbRed: 0x1a/255, green: 0x1b/255, blue: 0x26/255, alpha: 1).cgColor

        centerHeader = CenterHeaderView(frame: .zero)
        centerHeader.translatesAutoresizingMaskIntoConstraints = false
        centerHeader.onShowSidePanel = { [weak self] in self?.setSidePanel(visible: true) }
        centerHeader.onSelectTab = { [weak self] id in self?.switchMainTab(id: id) }
        centerHeader.onCloseTab = nil

        mainContainer = NSView()
        mainContainer.wantsLayer = true
        mainContainer.layer?.backgroundColor = NSColor(srgbRed: 0x1a/255, green: 0x1b/255, blue: 0x26/255, alpha: 1).cgColor
        mainContainer.translatesAutoresizingMaskIntoConstraints = false

        centerColumn.addSubview(centerHeader)
        centerColumn.addSubview(mainContainer)
        NSLayoutConstraint.activate([
            centerHeader.topAnchor.constraint(equalTo: centerColumn.topAnchor),
            centerHeader.leadingAnchor.constraint(equalTo: centerColumn.leadingAnchor),
            centerHeader.trailingAnchor.constraint(equalTo: centerColumn.trailingAnchor),
            mainContainer.topAnchor.constraint(equalTo: centerHeader.bottomAnchor),
            mainContainer.leadingAnchor.constraint(equalTo: centerColumn.leadingAnchor),
            mainContainer.trailingAnchor.constraint(equalTo: centerColumn.trailingAnchor),
            mainContainer.bottomAnchor.constraint(equalTo: centerColumn.bottomAnchor),
        ])

        sidePanel = SidePanelView()
        sidePanel.onCollapse = { [weak self] in self?.setSidePanel(visible: false) }
        sidePanel.fileTreeView.onFileClicked = { [weak self] path in self?.openFileTab(path: path) }
        sidePanel.gitStatusView.onFileClicked = { [weak self] path in self?.openDiffTab(path: path) }
        sidePanel.gitStatusView.onCommit = { [weak self] msg in
            guard let self = self, let session = self.activeSession, let manager = self.sessionManager else { return }
            Task {
                do {
                    try await manager.gitCommit(container: session, message: msg)
                    await self.refreshGitStatus()
                } catch {
                    self.sidebar.setStatus("✕ commit failed: \(error)")
                }
            }
        }
        sidePanel.gitStatusView.onPush = { [weak self] in
            guard let self = self, let session = self.activeSession, let manager = self.sessionManager else { return }
            Task {
                do {
                    try await manager.gitPush(container: session)
                    await self.refreshGitStatus()
                    self.sidebar.setStatus("Pushed")
                } catch {
                    self.sidebar.setStatus("✕ push failed: \(error)")
                }
            }
        }

        // Start with just sidebar + center. Side panel is added/removed by setSidePanel.
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(centerColumn)
        split.delegate = self
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        sidePanelVisible = false

        let container = NSView()
        container.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        window.contentView = container

        // Set sidebar width
        DispatchQueue.main.async { [weak self] in
            self?.split.setPosition(260, ofDividerAt: 0)
        }
    }

    /// Splash → connect → install main UI → list sessions.
    private func bootstrap() async {
        guard let loaded = TGVConfig.load() else {
            splash?.setError("No config — run `tgv init` first")
            return
        }

        let config = loaded
        self.config = config

        await attemptConnect(config: config)
    }

    private func attemptConnect(config: TGVConfig) async {
        splash?.setStatus("Connecting to \(config.sshTarget)…")
        splash?.hideRetry()

        let ssh = SSHManager(config: config)
        let manager = SessionManager(ssh: ssh, config: config)
        self.ssh = ssh
        self.sessionManager = manager

        do {
            try await ssh.connect()
            splash?.setStatus("Loading sessions…")

            installMainLayout()
            self.splash = nil
            showEmptyState()

            sidebar.setServer(config.sshTarget)
            await refreshSessions()
            await refreshMetrics()

            refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { await self?.refreshSessions() }
            }
            metricsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { await self?.refreshMetrics() }
            }
            gitStatusTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { await self?.refreshGitStatus() }
            }
        } catch {
            splash?.setError("✕ \(error)")
            splash?.showRetry { [weak self] in
                guard let self = self, let config = self.config else { return }
                Task { await self.attemptConnect(config: config) }
            }
        }
    }

    private func refreshSessions() async {
        guard let manager = sessionManager else { return }
        do {
            let sessions = try await manager.listSessions()
            sidebar.setSessions(sessions)
            let running = sessions.filter(\.running).count
            sidebar.setStatus("\(sessions.count) session(s), \(running) running")
            updateMenuBarTitle(running: running)
        } catch {
            sidebar.setStatus("✕ \(error)")
        }
    }

    private func refreshMetrics() async {
        guard let manager = sessionManager else { return }
        do {
            let metrics = try await manager.hostMetrics()
            sidebar.metricsView.update(metrics)
        } catch {
            sidebar.metricsView.setError()
        }
    }

    private func refreshGitStatus() async {
        guard let manager = sessionManager, let active = activeSession else { return }
        do {
            async let statusTask = manager.gitStatusRaw(container: active)
            async let logTask = manager.gitLogRaw(container: active, count: 20)
            async let filesTask = manager.fileListRaw(container: active)
            let (statusRaw, logRaw, filesRaw) = try await (statusTask, logTask, filesTask)

            let status = GitStatus.parse(statusRaw)
            let commits = GitStatus.parseLog(logRaw)
            sidePanel.gitStatusView.updateAll(status: status, commits: commits)

            let paths = filesRaw.components(separatedBy: "\n").filter { !$0.isEmpty }
            currentFilePaths = paths
            let tree = FileNode.buildTree(from: paths)
            sidePanel.fileTreeView.update(tree)

        } catch {
            sidePanel.gitStatusView.setError("git status failed")
            sidePanel.fileTreeView.setError("file list failed")
        }
    }

    private func updateMenuBarTitle(running: Int) {
        statusItem.button?.title = running > 0 ? "\(running)" : ""
    }

    // MARK: - Session pair management

    private func openSessionPair(_ session: Session) {
        if let existing = panes[session.name] {
            activate(session: session, panes: existing)
            return
        }
        guard let ssh = ssh, let manager = sessionManager, let config = config else { return }

        sidebar.setStatus("Preparing \(session.label)…")

        Task { [weak self] in
            do {
                try await manager.ensureTools(container: session.name)
            } catch {
                await MainActor.run {
                    self?.sidebar.setStatus("✕ tools setup failed: \(error)")
                }
                // Continue anyway — attach command has a zellij fallback
            }

            await MainActor.run {
                guard let self = self else { return }
                self.sidebar.setStatus("")

                let attachCmd = manager.attachCommand(container: session.name)
                let sshTarget = config.sshTarget

                let mainTab = TerminalTabView(sshTarget: sshTarget, command: attachCmd)

                let shellCmd = "docker exec -u dev -it -w /workspace/repo \(session.name) zsh"
                let shellTab = TerminalTabView(sshTarget: sshTarget, command: shellCmd)

                let panes = SessionPanes(main: mainTab, shell: shellTab)
                self.panes[session.name] = panes
                self.activate(session: session, panes: panes)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    for tab in panes.all { tab.connect() }
                }
            }
        }
    }

    private func activate(session: Session, panes pair: SessionPanes) {
        emptyStateSplash = nil
        setSidePanel(visible: true)

        // Swap main
        for sub in mainContainer.subviews { sub.removeFromSuperview() }
        pair.main.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.addSubview(pair.main)
        NSLayoutConstraint.activate([
            pair.main.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            pair.main.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            pair.main.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            pair.main.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),
        ])

        // Side panel: terminal tab gets the shell, files + git are native views
        sidePanel.terminalView = pair.shell

        activeSession = session.name
        sidebar.setSelected(session.id)
        centerHeader.setSession(session)
        window.title = "TGV — \(session.label)"
    }

    /// Show the gradient banner full-width as empty-state placeholder.
    /// Hides the side panel so the banner fills the whole content area.
    private func showEmptyState() {
        for sub in mainContainer.subviews { sub.removeFromSuperview() }
        let splash = SplashView(frame: .zero)
        splash.setStatus("Pick a session or create a new one")
        splash.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.addSubview(splash)
        NSLayoutConstraint.activate([
            splash.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            splash.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            splash.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            splash.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),
        ])
        emptyStateSplash = splash
        centerHeader.setSession(nil)
        sidePanel.clearAllTerminals()
        setSidePanel(visible: false)
        window.title = "TGV"
    }

    /// Toggle the right side panel by adding/removing it from the split view.
    private func setSidePanel(visible: Bool) {
        guard visible != sidePanelVisible else { return }
        sidePanelVisible = visible
        centerHeader.setSidePanelVisible(visible)

        if visible {
            split.addArrangedSubview(sidePanel)
            // Center holds its size; side panel absorbs window resize
            split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
            split.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 2)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let totalWidth = self.split.bounds.width
                self.split.setPosition(totalWidth - 380, ofDividerAt: 1)
            }
        } else {
            sidePanel.removeFromSuperview()
        }
    }

    private func killSession(_ session: Session) async {
        guard let manager = sessionManager else { return }
        // Tear down panes (close + remove all 4 terminal views)
        if let pair = panes.removeValue(forKey: session.name) {
            for tab in pair.all {
                tab.close()
                tab.removeFromSuperview()
            }
        }
        if activeSession == session.name {
            activeSession = nil
            sidebar.setSelected(nil)
            showEmptyState()
        }

        sidebar.setStatus("Killing \(session.label)…")
        do {
            try await manager.stop(name: session.name)
        } catch {
            sidebar.setStatus("✕ \(error)")
            return
        }
        await refreshSessions()
    }

    private func showNewSessionSheet() {
        guard let manager = sessionManager else { return }

        let sheet = NewSessionSheet(manager: manager,
            onStep: { [weak self] step in
                Task { @MainActor in
                    self?.emptyStateSplash?.setStatus(step)
                }
            },
            onBranchPicked: { [weak self] branch in
                Task { @MainActor in
                    // Show splash + temp row in sidebar as soon as branch is picked
                    if self?.emptyStateSplash == nil {
                        self?.showEmptyState()
                    }
                    self?.sidebar.setCreatingSession(branch: branch)
                }
            },
            onCreated: { [weak self] containerName in
                Task { await self?.handleNewSession(name: containerName) }
            }
        )
        newSessionSheet = sheet
        if let sheetWindow = sheet.window {
            window.beginSheet(sheetWindow) { _ in
                self.newSessionSheet = nil
            }
        }
    }

    private func handleNewSession(name: String) async {
        // Show banner with "preparing" message while the session boots
        if emptyStateSplash == nil {
            showEmptyState()
        }
        emptyStateSplash?.setStatus("Preparing session…")

        await refreshSessions()
        // Find the freshly created session and auto-attach
        guard let manager = sessionManager else { return }
        if let sessions = try? await manager.listSessions(),
           let created = sessions.first(where: { $0.name == name }) {
            emptyStateSplash?.setStatus("Attaching to \(created.label)…")
            openSessionPair(created)
        }
    }

    // MARK: - Main column tab management

    /// Switch the visible view in mainContainer to the tab with the given id.
    private func switchMainTab(id: String) {
        guard let session = activeSession, let pair = panes[session] else { return }

        for sub in mainContainer.subviews { sub.removeFromSuperview() }

        let view: NSView
        switch id {
        case "agent":
            view = pair.main
        case "edit":
            guard let edit = pair.edit else { return }
            view = edit
        default:
            return
        }

        view.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),
        ])
    }

    /// Open a file in nvim in the Edit tab, replacing any previously opened file.
    private func openFileTab(path: String) {
        guard let session = activeSession, let config = config else { return }
        let filename = (path as NSString).lastPathComponent

        // Close the previous edit terminal if any
        if let old = panes[session]?.edit {
            old.close()
            old.removeFromSuperview()
        }

        let cmd = "docker exec -u dev -it -w /workspace/repo \(session) nvim \(path)"
        let tab = TerminalTabView(sshTarget: config.sshTarget, command: cmd)
        panes[session]?.edit = tab

        centerHeader.setEditTitle(filename)
        centerHeader.selectTab(id: "edit")
        switchMainTab(id: "edit")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            tab.connect()
        }
    }

    /// Open a delta diff for a file in the Edit tab.
    private func openDiffTab(path: String) {
        guard let session = activeSession, let config = config else { return }
        let filename = (path as NSString).lastPathComponent

        // Close the previous edit terminal if any
        if let old = panes[session]?.edit {
            old.close()
            old.removeFromSuperview()
        }

        let cmd = "docker exec -u dev -it -w /workspace/repo \(session) tgv-diff \(path)"
        let tab = TerminalTabView(sshTarget: config.sshTarget, command: cmd)
        panes[session]?.edit = tab

        centerHeader.setEditTitle(filename)
        centerHeader.selectTab(id: "edit")
        switchMainTab(id: "edit")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            tab.connect()
        }
    }

    @objc private func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - NSSplitViewDelegate

extension AppDelegate: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 {
            return 220 // sidebar min width
        }
        // Right divider: center column needs at least 400px
        return splitView.arrangedSubviews[0].frame.width + splitView.dividerThickness + 400
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if dividerIndex == 0 {
            return 360 // sidebar max width
        }
        // Right divider: side panel needs at least 200px
        return splitView.bounds.width - 200
    }
}

// MARK: - Main entry

@main
struct TGVMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
