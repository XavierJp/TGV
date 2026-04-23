import AppKit
import Combine
import Core
import SwiftTerm

/// A file or diff tab in the main column — one terminal per open file.
private struct FileTab {
    let id: String                 // "file:<path>" or "diff:<path>"
    let label: String              // filename shown in the tab
    let terminal: TerminalTabView
}

/// Terminals attached to a session container.
private struct SessionPanes {
    let main: TerminalTabView      // abduco + codex (center area, "Agent" tab)
    let shell: TerminalTabView     // zsh in /workspace/repo (side: Terminal tab)
    var fileTabs: [FileTab] = []   // user-opened file/diff tabs in the center
    var activeTabID: String = "agent"

    var all: [TerminalTabView] {
        [main, shell] + fileTabs.map { $0.terminal }
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
    private var splitVC: NSSplitViewController!
    private var sidebarItem: NSSplitViewItem!
    private var sidePanelItem: NSSplitViewItem!
    private var centerColumn: NSView!
    private var sidePanelVisible = false
    private var isWindowFilled = false
    private var preFillSidebarCollapsed = false
    private var preFillSidePanelCollapsed = true

    private var config: TGVConfig?
    private var ssh: SSHManager?
    private var sessionManager: SessionManager?
    private var store: SessionStore?
    private var storeCancellables = Set<AnyCancellable>()
    private var activeStateCancellables = Set<AnyCancellable>()

    private var panes: [String: SessionPanes] = [:]
    private var fuzzyFinder: FuzzyFinderPanel?

    private var metricsTimer: Timer?
    private var reconnectTimer: Timer?
    private var newSessionSheet: NewSessionSheet?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.applicationIconImage = TrainIcon.makeAppIcon()
        setupMainMenu()
        setupMenuBar()
        setupWindow()
        installCmdPMonitor()
        Task { await bootstrap() }
    }

