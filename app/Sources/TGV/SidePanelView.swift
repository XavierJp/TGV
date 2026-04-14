import AppKit

/// Right-hand side panel for a session.
/// Has a segmented header at the top with 3 tabs: Terminal / Files / Git.
/// Each tab hosts a TerminalTabView created by TGVApp per session.
final class SidePanelView: NSView {
    enum Tab: Int, CaseIterable {
        case terminal = 0
        case files = 1
        case git = 2
    }

    private let segmented = NSSegmentedControl(labels: ["Terminal", "Files", "Git"],
                                                trackingMode: .selectOne,
                                                target: nil, action: nil)
    private let collapseButton = NSButton()
    private let header = NSView()
    private let terminalContainer = NSView()
    private let filesContainer = NSView()
    private let gitContainer = NSView()

    /// Called when the collapse button is clicked. TGVApp hides the panel.
    var onCollapse: (() -> Void)?

    var terminalView: TerminalTabView? {
        didSet { swap(in: terminalContainer, old: oldValue, new: terminalView) }
    }

    let fileTreeView = FileTreeView()
    private var fileTreeInstalled = false

    let gitStatusView = GitStatusView()

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
        let bg = NSColor(srgbRed: 0x1a/255, green: 0x1b/255, blue: 0x26/255, alpha: 1)
        layer?.backgroundColor = bg.cgColor

        // Header with segmented control
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false

        segmented.segmentStyle = .capsule
        // Fit each segment to its label, don't stretch full width
        segmented.segmentDistribution = .fit
        segmented.target = self
        segmented.action = #selector(segmentChanged)
        segmented.selectedSegment = 0
        segmented.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(segmented)

        if let img = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Hide side panel") {
            collapseButton.image = img
        } else {
            collapseButton.title = "✕"
        }
        collapseButton.bezelStyle = .inline
        collapseButton.isBordered = false
        collapseButton.imagePosition = .imageOnly
        collapseButton.contentTintColor = .secondaryLabelColor
        collapseButton.target = self
        collapseButton.action = #selector(collapseTapped)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(collapseButton)

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(border)

        // Content containers
        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        filesContainer.translatesAutoresizingMaskIntoConstraints = false
        gitContainer.translatesAutoresizingMaskIntoConstraints = false
        filesContainer.isHidden = true
        gitContainer.isHidden = true

        // Install the native file tree in the files container
        fileTreeView.translatesAutoresizingMaskIntoConstraints = false
        filesContainer.addSubview(fileTreeView)

        // Install the native git status view in the git container
        gitStatusView.translatesAutoresizingMaskIntoConstraints = false
        gitContainer.addSubview(gitStatusView)

        // (scripts tab removed)

        addSubview(header)
        addSubview(terminalContainer)
        addSubview(filesContainer)
        addSubview(gitContainer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 40),

            segmented.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            segmented.centerXAnchor.constraint(equalTo: header.centerXAnchor),

            collapseButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            collapseButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            collapseButton.widthAnchor.constraint(equalToConstant: 22),
            collapseButton.heightAnchor.constraint(equalToConstant: 22),

            border.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            border.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            terminalContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            filesContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            filesContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            filesContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            filesContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            fileTreeView.topAnchor.constraint(equalTo: filesContainer.topAnchor),
            fileTreeView.leadingAnchor.constraint(equalTo: filesContainer.leadingAnchor),
            fileTreeView.trailingAnchor.constraint(equalTo: filesContainer.trailingAnchor),
            fileTreeView.bottomAnchor.constraint(equalTo: filesContainer.bottomAnchor),

            gitContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            gitContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            gitContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            gitContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            gitStatusView.topAnchor.constraint(equalTo: gitContainer.topAnchor),
            gitStatusView.leadingAnchor.constraint(equalTo: gitContainer.leadingAnchor),
            gitStatusView.trailingAnchor.constraint(equalTo: gitContainer.trailingAnchor),
            gitStatusView.bottomAnchor.constraint(equalTo: gitContainer.bottomAnchor),

        ])
    }

    @objc private func collapseTapped() {
        onCollapse?()
    }

    @objc private func segmentChanged() {
        guard let tab = Tab(rawValue: segmented.selectedSegment) else { return }
        terminalContainer.isHidden = tab != .terminal
        filesContainer.isHidden = tab != .files
        gitContainer.isHidden = tab != .git
    }

    private func swap(in container: NSView, old: TerminalTabView?, new: TerminalTabView?) {
        old?.removeFromSuperview()
        guard let tv = new else { return }
        tv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: container.topAnchor),
            tv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    func clearAllTerminals() {
        terminalView = nil
        // fileTreeView + gitStatusView are always present — content clears on next update
    }
}
