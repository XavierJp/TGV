import AppKit

/// A lightweight Cmd+P file picker panel.
/// Floats over the main window, fuzzy-matches file paths, opens on Enter.
final class FuzzyFinderPanel: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private let panel: NSPanel
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private let allFiles: [String]
    private var filtered: [String] = []

    init(files: [String], relativeTo parent: NSWindow) {
        self.allFiles = files
        self.filtered = files

        let width: CGFloat = 500
        let height: CGFloat = 340

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
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(srgbRed: 0x1e/255, green: 0x1f/255, blue: 0x2e/255, alpha: 1)
        panel.hasShadow = true

        super.init()

        setupUI()
    }

    private func setupUI() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        // Search field
        searchField.placeholderString = "Go to file…"
        searchField.font = AppFont.regular(14)
        searchField.focusRingType = .none
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.textColor = .labelColor
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let fieldBorder = NSBox()
        fieldBorder.boxType = .separator
        fieldBorder.translatesAutoresizingMaskIntoConstraints = false

        // Table
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = ""
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 24
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 0)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(fieldBorder)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            fieldBorder.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            fieldBorder.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fieldBorder.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fieldBorder.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: fieldBorder.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        panel.contentView = container
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        // Monitor for Escape and Enter
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.panel.isVisible else { return event }
            switch event.keyCode {
            case 53: // Escape
                self.dismiss()
                return nil
            case 36: // Enter
                self.confirmSelection()
                return nil
            case 125: // Down arrow
                self.moveSelection(by: 1)
                return nil
            case 126: // Up arrow
                self.moveSelection(by: -1)
                return nil
            default:
                return event
            }
        }
    }

    func dismiss() {
        panel.orderOut(nil)
        onDismiss?()
    }

    private func confirmSelection() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let path = filtered[row]
        panel.orderOut(nil)
        onSelect?(path)
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        var next = tableView.selectedRow + delta
        next = max(0, min(filtered.count - 1, next))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: - Fuzzy matching

    private func fuzzyMatch(query: String, in path: String) -> (Bool, Int) {
        guard !query.isEmpty else { return (true, 0) }
        let q = query.lowercased()
        let p = path.lowercased()
        var qi = q.startIndex
        var score = 0
        var prevMatched = false

        for ch in p {
            if qi < q.endIndex && ch == q[qi] {
                score += prevMatched ? 2 : 1  // consecutive bonus
                qi = q.index(after: qi)
                prevMatched = true
            } else {
                prevMatched = false
            }
        }
        let matched = qi == q.endIndex

        // Bonus: filename match (last component)
        let filename = (path as NSString).lastPathComponent.lowercased()
        if filename.contains(q) {
            score += 10
        }

        return (matched, score)
    }

    private func updateFilter() {
        let query = searchField.stringValue
        if query.isEmpty {
            filtered = allFiles
        } else {
            filtered = allFiles
                .compactMap { path -> (String, Int)? in
                    let (ok, score) = fuzzyMatch(query: query, in: path)
                    return ok ? (path, score) : nil
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
        }
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateFilter()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = filtered[row]
        let filename = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent

        let cell = NSView()
        cell.wantsLayer = true

        let nameLabel = NSTextField(labelWithString: filename)
        nameLabel.font = AppFont.medium(12)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let dirLabel = NSTextField(labelWithString: dir.isEmpty ? "" : dir)
        dirLabel.font = AppFont.regular(10)
        dirLabel.textColor = .secondaryLabelColor
        dirLabel.lineBreakMode = .byTruncatingHead
        dirLabel.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(nameLabel)
        cell.addSubview(dirLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            dirLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            dirLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
            dirLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}