    /// Build the app's main menu bar. An Edit menu with standard Copy / Paste /
    /// Select All items is required so Cmd+C / Cmd+V / Cmd+A route through the
    /// responder chain to the first responder (the terminal view).
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "TGV")
        appMenu.addItem(withTitle: "About TGV", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide TGV", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit TGV", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        metricsTimer?.invalidate()
        reconnectTimer?.invalidate()
        store?.stop()
    }

    /// Intercept Cmd+P to show the native fuzzy file finder.
    private func installCmdPMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers == "p" else { return event }
            guard let self = self, self.store?.activeSessionName != nil else { return event }
            self.showFuzzyFinder()
            return nil
        }
    }

    private func showFuzzyFinder() {
        if let existing = fuzzyFinder {
            existing.dismiss()
            fuzzyFinder = nil
            return
        }

        let files = store?.activeSession?.filePaths ?? []
        let panel = FuzzyFinderPanel(files: files, relativeTo: window)
        panel.onSelect = { [weak self] path in
            self?.fuzzyFinder = nil
            self?.openFileTab(path: path)
        }
        panel.onDismiss = { [weak self] in
            self?.fuzzyFinder = nil
            self?.focusActiveMainTerminal()
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
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 800),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "TGV"
        window.backgroundColor = NSColor(srgbRed: 0x1a/255, green: 0x1b/255, blue: 0x26/255, alpha: 1)
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1060, height: 600)

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

    /// Build the 3-pane split layout using NSSplitViewController:
    /// sidebar (glass) | center (header + terminal) | inspector (glass)
    private func installMainLayout() {
        splitVC = NSSplitViewController()

        sidebar = SidebarView(frame: .zero)
        sidebar.onSelectSession = { [weak self] s in self?.openSessionPair(s) }
        sidebar.onKillSession = { [weak self] s in self?.killSession(s) }
        sidebar.onNewSession = { [weak self] in self?.showNewSessionSheet() }

        let sidebarVC = NSViewController()
        sidebarVC.view = sidebar
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 260
        splitVC.addSplitViewItem(sidebarItem)

        centerColumn = NSView()
        centerColumn.wantsLayer = true
        centerColumn.layer?.backgroundColor = NSColor(srgbRed: 0x1a/255, green: 0x1b/255, blue: 0x26/255, alpha: 1).cgColor

        centerHeader = CenterHeaderView(frame: .zero)
        centerHeader.translatesAutoresizingMaskIntoConstraints = false
        centerHeader.onShowSidePanel = { [weak self] in self?.setSidePanel(visible: true) }
        centerHeader.onSelectTab = { [weak self] id in self?.switchMainTab(id: id) }
        centerHeader.onCloseTab = { [weak self] id in self?.closeFileTab(id: id) }
        centerHeader.onToggleFillWindow = { [weak self] in self?.toggleWindowFill() }

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

        let centerVC = NSViewController()
        centerVC.view = centerColumn
        let centerItem = NSSplitViewItem(viewController: centerVC)
        centerItem.minimumThickness = 520
        splitVC.addSplitViewItem(centerItem)

        sidePanel = SidePanelView()
        sidePanel.onCollapse = { [weak self] in self?.setSidePanel(visible: false) }
        sidePanel.fileTreeView.onFileClicked = { [weak self] path in self?.openFileTab(path: path) }
        sidePanel.gitStatusView.onFileClicked = { [weak self] path in self?.openDiffTab(path: path) }
        sidePanel.gitStatusView.onCommitAndPush = { [weak self] msg in
            guard let self = self,
                  let session = self.store?.activeSessionName,
                  let manager = self.sessionManager else { return }
            Task {
                do {
                    self.sidebar.setStatus("Committing…")
                    try await manager.gitCommit(container: session, message: msg)
                    self.sidebar.setStatus("Pushing…")
                    try await manager.gitPush(container: session)
                    self.sidebar.setStatus("Creating PR…")
                    try await manager.gitCreatePR(container: session, title: msg)
                    await self.store?.refreshActive()
                    self.sidebar.setStatus("PR created")
                } catch {
                    await self.store?.refreshActive()
                    self.sidebar.setStatus("✕ \(error)")
                }
            }
        }

        let sidePanelVC = NSViewController()
        sidePanelVC.view = sidePanel
        sidePanelItem = NSSplitViewItem(inspectorWithViewController: sidePanelVC)
        sidePanelItem.minimumThickness = 280
        sidePanelItem.isCollapsed = true
        splitVC.addSplitViewItem(sidePanelItem)

        sidePanelVisible = false

        // Swap the window's content from the splash container to the split.
        // `contentViewController` replaces contentView and drives sizing via
        // the VC's preferredContentSize. Setting that pins the content to a
        // fixed size and breaks edge-drag resize — switch contentView instead.
        window.contentView = splitVC.view

        let toolbar = NSToolbar(identifier: "main")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
    }

    /// Splash → connect → install main UI → wire the store.
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

            let store = SessionStore(manager: manager, repoURL: config.repoURL)
            self.store = store
            sidebar.bind(store: store)

            // Menubar counter follows the store's running-session count.
            store.$sessions
                .map { sessions in sessions.values.filter { $0.status == .running }.count }
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] running in self?.updateMenuBarTitle(running: running) }
                .store(in: &storeCancellables)

            // When the store loses its connection, schedule SSH reconnection.
            store.$isConnected
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] connected in
                    if !connected { self?.startReconnectTimer() }
                }
                .store(in: &storeCancellables)

            store.start()
            await refreshMetrics()

            metricsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { await self?.refreshMetrics() }
            }
        } catch {
            splash?.setError("✕ \(error)")
            splash?.showRetry { [weak self] in
                guard let self = self, let config = self.config else { return }
                Task { await self.attemptConnect(config: config) }
            }
        }
    }

    private func refreshMetrics() async {
        guard let manager = sessionManager else { return }
        do {
            let metrics = try await manager.hostMetrics()
            sidebar.metricsView.update(metrics)
        } catch {
            // Keep showing last metrics on failure — store.isConnected covers the warning.
            startReconnectTimer()
        }
    }

    // MARK: - Connection recovery

    private func startReconnectTimer() {
        guard reconnectTimer == nil else { return }
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.attemptReconnect() }
        }
    }

    private func attemptReconnect() async {
        guard let ssh = ssh else { return }
        await ssh.resetConnection()
        do {
            try await ssh.connect()
            await store?.refreshSessionList()
            await store?.refreshActive()
            await refreshMetrics()
            reconnectTimer?.invalidate()
            reconnectTimer = nil
        } catch {
            // Still down — timer will retry.
        }
    }

    private func updateMenuBarTitle(running: Int) {
        statusItem.button?.title = running > 0 ? "\(running)" : ""
    }

    // MARK: - Active session dispatch

    private func openSessionPair(_ state: SessionState) {
        activeStateCancellables.removeAll()
        store?.setActive(state.name)
        centerHeader.bind(state: state)
        sidePanel.bind(state: state)

        applyStatus(state: state)

        // React to status transitions (e.g. CREATING → RUNNING) while this
        // session stays active. Ignore the immediate emission — applyStatus has
        // already handled the current value above.
        state.$status
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak state] _ in
                guard let self = self, let state = state else { return }
                guard self.store?.activeSessionName == state.name else { return }
                self.applyStatus(state: state)
            }
            .store(in: &activeStateCancellables)

        // Safety net: the 3s git refresh rebuilds GitStatusView's stack and
        // FileTreeView's NSOutlineView data, and one of those steals first
        // responder even though terminalView is a sibling, not a child. Re-
        // focus the terminal after each refresh unless the user has clicked
        // into another real view (text field, etc.).
        state.$gitRefreshedAt
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak state] _ in
                guard let self = self, let state = state else { return }
                guard self.store?.activeSessionName == state.name else { return }
                self.restoreTerminalFocusIfUnclaimed()
            }
            .store(in: &activeStateCancellables)

        window.title = "TGV — \(state.label)"
    }

    /// Put first-responder back on the active main terminal if the current
    /// responder is the window itself, nil, or a view inside the file-tree /
    /// git-status refresh path. Leaves real user-grabbed responders alone.
    private func restoreTerminalFocusIfUnclaimed() {
        guard let session = store?.activeSessionName, panes[session] != nil else { return }
        let fr = window.firstResponder
        if fr == nil || fr === window {
            focusActiveMainTerminal()
        }
    }

    private func applyStatus(state: SessionState) {
        switch state.status {
        case .running:
            attachTerminals(state)
        case .creating, .deleting, .stopped:
            showStatusSplash(for: state)
        }
    }

    private func attachTerminals(_ state: SessionState) {
        if let existing = panes[state.name] {
            activate(state: state, panes: existing)
            return
        }
        guard let manager = sessionManager, let ssh = ssh else { return }

        // SSH PTY transport (Citadel) instead of mosh. Reasons:
        //  - mosh-client activates alt-screen on init (from xterm-256color's
        //    smcup) which disables SwiftTerm's scrollback buffer.
        //  - mosh uses absolute-positioning frame-buffer painting, so even in
        //    main buffer no content ever scrolls into scrollback history.
        // Session persistence (the main reason to use mosh) is already handled
        // by abduco on the remote side — a dropped SSH just reattaches.
        let attachCmd = SessionManager.joinShellCommand(manager.attachArgs(container: state.name))
        let shellCmd = SessionManager.joinShellCommand(manager.shellArgs(container: state.name))

        let mainTab = TerminalTabView(ssh: ssh, command: attachCmd)
        let shellTab = TerminalTabView(ssh: ssh, command: shellCmd)

        let sessionPanes = SessionPanes(main: mainTab, shell: shellTab)
        panes[state.name] = sessionPanes
        activate(state: state, panes: sessionPanes)

        // Connect once the view hierarchy has laid out. Scheduling on the next
        // runloop tick (vs. an arbitrary delay) guarantees terminalView.bounds is
        // populated; SwiftTerm's sizeChanged delegate covers any later reflow.
        window.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.async {
            for tab in sessionPanes.all { tab.connect() }
        }
    }

    private func activate(state: SessionState, panes pair: SessionPanes) {
        emptyStateSplash?.detachLog()
        emptyStateSplash = nil
        setSidePanel(visible: true, animated: false)

        switchMainTab(id: pair.activeTabID)
        sidePanel.terminalView = pair.shell
    }

    /// Show the gradient splash with a live status log for sessions that aren't
    /// RUNNING. Subsequent transitions to `.running` will rebuild this pane via
    /// the status subscription in `openSessionPair`.
    private func showStatusSplash(for state: SessionState) {
        for sub in mainContainer.subviews { sub.removeFromSuperview() }
        centerHeader.setTabs([], activeID: "agent")
        sidePanel.clearAllTerminals()
        setSidePanel(visible: false)

        let splash = SplashView(frame: .zero)
        splash.translatesAutoresizingMaskIntoConstraints = false
        switch state.status {
        case .creating:
            splash.setStatus("Preparing \(state.label)…")
        case .deleting:
            splash.setStatus("Stopping \(state.label)…")
        case .stopped:
            splash.setStatus("\(state.label) — stopped")
        case .running:
            splash.setStatus(state.label)
        }
        mainContainer.addSubview(splash)
        NSLayoutConstraint.activate([
            splash.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            splash.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            splash.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            splash.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),
        ])
        splash.attachLog(state.$statusLog)
        emptyStateSplash = splash
    }

    /// Banner with no bound session.
    private func showEmptyState() {
        for sub in mainContainer.subviews { sub.removeFromSuperview() }
        let splash = SplashView(frame: .zero)
        splash.setStatus("")
        splash.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.addSubview(splash)
        NSLayoutConstraint.activate([
            splash.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            splash.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            splash.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            splash.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),
        ])
        emptyStateSplash = splash
        centerHeader.bind(state: nil)
        sidePanel.bind(state: nil)
        sidePanel.clearAllTerminals()
        setSidePanel(visible: false)
        window.title = "TGV"
    }

    /// Double-click on the center header toggles "fill window": collapses both
    /// the sidebar and the side panel to give the center pane the full window
    /// width. A second toggle restores the prior collapse state of each.
    private func toggleWindowFill() {
        if isWindowFilled {
            sidebarItem.animator().isCollapsed = preFillSidebarCollapsed
            setSidePanel(visible: !preFillSidePanelCollapsed)
            isWindowFilled = false
        } else {
            preFillSidebarCollapsed = sidebarItem.isCollapsed
            preFillSidePanelCollapsed = sidePanelItem.isCollapsed
            sidebarItem.animator().isCollapsed = true
            setSidePanel(visible: false)
            isWindowFilled = true
        }
        focusActiveMainTerminal()
    }

    private func setSidePanel(visible: Bool, animated: Bool = true) {
        guard visible != sidePanelVisible else { return }
        sidePanelVisible = visible
        centerHeader.setSidePanelVisible(visible)
        if animated {
            sidePanelItem.animator().isCollapsed = !visible
        } else {
            sidePanelItem.isCollapsed = !visible
        }
    }

    private func killSession(_ state: SessionState) {
        // Tear down cached terminal panes immediately so we don't leave dead PTYs.
        if let pair = panes.removeValue(forKey: state.name) {
            for tab in pair.all {
                tab.close()
                tab.removeFromSuperview()
            }
        }
        // If we were viewing this session, drop to empty state before flipping
        // status to DELETING — otherwise the status-subscription would briefly
        // swap in the "Stopping…" splash on top of our teardown.
        if store?.activeSessionName == state.name {
            activeStateCancellables.removeAll()
            store?.setActive(nil)
            showEmptyState()
        }
        store?.kill(name: state.name)
    }

    private func showNewSessionSheet() {
        guard let store = store else { return }

        let sheet = NewSessionSheet { [weak self] title, prompt in
            Task { @MainActor in
                guard let self = self else { return }
                let state = store.spawn(title: title, prompt: prompt)
                // Select the new session so its splash + log becomes visible.
                self.openSessionPair(state)
            }
        }
        newSessionSheet = sheet
        if let sheetWindow = sheet.window {
            window.beginSheet(sheetWindow) { _ in
                self.newSessionSheet = nil
            }
        }
    }

    // MARK: - Main column tab management

    /// Swap the view mounted in `mainContainer` to the tab with this id and
    /// reflect the selection in the header.
    private func switchMainTab(id: String) {
        guard let session = store?.activeSessionName, var pair = panes[session] else { return }

        let view: NSView
        if id == "agent" {
            view = pair.main
        } else if let tab = pair.fileTabs.first(where: { $0.id == id }) {
            view = tab.terminal
        } else {
            return
        }

        pair.activeTabID = id
        panes[session] = pair

        for sub in mainContainer.subviews { sub.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        mainContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: mainContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: mainContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: mainContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: mainContainer.bottomAnchor),
        ])

        refreshHeaderTabs(session: session)

        // viewDidMoveToWindow handles the re-parent case, but explicit focus
        // covers same-tab re-clicks and panel animations that don't re-parent.
        DispatchQueue.main.async { [weak view] in
            (view as? TerminalTabView)?.focusTerminal()
        }
    }

    /// Focus the terminal currently mounted in the center pane. Used after
    /// modal panels (fuzzy finder) dismiss to return keystrokes to the tab.
    private func focusActiveMainTerminal() {
        guard let session = store?.activeSessionName, let pair = panes[session] else { return }
        let view: TerminalTabView
        if pair.activeTabID == "agent" {
            view = pair.main
        } else if let tab = pair.fileTabs.first(where: { $0.id == pair.activeTabID }) {
            view = tab.terminal
        } else {
            view = pair.main
        }
        view.focusTerminal()
    }

    private func refreshHeaderTabs(session: String) {
        guard let pair = panes[session] else { return }
        var items: [CenterHeaderView.TabItem] = [
            .init(id: "agent", label: "Agent", closable: false)
        ]
        for tab in pair.fileTabs {
            items.append(.init(id: tab.id, label: tab.label, closable: true))
        }
        centerHeader.setTabs(items, activeID: pair.activeTabID)
    }

    private func openFileTab(path: String) {
        openOrFocusTab(id: "file:\(path)", path: path) { session in
            ["docker", "exec", "-u", "dev", "-it", "-w", "/workspace/repo", session, "nvim", path]
        }
    }

    private func openDiffTab(path: String) {
        openOrFocusTab(id: "diff:\(path)", path: path) { session in
            ["docker", "exec", "-u", "dev", "-it", "-w", "/workspace/repo", session, "tgv-diff", path]
        }
    }

    private func openOrFocusTab(id: String, path: String, makeArgs: (String) -> [String]) {
        guard let session = store?.activeSessionName,
              let config = config,
              var pair = panes[session] else { return }

        // If a tab for this path+kind already exists, just focus it.
        if pair.fileTabs.contains(where: { $0.id == id }) {
            switchMainTab(id: id)
            return
        }

        let label = (path as NSString).lastPathComponent
        let terminal = TerminalTabView(sshTarget: config.sshTarget, args: makeArgs(session))
        pair.fileTabs.append(FileTab(id: id, label: label, terminal: terminal))
        panes[session] = pair

        switchMainTab(id: id)

        DispatchQueue.main.async {
            terminal.connect()
        }
    }

    private func closeFileTab(id: String) {
        guard let session = store?.activeSessionName, var pair = panes[session] else { return }
        guard let idx = pair.fileTabs.firstIndex(where: { $0.id == id }) else { return }

        let removed = pair.fileTabs.remove(at: idx)
        removed.terminal.close()
        removed.terminal.removeFromSuperview()

        // If the closed tab was active, fall back to the neighbor on the left
        // (or agent when no file tabs remain).
        if pair.activeTabID == id {
            if idx > 0 {
                pair.activeTabID = pair.fileTabs[idx - 1].id
            } else if let first = pair.fileTabs.first {
                pair.activeTabID = first.id
            } else {
                pair.activeTabID = "agent"
            }
        }

        panes[session] = pair
        switchMainTab(id: pair.activeTabID)
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

// MARK: - Main entry

@main
struct TGVMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--export-iconset"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            do {
                try IconExport.writeIconset(to: dir)
                FileHandle.standardOutput.write(Data("wrote iconset to \(dir.path)\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("iconset export failed: \(error)\n".utf8))
                exit(1)
            }
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
