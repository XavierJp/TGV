import AppKit
import Core

/// Braille spinner frames shared by CreatingRow and SessionRow.
private let brailleFrames = ["⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"]

/// Left-hand sidebar:
/// - "+ New Session" button at the top
/// - Session list (each row has an always-visible trash icon)
/// - Divider
/// - Server (user@host)
/// - Host metrics (CPU / GPU / RAM / Disk)
/// - Status footer
final class SidebarView: NSView {
    var onSelectSession: ((Session) -> Void)?
    var onKillSession: ((Session) -> Void)?
    var onNewSession: (() -> Void)?

    private let newButton = NSButton(title: "  + New Session", target: nil, action: nil)
    private let listStack = NSStackView()
    private let scrollView = NSScrollView()

    private let serverLabel = NSTextField(labelWithString: "")
    let metricsView = HostMetricsView()
    private let statusLabel = NSTextField(labelWithString: "")

    private var sessions: [Session] = []
    private var selectedID: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        newButton.target = self
        newButton.action = #selector(newPressed)
        newButton.bezelStyle = .rounded
        newButton.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        newButton.alignment = .left
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

        serverLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        serverLabel.textColor = .secondaryLabelColor
        serverLabel.translatesAutoresizingMaskIntoConstraints = false
        serverLabel.lineBreakMode = .byTruncatingMiddle

        metricsView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 10)
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
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            newButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            newButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            newButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -8),

            flipped.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            listStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            divider.bottomAnchor.constraint(equalTo: serverLabel.topAnchor, constant: -10),
            divider.heightAnchor.constraint(equalToConstant: 1),

            serverLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            serverLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            serverLabel.bottomAnchor.constraint(equalTo: metricsView.topAnchor, constant: -10),

            metricsView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            metricsView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            metricsView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),

            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    func setServer(_ target: String) {
        serverLabel.stringValue = target
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func setSessions(_ sessions: [Session]) {
        self.sessions = sessions
        rebuildRows()
    }

    func setSelected(_ id: String?) {
        selectedID = id
        rebuildRows()
    }

    private func rebuildRows() {
        for row in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        if sessions.isEmpty {
            let empty = NSTextField(labelWithString: "No sessions yet")
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = .tertiaryLabelColor
            empty.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(empty)
            empty.leadingAnchor.constraint(equalTo: listStack.leadingAnchor, constant: 14).isActive = true
            return
        }

        for session in sessions {
            var row: SessionRow!
            row = SessionRow(
                session: session,
                selected: session.id == selectedID,
                onClick: { [weak self] s in self?.onSelectSession?(s) },
                onKill: { [weak self] s in self?.startKill(s, row: row) }
            )
            row.translatesAutoresizingMaskIntoConstraints = false
            listStack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: listStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: listStack.trailingAnchor).isActive = true
        }
    }

    private func startKill(_ session: Session, row: SessionRow) {
        row.setKilling()
        onKillSession?(session)
    }

    /// Show a temporary "creating" row at the top of the session list with a braille spinner.
    func setCreatingSession(branch: String) {
        let row = CreatingRow(branch: branch)
        row.translatesAutoresizingMaskIntoConstraints = false

        // Insert at the top
        if !listStack.arrangedSubviews.isEmpty {
            listStack.insertArrangedSubview(row, at: 0)
        } else {
            listStack.addArrangedSubview(row)
        }
        row.leadingAnchor.constraint(equalTo: listStack.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: listStack.trailingAnchor).isActive = true

        selectedID = nil
    }

    @objc private func newPressed() { onNewSession?() }
}

/// A temporary row shown while a session is being created.
private final class CreatingRow: NSView {
    private let spinnerLabel = NSTextField(labelWithString: "⠋")
    private var spinnerTimer: Timer?
    private var frame_ = 0

    init(branch: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.4).cgColor

        spinnerLabel.font = NSFont.systemFont(ofSize: 13)
        spinnerLabel.textColor = .systemOrange
        spinnerLabel.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: branch)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(spinnerLabel)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            spinnerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            spinnerLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: spinnerLabel.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.frame_ = (self.frame_ + 1) % brailleFrames.count
            self.spinnerLabel.stringValue = brailleFrames[self.frame_]
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        spinnerTimer?.invalidate()
    }
}

/// A clickable session row with trash icon or braille spinner.
final class SessionRow: NSView {
    let sessionID: String
    private let session: Session
    private let onClick: (Session) -> Void
    private let onKill: (Session) -> Void
    private let trackingArea: NSTrackingArea
    private var isHovering = false
    private let isSelected: Bool
    private let trashButton = NSButton()
    private let spinnerLabel = NSTextField(labelWithString: "")
    private var spinnerTimer: Timer?
    private var spinnerFrame = 0

    init(session: Session, selected: Bool,
         onClick: @escaping (Session) -> Void,
         onKill: @escaping (Session) -> Void) {
        self.session = session
        self.onClick = onClick
        self.onKill = onKill
        self.isSelected = selected
        self.trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: nil,
            userInfo: nil
        )
        self.sessionID = session.id
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 5
        updateBackground()

        let dot = NSTextField(labelWithString: "●")
        dot.font = NSFont.systemFont(ofSize: 11)
        dot.textColor = session.running ? .systemGreen : .tertiaryLabelColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: session.label)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

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

        spinnerLabel.font = NSFont.systemFont(ofSize: 13)
        spinnerLabel.textColor = .systemOrange
        spinnerLabel.translatesAutoresizingMaskIntoConstraints = false
        spinnerLabel.isHidden = true

        addSubview(dot)
        addSubview(label)
        addSubview(trashButton)
        addSubview(spinnerLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            trashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trashButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            trashButton.widthAnchor.constraint(equalToConstant: 20),
            trashButton.heightAnchor.constraint(equalToConstant: 20),
            spinnerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            spinnerLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTrackingArea(trackingArea)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Row click — anywhere except the trash button opens the session.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if trashButton.frame.insetBy(dx: -4, dy: -4).contains(point) {
            // Let the button's target/action handle it
            return super.mouseDown(with: event)
        }
        onClick(session)
    }

    @objc private func trashClicked() {
        setKilling()
        onKill(session)
    }

    /// Replace the trash icon with a braille spinner.
    func setKilling() {
        trashButton.isHidden = true
        spinnerLabel.isHidden = false
        spinnerFrame = 0
        spinnerLabel.stringValue = brailleFrames[0]
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.spinnerFrame = (self.spinnerFrame + 1) % brailleFrames.count
            self.spinnerLabel.stringValue = brailleFrames[self.spinnerFrame]
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateBackground()
    }

    private func updateBackground() {
        if isSelected {
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.4).cgColor
        } else if isHovering {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
