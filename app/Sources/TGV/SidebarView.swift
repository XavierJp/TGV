import AppKit
import Combine
import Core

/// Braille spinner frames used by session rows while CREATING or DELETING.
private let brailleFrames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]

/// Left-hand sidebar:
/// - "+" button pinned at the top of the sidebar, next to the traffic lights
/// - Session list (rendered from `SessionStore`; status drives dot + spinner)
/// - Divider
/// - Server (user@host)
/// - Host metrics (CPU / GPU / RAM / Disk)
/// - Status footer
final class SidebarView: NSView {
    var onSelectSession: ((SessionState) -> Void)?
    var onKillSession: ((SessionState) -> Void)?
    var onNewSession: (() -> Void)?

    private let newButton = NSButton()
    private let listStack = NSStackView()
    private let scrollView = NSScrollView()

    private let serverLabel = NSTextField(labelWithString: "")
    let metricsView = HostMetricsView()
    private let connectionWarning = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    private weak var store: SessionStore?
    private var selectedID: String?
    private var storeCancellables = Set<AnyCancellable>()
    private var transientStatus: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Session")?
            .withSymbolConfiguration(cfg)
        newButton.imagePosition = .imageOnly
        newButton.bezelStyle = .circular
        newButton.isBordered = true
        newButton.target = self
        newButton.action = #selector(newPressed)
        newButton.toolTip = "New Session"
        newButton.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.distribution = .fill
        listStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(listStack)
        scrollView.documentView = flipped

        serverLabel.font = AppFont.regular(11)
        serverLabel.textColor = .secondaryLabelColor
        serverLabel.translatesAutoresizingMaskIntoConstraints = false
        serverLabel.lineBreakMode = .byTruncatingMiddle

        metricsView.translatesAutoresizingMaskIntoConstraints = false

        connectionWarning.font = AppFont.medium(10)
        connectionWarning.textColor = .systemOrange
        connectionWarning.translatesAutoresizingMaskIntoConstraints = false
        connectionWarning.isHidden = true

