import AppKit

/// Cmd+P file picker.
///
/// Floats over the main window, fuzzy-matches file paths with character-level
/// highlighting, and opens the selected file on Enter. Matched characters are
/// rendered in the accent color so the user can see *why* a path matched.
final class FuzzyFinderPanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private let panel: NSPanel
    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No matches")
    private let countLabel = NSTextField(labelWithString: "")

    private struct Match {
        let path: String
        let positions: Set<String.Index>   // matched positions in the ORIGINAL path
        let score: Int
    }

    private let allFiles: [String]
    private var filtered: [Match] = []
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    // Visual tokens — tuned to the app's TokyoNight-ish palette.
    private static let bgColor      = NSColor(srgbRed: 0x1e/255, green: 0x1f/255, blue: 0x2e/255, alpha: 1)
    private static let borderColor  = NSColor(srgbRed: 0x2f/255, green: 0x30/255, blue: 0x43/255, alpha: 1)
    private static let accentColor  = NSColor(srgbRed: 0x7a/255, green: 0xa2/255, blue: 0xf7/255, alpha: 1)
    private static let selectionBg  = NSColor(srgbRed: 0x7a/255, green: 0xa2/255, blue: 0xf7/255, alpha: 0.18)

    init(files: [String], relativeTo parent: NSWindow) {
        self.allFiles = files
        self.filtered = files.map { Match(path: $0, positions: [], score: 0) }

        let width: CGFloat = 560
        let height: CGFloat = 420

        let parentFrame = parent.frame
        let x = parentFrame.midX - width / 2
        let y = parentFrame.midY + parentFrame.height * 0.15 - height / 2

        panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        // Transparent window + opaque contentView gives us proper rounded corners
        // (clipped by the contentView's layer mask) while keeping the system shadow.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        super.init()

        setupUI()
    }

    private func setupUI() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = Self.bgColor.cgColor
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = Self.borderColor.cgColor

        // Search icon (SF Symbol, macOS 11+)
        if let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) {
            searchIcon.image = img
            searchIcon.contentTintColor = .tertiaryLabelColor
        }
        searchIcon.translatesAutoresizingMaskIntoConstraints = false

        // Search field
        searchField.placeholderString = "Go to file…"
        searchField.font = AppFont.regular(15)
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.textColor = .labelColor
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let fieldBorder = NSBox()
        fieldBorder.boxType = .custom
        fieldBorder.borderWidth = 0
        fieldBorder.fillColor = Self.borderColor
        fieldBorder.translatesAutoresizingMaskIntoConstraints = false

        // Table
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 30
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        // .regular lets clicks + arrow keys update selection; the default blue pill
        // is suppressed by PillRowView.drawSelection, which draws our own shape.
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.style = .plain
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

        // Empty state
        emptyLabel.font = AppFont.regular(12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        // Footer
        let footerBorder = NSBox()
        footerBorder.boxType = .custom
        footerBorder.borderWidth = 0
        footerBorder.fillColor = Self.borderColor
        footerBorder.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = AppFont.regular(10)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchIcon)
        container.addSubview(searchField)
        container.addSubview(fieldBorder)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        container.addSubview(footerBorder)
        container.addSubview(countLabel)

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            searchIcon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 14),
            searchIcon.heightAnchor.constraint(equalToConstant: 14),

            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            fieldBorder.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            fieldBorder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fieldBorder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fieldBorder.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: fieldBorder.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerBorder.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footerBorder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerBorder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerBorder.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -6),
            footerBorder.heightAnchor.constraint(equalToConstant: 1),

            countLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            countLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
        ])

        panel.contentView = container
        updateCount()
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        // Register the keyDown monitor only once per show/dismiss cycle —
        // AppKit does NOT auto-remove it when the panel closes, so we hold the
        // returned token and tear it down in dismiss().
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self, self.panel.isVisible else { return event }
                return self.handleKeyDown(event)
            }
        }
        // Click outside / app switch → panel resigns key → dismiss.
        if resignObserver == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        guard panel.isVisible || keyMonitor != nil || resignObserver != nil else { return }
        panel.orderOut(nil)
        teardownObservers()
        onDismiss?()
    }

    private func teardownObservers() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        if let o = resignObserver {
            NotificationCenter.default.removeObserver(o)
            resignObserver = nil
        }
    }

    deinit {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
        }
        if let o = resignObserver {
            NotificationCenter.default.removeObserver(o)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Ctrl/Cmd+J / Ctrl/Cmd+K as vim-style Down/Up, in addition to arrows.
        if event.modifierFlags.contains(.control) || event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "j", "n":
                moveSelection(by: 1)
                return nil
            case "k", "p":
                moveSelection(by: -1)
                return nil
            default:
                break
            }
        }
        switch event.keyCode {
        case 53: // Escape
            dismiss()
            return nil
        case 36, 76: // Enter, keypad Enter
            confirmSelection()
            return nil
        case 125: // Down
            moveSelection(by: 1)
            return nil
        case 126: // Up
            moveSelection(by: -1)
            return nil
        default:
            return event
        }
    }

    private func confirmSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let path = filtered[row].path
        // Tear down observers BEFORE orderOut so the resign-key notification
        // doesn't fire onDismiss in addition to onSelect.
        teardownObservers()
        panel.orderOut(nil)
        onSelect?(path)
    }

    @objc private func rowClicked() {
        // Single click just tracks the selection — NSTableView handles that for us.
        // This stub exists so doubleAction works; keeping action/doubleAction aligned
        // stops AppKit from ignoring double-click detection on clickable rows.
    }

    @objc private func rowDoubleClicked() {
        confirmSelection()
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow
        let base = current < 0 ? 0 : current
        var next = base + delta
        next = max(0, min(filtered.count - 1, next))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: - Fuzzy matching

    /// Subsequence fuzzy match. Returns score + matched character positions in `path`,
    /// or nil if the query isn't a subsequence of the path (case-insensitive).
    /// Scoring rewards consecutive matches and a bonus when the literal query appears
    /// as a substring of the filename.
    private func fuzzyMatch(query: String, in path: String) -> (score: Int, positions: Set<String.Index>)? {
        if query.isEmpty { return (0, []) }
        let q = query.lowercased()
        let pLower = path.lowercased()
        var positions: [String.Index] = []
        var qIdx = q.startIndex
        var score = 0
        var prevMatched = false

        var pi = pLower.startIndex
        var pathIdx = path.startIndex
        while pi < pLower.endIndex && qIdx < q.endIndex {
            if pLower[pi] == q[qIdx] {
                positions.append(pathIdx)
                score += prevMatched ? 3 : 1
                qIdx = q.index(after: qIdx)
                prevMatched = true
            } else {
                prevMatched = false
            }
            pi = pLower.index(after: pi)
            pathIdx = path.index(after: pathIdx)
        }
        guard qIdx == q.endIndex else { return nil }

        // Filename substring bonus — huge weight so name matches rank first.
        let filename = (path as NSString).lastPathComponent.lowercased()
        if filename.contains(q) { score += 20 }
        // Shorter paths tend to be more relevant; cheap tiebreak.
        score -= path.count / 10

        return (score, Set(positions))
    }

    private func updateFilter() {
        let query = searchField.stringValue
        if query.isEmpty {
            filtered = allFiles.map { Match(path: $0, positions: [], score: 0) }
        } else {
            filtered = allFiles.compactMap { path -> Match? in
                guard let m = fuzzyMatch(query: query, in: path) else { return nil }
                return Match(path: path, positions: m.positions, score: m.score)
            }
            .sorted { $0.score > $1.score }
        }
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        emptyLabel.isHidden = !filtered.isEmpty || query.isEmpty
        updateCount()
    }

    private func updateCount() {
        let total = allFiles.count
        let shown = filtered.count
        if shown == total {
            countLabel.stringValue = "\(total) files"
        } else {
            countLabel.stringValue = "\(shown) of \(total)"
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateFilter()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PillRowView(fill: Self.selectionBg)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let match = filtered[row]
        let cell = NSView()

        let nameLabel = NSTextField(labelWithAttributedString: attributedFilename(for: match))
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let dirLabel = NSTextField(labelWithAttributedString: attributedDirectory(for: match))
        dirLabel.lineBreakMode = .byTruncatingHead
        dirLabel.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(nameLabel)
        cell.addSubview(dirLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16),
            nameLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: dirLabel.leadingAnchor, constant: -12),

            dirLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16),
            dirLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    // MARK: - Attributed rendering

    private func attributedFilename(for match: Match) -> NSAttributedString {
        let path = match.path
        let filename = (path as NSString).lastPathComponent
        let filenameStart = path.index(path.endIndex, offsetBy: -filename.count)

        let base: [NSAttributedString.Key: Any] = [
            .font: AppFont.medium(13),
            .foregroundColor: NSColor.labelColor,
        ]
        let attr = NSMutableAttributedString(string: filename, attributes: base)
        highlight(positions: match.positions, path: path, start: filenameStart, onto: attr, base: base)
        return attr
    }

    private func attributedDirectory(for match: Match) -> NSAttributedString {
        let path = match.path
        let dir = (path as NSString).deletingLastPathComponent
        guard !dir.isEmpty else { return NSAttributedString(string: "") }

        let base: [NSAttributedString.Key: Any] = [
            .font: AppFont.regular(11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let attr = NSMutableAttributedString(string: dir, attributes: base)
        highlight(positions: match.positions, path: path, start: path.startIndex, onto: attr, base: base)
        return attr
    }

    /// Apply an accent color + bold weight to the characters in `attr` that correspond
    /// to matched positions in the original `path`, starting from `start`. Walking in
    /// UTF-16 units keeps the NSRange maths correct for multi-unit scalars.
    private func highlight(
        positions: Set<String.Index>,
        path: String,
        start: String.Index,
        onto attr: NSMutableAttributedString,
        base: [NSAttributedString.Key: Any]
    ) {
        guard !positions.isEmpty else { return }
        let baseFont = (base[.font] as? NSFont) ?? AppFont.regular(13)
        let accentFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let attrLen = attr.length

        var idx = start
        var utf16Offset = 0
        while idx < path.endIndex && utf16Offset < attrLen {
            let charUTF16 = path[idx].utf16.count
            if positions.contains(idx) {
                let range = NSRange(location: utf16Offset, length: charUTF16)
                if range.upperBound <= attrLen {
                    attr.addAttribute(.foregroundColor, value: Self.accentColor, range: range)
                    attr.addAttribute(.font, value: accentFont, range: range)
                }
            }
            utf16Offset += charUTF16
            idx = path.index(after: idx)
        }
    }
}

/// Row view that draws a rounded selection pill instead of the default blue bar.
private final class PillRowView: NSTableRowView {
    private let fill: NSColor

    init(fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        self.fill = .clear
        super.init(coder: coder)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let inset = bounds.insetBy(dx: 6, dy: 0)
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        fill.setFill()
        path.fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent — let the panel background show through.
    }
}
