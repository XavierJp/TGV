import AppKit
import Core

/// New-session picker. Lists:
///   ⊕ Random branch  (default)
///   ⊕ Custom name    (opens input modal)
///   <existing branches>
/// Up/down to select, Enter to create, Esc to cancel.
final class NewSessionSheet: NSWindowController, NSTableViewDelegate, NSTableViewDataSource {
    private let manager: SessionManager
    private let onStep: (String) -> Void
    private let onBranchPicked: (String) -> Void
    private let onCreated: (String) -> Void

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    private enum Item {
        case random
        case custom
        case branch(String)

        var displayTitle: String {
            switch self {
            case .random: return "⊕  New branch (random name)"
            case .custom: return "⊕  New branch (custom name)"
            case .branch(let b): return "    \(b)"
            }
        }

        var searchKey: String {
            switch self {
            case .random: return "random new"
            case .custom: return "custom new"
            case .branch(let b): return b
            }
        }
    }

    private var allItems: [Item] = [.random, .custom]
    private var filteredItems: [Item] = [.random, .custom]

    init(manager: SessionManager,
         onStep: @escaping (String) -> Void = { _ in },
         onBranchPicked: @escaping (String) -> Void = { _ in },
         onCreated: @escaping (String) -> Void) {
        self.manager = manager
        self.onStep = onStep
        self.onBranchPicked = onBranchPicked
        self.onCreated = onCreated

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "New Session"
        super.init(window: window)

        buildUI()
        Task { await loadBranches() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "New Session")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search branches…"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self

        // Table
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.style = .inset
        tableView.allowsEmptySelection = false
        tableView.target = self
        tableView.doubleAction = #selector(create)
        tableView.delegate = self
        tableView.dataSource = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 6
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor

        createButton.target = self
        createButton.action = #selector(create)
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1B}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true

        contentView.addSubview(title)
        contentView.addSubview(searchField)
        contentView.addSubview(scrollView)
        contentView.addSubview(spinner)
        contentView.addSubview(statusLabel)
        contentView.addSubview(cancelButton)
        contentView.addSubview(createButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            searchField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            searchField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: createButton.topAnchor, constant: -14),

            spinner.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            spinner.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),

            statusLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            statusLabel.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -8),

            createButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            createButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor, constant: -8),
        ])

        // Initial selection = first item (Random)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self?.searchField)
        }
    }

    private func loadBranches() async {
        do {
            let branches = try await manager.listBranches()
            var items: [Item] = [.random, .custom]
            items.append(contentsOf: branches.map { .branch($0) })
            allItems = items
            filteredItems = items
            tableView.reloadData()
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } catch {
            statusLabel.stringValue = "Could not load branches: \(error)"
        }
    }

    private func applyFilter(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            filteredItems = allItems
        } else {
            filteredItems = allItems.filter { $0.searchKey.lowercased().contains(q) }
        }
        tableView.reloadData()
        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { filteredItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.font = NSFont.systemFont(ofSize: 13)
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let item = filteredItems[row]
        cell.textField?.stringValue = item.displayTitle
        return cell
    }

    // MARK: - Actions

    @objc private func cancel() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    @objc private func create() {
        guard tableView.selectedRow >= 0, tableView.selectedRow < filteredItems.count else {
            return
        }
        let item = filteredItems[tableView.selectedRow]
        switch item {
        case .random:
            spawn(branch: SessionManager.randomBranchName())
        case .custom:
            promptCustomBranch()
        case .branch(let b):
            spawn(branch: b)
        }
    }

    private func promptCustomBranch() {
        let alert = NSAlert()
        alert.messageText = "Branch name"
        alert.informativeText = "Enter a name for the new branch."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "feature/my-thing"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let branch = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return }
        spawn(branch: branch)
    }

    private func spawn(branch: String) {
        // Notify that a branch was picked (sidebar shows temp row + splash)
        onBranchPicked(branch)
        onStep("Spawning on \(branch)…")
        // Close the sheet — progress shows on the splash screen behind it
        window?.sheetParent?.endSheet(window!, returnCode: .OK)

        Task {
            do {
                let name = try await manager.spawn(branch: branch) { [weak self] step in
                    Task { @MainActor in
                        self?.onStep(step)
                    }
                }
                await MainActor.run {
                    self.onCreated(name)
                }
            } catch {
                await MainActor.run {
                    self.onStep("✕ \(error)")
                }
            }
        }
    }
}

// MARK: - Search filtering

extension NewSessionSheet: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Pass arrow keys from search field to the table
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            if filteredItems.isEmpty { return true }
            let next = min(tableView.selectedRow + 1, filteredItems.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tableView.scrollRowToVisible(next)
            return true
        case #selector(NSResponder.moveUp(_:)):
            if filteredItems.isEmpty { return true }
            let prev = max(tableView.selectedRow - 1, 0)
            tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            tableView.scrollRowToVisible(prev)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            create()
            return true
        default:
            return false
        }
    }
}