        statusLabel.font = AppFont.regular(10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(newButton)
        addSubview(scrollView)
        addSubview(divider)
        addSubview(serverLabel)
        addSubview(metricsView)
        addSubview(connectionWarning)
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            // Pin the + button into the titlebar strip, just past the traffic lights.
            newButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            newButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 82),
            newButton.widthAnchor.constraint(equalToConstant: 22),
            newButton.heightAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: connectionWarning.topAnchor, constant: -4),

            flipped.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            listStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),

            connectionWarning.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            connectionWarning.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            connectionWarning.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -8),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            divider.bottomAnchor.constraint(equalTo: serverLabel.topAnchor, constant: -10),
            divider.heightAnchor.constraint(equalToConstant: 1),

            serverLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            serverLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            serverLabel.bottomAnchor.constraint(equalTo: metricsView.topAnchor, constant: -10),

            metricsView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            metricsView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            metricsView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    // MARK: - Public API

    func setServer(_ target: String) {
        serverLabel.stringValue = target
    }

    /// Temporary status string (e.g. "Committing…"), overrides the computed
    /// "N session(s)" footer until cleared (pass "").
    func setStatus(_ text: String) {
        transientStatus = text.isEmpty ? nil : text
        refreshFooter()
    }

    func bind(store: SessionStore) {
        storeCancellables.removeAll()
        self.store = store
        rebuildRows()
        refreshFooter()

        Publishers.CombineLatest(store.$orderedNames, store.$sessions)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.rebuildRows()
                self?.refreshFooter()
            }
            .store(in: &storeCancellables)

        store.$activeSessionName
            .receive(on: RunLoop.main)
            .sink { [weak self] name in
                self?.selectedID = name
                self?.rebuildRows()
            }
            .store(in: &storeCancellables)

        store.$heartbeat
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshFooter() }
            .store(in: &storeCancellables)

        store.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.setConnectionState(connected: connected)
            }
            .store(in: &storeCancellables)
    }

    private func setConnectionState(connected: Bool) {
        if connected {
            connectionWarning.isHidden = true
        } else {
            connectionWarning.stringValue = "Connection lost — data may be stale"
            connectionWarning.isHidden = false
        }
    }

    private func refreshFooter() {
        if let msg = transientStatus {
            statusLabel.stringValue = msg
            return
        }
        guard let store = store else {
            statusLabel.stringValue = ""
            return
        }
        let total = store.sessions.count
        let running = store.sessions.values.filter { $0.status == .running }.count
        var text = "\(total) session(s), \(running) running"
        if let t = store.sessionsRefreshedAt {
            let age = Date().timeIntervalSince(t)
            if age > SessionState.staleThreshold {
                text += " • ⟳ \(Int(age))s ago"
            }
        }
        statusLabel.stringValue = text
    }

    @objc private func newPressed() { onNewSession?() }

    /// Reconcile `listStack` with the store's ordered names. Reuses existing
    /// `SessionRow` instances when the id survives — tearing down all rows on
    /// every refresh steals first-responder from the center terminal whenever
    /// the 30s session-list poll fires.
    private func rebuildRows() {
        guard let store = store else {
            for v in listStack.arrangedSubviews {
                listStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
            return
        }

        if store.orderedNames.isEmpty {
            for v in listStack.arrangedSubviews {
                listStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
            let empty = NSTextField(labelWithString: "No sessions")
            empty.font = AppFont.regular(12)
            empty.textColor = .tertiaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(empty)
            empty.leadingAnchor.constraint(equalTo: listStack.leadingAnchor, constant: 14).isActive = true
            return
        }

        let existingRows: [String: SessionRow] = Dictionary(uniqueKeysWithValues:
            listStack.arrangedSubviews.compactMap { ($0 as? SessionRow).map { ($0.sessionID, $0) } }
        )
        let targetIDs = Set(store.orderedNames)

        // Drop rows that are no longer in the list (including the "No sessions" placeholder).
        for v in listStack.arrangedSubviews {
            if let row = v as? SessionRow {
                if !targetIDs.contains(row.sessionID) {
                    listStack.removeArrangedSubview(row)
                    row.removeFromSuperview()
                }
            } else {
                listStack.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
        }

        // Ensure rows exist in the correct order. Only insert/move when needed.
        for (idx, name) in store.orderedNames.enumerated() {
            guard let state = store.sessions[name] else { continue }
            if let existing = existingRows[name] {
                existing.setSelected(name == selectedID)
                if listStack.arrangedSubviews.firstIndex(of: existing) != idx {
                    listStack.removeArrangedSubview(existing)
                    listStack.insertArrangedSubview(existing, at: idx)
                }
            } else {
                let row = SessionRow(
                    state: state,
                    selected: name == selectedID,
                    onClick: { [weak self] s in self?.onSelectSession?(s) },
                    onKill: { [weak self] s in self?.onKillSession?(s) }
                )
                row.translatesAutoresizingMaskIntoConstraints = false
                listStack.insertArrangedSubview(row, at: idx)
                row.leadingAnchor.constraint(equalTo: listStack.leadingAnchor).isActive = true
                row.trailingAnchor.constraint(equalTo: listStack.trailingAnchor).isActive = true
            }
        }
    }

}

/// A session row. Renders its session's status reactively: the dot color and
/// spinner come straight from `state.$status`, the label from `state.$branch` +
/// `state.$displayName`.
final class SessionRow: NSView {
    let sessionID: String
    private let state: SessionState
    private let onClick: (SessionState) -> Void
    private let onKill: (SessionState) -> Void
    private let trackingArea: NSTrackingArea
    private var isHovering = false
    private var isSelected: Bool
    private let dot = NSTextField(labelWithString: "●")
    private let titleLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let trashButton = NSButton()
    private let spinnerLabel = NSTextField(labelWithString: "")
    private var spinnerTimer: Timer?
    private var spinnerFrame = 0
    private var cancellables = Set<AnyCancellable>()

    init(state: SessionState, selected: Bool,
         onClick: @escaping (SessionState) -> Void,
         onKill: @escaping (SessionState) -> Void) {
        self.state = state
        self.onClick = onClick
        self.onKill = onKill
        self.isSelected = selected
        self.trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: nil,
            userInfo: nil
        )
        self.sessionID = state.name
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5

        dot.font = AppFont.regular(11)
        dot.alignment = .center
        dot.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = AppFont.semibold(12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        branchLabel.font = AppFont.regular(10)
        branchLabel.textColor = .secondaryLabelColor
        branchLabel.lineBreakMode = .byTruncatingTail
        branchLabel.translatesAutoresizingMaskIntoConstraints = false

        if let img = NSImage(systemSymbolName: "trash", accessibilityDescription: "Kill session") {
            trashButton.image = img
        } else {
            trashButton.title = "✕"
        }
        trashButton.bezelStyle = .inline
        trashButton.isBordered = false
        trashButton.imagePosition = .imageOnly
        trashButton.contentTintColor = .secondaryLabelColor
        trashButton.target = self
        trashButton.action = #selector(trashClicked)
        trashButton.translatesAutoresizingMaskIntoConstraints = false

        spinnerLabel.font = AppFont.regular(13)
        spinnerLabel.textColor = .systemOrange
        spinnerLabel.translatesAutoresizingMaskIntoConstraints = false
        spinnerLabel.isHidden = true

        addSubview(dot)
        addSubview(titleLabel)
        addSubview(branchLabel)
        addSubview(trashButton)
        addSubview(spinnerLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            branchLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 14),
            branchLabel.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -6),
            branchLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            trashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trashButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: 20),
            trashButton.heightAnchor.constraint(equalToConstant: 20),
            spinnerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            spinnerLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTrackingArea(trackingArea)
        applyLabel()
        applyStatus()
        updateAppearance()

        state.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyStatus() }
            .store(in: &cancellables)

        Publishers.CombineLatest(state.$branch, state.$displayName)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.applyLabel() }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        spinnerTimer?.invalidate()
    }

    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        updateAppearance()
    }

    private func applyLabel() {
        let dn = state.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !dn.isEmpty {
            titleLabel.stringValue = dn
            branchLabel.attributedStringValue = Self.underlined(state.branch, font: branchLabel.font ?? AppFont.regular(10), color: .secondaryLabelColor)
            branchLabel.isHidden = false
        } else {
            // No explicit title — show the branch as the title line.
            titleLabel.stringValue = state.branch
            branchLabel.stringValue = ""
            branchLabel.isHidden = true
        }
    }

    private static func underlined(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
    }

    private func applyStatus() {
        switch state.status {
        case .running:
            dot.textColor = .systemGreen
            setSpinnerActive(false)
            trashButton.isHidden = false
        case .stopped:
            dot.textColor = .tertiaryLabelColor
            setSpinnerActive(false)
            trashButton.isHidden = false
        case .creating:
            dot.textColor = .systemYellow
            setSpinnerActive(true)
            trashButton.isHidden = true
        case .deleting:
            dot.textColor = .systemRed
            setSpinnerActive(true)
            trashButton.isHidden = true
        }
    }

    private func setSpinnerActive(_ active: Bool) {
        if active {
            spinnerLabel.isHidden = false
            if spinnerTimer == nil {
                spinnerFrame = 0
                spinnerLabel.stringValue = brailleFrames[0]
                spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.spinnerFrame = (self.spinnerFrame + 1) % brailleFrames.count
                    self.spinnerLabel.stringValue = brailleFrames[self.spinnerFrame]
                }
            }
        } else {
            spinnerLabel.isHidden = true
            spinnerTimer?.invalidate()
            spinnerTimer = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if trashButton.frame.insetBy(dx: -4, dy: -4).contains(point), !trashButton.isHidden {
            return super.mouseDown(with: event)
        }
        onClick(state)
    }

    @objc private func trashClicked() {
        onKill(state)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    private func updateAppearance() {
        if isSelected {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
            titleLabel.textColor = .controlAccentColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            titleLabel.textColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = .labelColor
        }
    }
}
