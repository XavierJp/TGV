import AppKit
import Combine
import Core

/// Native file tree view using NSOutlineView.
/// Binds to a `SessionState` and renders its cached file tree reactively.
final class FileTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// Called when the user clicks a file (not a directory). Path is relative to repo root.
    var onFileClicked: ((String) -> Void)?
    /// Latest flat list of paths — exposed for the fuzzy finder.
    private(set) var currentFilePaths: [String] = []

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private var rootNodes: [FileNode] = []

    private var cancellables = Set<AnyCancellable>()

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
        let darkBlue = NSColor(srgbRed: 0x1a/255, green: 0x1b/255, blue: 0x26/255, alpha: 1)
        layer?.backgroundColor = darkBlue.cgColor

        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 16
        outlineView.style = .plain
        outlineView.backgroundColor = darkBlue
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func bind(state: SessionState?) {
        cancellables.removeAll()
        guard let state = state else {
            currentFilePaths = []
            update([])
            return
        }

        // Immediate snapshot so view switches show cached data without flicker.
        currentFilePaths = state.filePaths
        update(state.fileTree)

        Publishers.CombineLatest(state.$fileTree, state.$filePaths)
            .receive(on: RunLoop.main)
            .sink { [weak self] tree, paths in
                self?.currentFilePaths = paths
                self?.update(tree)
            }
            .store(in: &cancellables)
    }

    /// Replace the entire tree. Preserves expansion state for matching paths.
    func update(_ nodes: [FileNode]) {
        // Remember expanded paths
        var expanded = Set<String>()
        for row in 0..<outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileNode,
               outlineView.isItemExpanded(node) {
                expanded.insert(node.path)
            }
        }

        rootNodes = nodes
        outlineView.reloadData()

        // Re-expand previously expanded paths
        restoreExpansion(nodes: nodes, expanded: expanded)
    }

    func setError(_ message: String) {
        rootNodes = []
        outlineView.reloadData()
    }

    private func restoreExpansion(nodes: [FileNode], expanded: Set<String>) {
        for node in nodes {
            if node.isDirectory {
                if expanded.contains(node.path) {
                    outlineView.expandItem(node)
                }
                restoreExpansion(nodes: node.children, expanded: expanded)
            }
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rootNodes.count }
        guard let node = item as? FileNode else { return 0 }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return rootNodes[index] }
        guard let node = item as? FileNode else { return rootNodes[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FileNode else { return false }
        return node.isDirectory
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }

        let id = NSUserInterfaceItemIdentifier("fileCell")
        let cell: NSTableCellView
        if let existing = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = id

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = AppFont.regular(12)
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.textField?.stringValue = node.name
        cell.textField?.textColor = node.isDirectory ? .labelColor : .secondaryLabelColor

        if node.isDirectory {
            cell.imageView?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "Folder")
            cell.imageView?.contentTintColor = .systemBlue
        } else {
            let icon = fileIcon(for: node.name)
            cell.imageView?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "File")
            cell.imageView?.contentTintColor = .tertiaryLabelColor
        }

        return cell
    }

    /// Prevent selection highlight — we handle clicks ourselves.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        return false
    }

    @objc private func rowClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            onFileClicked?(node.path)
        }
    }

    /// Pick an SF Symbol based on file extension.
    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "rs", "go", "py", "rb", "java", "kt", "ts", "tsx", "js", "jsx":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "doc.text"
        case "md", "txt", "rst":
            return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico":
            return "photo"
        case "css", "scss", "less":
            return "paintbrush"
        case "html", "htm":
            return "globe"
        case "sh", "bash", "zsh", "fish":
            return "terminal"
        case "lock":
            return "lock"
        case "gitignore", "dockerignore":
            return "eye.slash"
        default:
            return "doc"
        }
    }
}
