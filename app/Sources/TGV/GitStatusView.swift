import AppKit
import Combine
import Core

/// Native git status view that replaces the terminal-based `watch git status`.
/// Binds to a `SessionState` and renders its cached git data reactively.
final class GitStatusView: NSView {
    /// Called when the user clicks a changed file. Path is relative to repo root.
    var onFileClicked: ((String) -> Void)?
    /// Called when the user clicks "Commit & Push". Passes the commit message.
    /// The handler should commit, push, and create a PR.
    var onCommitAndPush: ((String) -> Void)?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")

    // Branch header (fixed, above commit area)
    private let branchIcon = NSImageView()
    private let branchNameLabel = NSTextField(labelWithString: "")
    private let branchMetaLabel = NSTextField(labelWithString: "")
    private let staleLabel = NSTextField(labelWithString: "")
    private let branchContainer = NSView()

    private var cancellables = Set<AnyCancellable>()
    private weak var boundState: SessionState?
    private var staleTimer: Timer?

    // Commit area
    private let commitScroll = NSScrollView()
    private let commitTextView = NSTextView()
    private let commitButton = NSButton(title: "Commit & Push", target: nil, action: nil)
    private let commitContainer = NSView()

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
        layer?.backgroundColor = NSColor(srgbRed: 0x1a/255, green: 0x1b/255, blue: 0x26/255, alpha: 1).cgColor

        // 1. Branch header (fixed at top)
        branchContainer.translatesAutoresizingMaskIntoConstraints = false
        if let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil) {
            branchIcon.image = img
            branchIcon.contentTintColor = .systemGreen
        }
        branchIcon.translatesAutoresizingMaskIntoConstraints = false
        branchNameLabel.font = AppFont.semibold(13)
        branchNameLabel.textColor = .labelColor
        branchNameLabel.translatesAutoresizingMaskIntoConstraints = false
        branchMetaLabel.font = AppFont.regular(11)
        branchMetaLabel.textColor = .secondaryLabelColor
        branchMetaLabel.translatesAutoresizingMaskIntoConstraints = false

        staleLabel.font = AppFont.medium(10)
        staleLabel.textColor = .systemOrange
        staleLabel.translatesAutoresizingMaskIntoConstraints = false
        staleLabel.isHidden = true

        branchContainer.addSubview(branchIcon)
        branchContainer.addSubview(branchNameLabel)
        branchContainer.addSubview(branchMetaLabel)
        branchContainer.addSubview(staleLabel)

        let branchDivider = NSBox()
        branchDivider.boxType = .separator
        branchDivider.translatesAutoresizingMaskIntoConstraints = false

        // 2. Commit area — multi-line text view + buttons
        commitContainer.translatesAutoresizingMaskIntoConstraints = false

        commitTextView.font = AppFont.regular(12)
        commitTextView.isRichText = false
        commitTextView.isAutomaticQuoteSubstitutionEnabled = false
        commitTextView.isAutomaticDashSubstitutionEnabled = false
        commitTextView.textContainerInset = NSSize(width: 4, height: 4)

        commitScroll.documentView = commitTextView
        commitScroll.hasVerticalScroller = true
        commitScroll.borderType = .bezelBorder
        commitScroll.translatesAutoresizingMaskIntoConstraints = false

        commitButton.bezelStyle = .rounded
        commitButton.font = AppFont.medium(11)
        commitButton.target = self
        commitButton.action = #selector(commitTapped)
        commitButton.translatesAutoresizingMaskIntoConstraints = false
        commitButton.controlSize = .small

        commitContainer.addSubview(commitScroll)
        commitContainer.addSubview(commitButton)

        let commitDivider = NSBox()
        commitDivider.boxType = .separator
        commitDivider.translatesAutoresizingMaskIntoConstraints = false

        // 3. Scrollable file list + commits
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        scrollView.documentView = flipped

        addSubview(branchContainer)
        addSubview(branchDivider)
        addSubview(commitContainer)
        addSubview(commitDivider)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            // Branch header
            branchContainer.topAnchor.constraint(equalTo: topAnchor),
            branchContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            branchContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            branchContainer.heightAnchor.constraint(equalToConstant: 36),
            branchIcon.leadingAnchor.constraint(equalTo: branchContainer.leadingAnchor, constant: 14),
            branchIcon.centerYAnchor.constraint(equalTo: branchContainer.centerYAnchor),
            branchIcon.widthAnchor.constraint(equalToConstant: 16),
            branchIcon.heightAnchor.constraint(equalToConstant: 16),
            branchNameLabel.leadingAnchor.constraint(equalTo: branchIcon.trailingAnchor, constant: 8),
            branchNameLabel.centerYAnchor.constraint(equalTo: branchContainer.centerYAnchor),
            branchMetaLabel.leadingAnchor.constraint(equalTo: branchNameLabel.trailingAnchor, constant: 6),
            branchMetaLabel.centerYAnchor.constraint(equalTo: branchContainer.centerYAnchor),

            staleLabel.trailingAnchor.constraint(equalTo: branchContainer.trailingAnchor, constant: -14),
            staleLabel.centerYAnchor.constraint(equalTo: branchContainer.centerYAnchor),

            branchDivider.topAnchor.constraint(equalTo: branchContainer.bottomAnchor),
            branchDivider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            branchDivider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            branchDivider.heightAnchor.constraint(equalToConstant: 1),

            // Commit area
            commitContainer.topAnchor.constraint(equalTo: branchDivider.bottomAnchor),
            commitContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            commitContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            commitScroll.topAnchor.constraint(equalTo: commitContainer.topAnchor, constant: 8),
            commitScroll.leadingAnchor.constraint(equalTo: commitContainer.leadingAnchor, constant: 14),
            commitScroll.trailingAnchor.constraint(equalTo: commitContainer.trailingAnchor, constant: -14),
            commitScroll.heightAnchor.constraint(equalToConstant: 52),  // ~3 lines
            commitButton.topAnchor.constraint(equalTo: commitScroll.bottomAnchor, constant: 6),
            commitButton.leadingAnchor.constraint(equalTo: commitContainer.leadingAnchor, constant: 14),
            commitButton.bottomAnchor.constraint(equalTo: commitContainer.bottomAnchor, constant: -8),

            commitDivider.topAnchor.constraint(equalTo: commitContainer.bottomAnchor),
            commitDivider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            commitDivider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            commitDivider.heightAnchor.constraint(equalToConstant: 1),

            // Scrollable list
            scrollView.topAnchor.constraint(equalTo: commitDivider.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            flipped.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
    }

    /// Update the fixed branch header (called from update/updateAll).
    private func updateBranchHeader(_ status: GitStatus) {
        branchNameLabel.stringValue = status.branch
        var meta = ""
        if status.ahead > 0 { meta += " ↑\(status.ahead)" }
        if status.behind > 0 { meta += " ↓\(status.behind)" }
        branchMetaLabel.stringValue = meta
    }

    @objc private func commitTapped() {
        let msg = commitTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return }
        onCommitAndPush?(msg)
        commitTextView.string = ""
    }

    /// Cached commits — updated separately from status so we don't rebuild the whole view.
    private var currentCommits: [GitStatus.Commit] = []

    func bind(state: SessionState?) {
        cancellables.removeAll()
        staleTimer?.invalidate(); staleTimer = nil
        boundState = state

        guard let state = state else {
            clearAll()
            return
        }

        // Render whatever the state has already cached so view switches are instant.
        if let cached = state.gitStatus {
            updateAll(status: cached, commits: state.commits)
        } else {
            clearAll()
        }
        updateStaleIndicator()

        // Sink on status + commits: Combine emits the current values on subscribe,
        // then on every publish thereafter.
        Publishers.CombineLatest(state.$gitStatus, state.$commits)
            .receive(on: RunLoop.main)
            .sink { [weak self] status, commits in
                guard let self = self else { return }
                if let status = status {
                    self.updateAll(status: status, commits: commits)
                } else {
                    self.clearAll()
                }
            }
            .store(in: &cancellables)

        state.$gitRefreshedAt
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStaleIndicator() }
            .store(in: &cancellables)

        // Local timer recomputes the stale indicator once per second so it appears
        // even while no new data is arriving.
        staleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateStaleIndicator()
        }
    }

    private func clearAll() {
        currentCommits = []
        branchNameLabel.stringValue = ""
        branchMetaLabel.stringValue = ""
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    private func updateStaleIndicator() {
        guard let state = boundState, state.gitRefreshedAt != nil else {
            staleLabel.isHidden = true
            return
        }
        staleLabel.isHidden = !state.isGitStale
        if state.isGitStale {
            staleLabel.stringValue = "⟳ stale"
        }
    }

    func update(_ status: GitStatus) {
        rebuild(status: status, commits: currentCommits)
    }

    func updateCommits(_ commits: [GitStatus.Commit]) {
        currentCommits = commits
        // Only update if we've already rendered the view at least once
        if !stack.arrangedSubviews.isEmpty {
            // Find and remove the old COMMITS section (everything after the last divider)
            removeCommitSection()
            addCommitSection(commits)
        }
    }

    func updateAll(status: GitStatus, commits: [GitStatus.Commit]) {
        currentCommits = commits
        rebuild(status: status, commits: commits)
    }

    private func rebuild(status: GitStatus, commits: [GitStatus.Commit]) {
        // Update fixed branch header
        updateBranchHeader(status)

        // Clear scrollable list
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        // Sections
        if !status.staged.isEmpty {
            addSection(title: "Staged Changes", count: status.staged.count, entries: status.staged, color: .systemGreen)
        }
        if !status.changed.isEmpty {
            addSection(title: "Changes", count: status.changed.count, entries: status.changed, color: .systemOrange)
        }
        if !status.untracked.isEmpty {
            addSection(title: "Untracked", count: status.untracked.count, entries: status.untracked, color: .tertiaryLabelColor)
        }
        if status.isEmpty {
            let clean = makeLabel("  Nothing to commit, working tree clean", font: AppFont.regular(12), color: .secondaryLabelColor)
            clean.translatesAutoresizingMaskIntoConstraints = false
            let row = wrapRow(clean)
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        // Commit log
        addCommitSection(commits)
    }

    func setError(_ message: String) {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let label = makeLabel("  \(message)", font: AppFont.regular(12), color: .systemRed)
        label.translatesAutoresizingMaskIntoConstraints = false
        let row = wrapRow(label)
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
    }

    // MARK: - Section

    private func addSection(title: String, count: Int, entries: [GitStatus.Entry], color: NSColor) {
        // Section header
        let header = makeLabel("  \(title) (\(count))", font: AppFont.semibold(10), color: .tertiaryLabelColor)
        header.translatesAutoresizingMaskIntoConstraints = false
        let headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(header)
        NSLayoutConstraint.activate([
            headerRow.heightAnchor.constraint(equalToConstant: 28),
            header.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 14),
            header.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
        ])
        stack.addArrangedSubview(headerRow)
        headerRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        headerRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        // Entries
        for entry in entries {
            let row = makeEntryRow(entry, color: color)
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }

    private func makeEntryRow(_ entry: GitStatus.Entry, color: NSColor) -> NSView {
        let row = ClickableRowView { [weak self] in
            self?.onFileClicked?(entry.path)
        }
        row.translatesAutoresizingMaskIntoConstraints = false

        let badge = makeLabel(statusChar(entry.status), font: AppFont.bold(11), color: color)
        badge.translatesAutoresizingMaskIntoConstraints = false

        // Show just the filename (last path component) with the full path as a tooltip
        let filename = (entry.path as NSString).lastPathComponent
        let pathLabel = makeLabel(filename, font: AppFont.regular(12), color: .labelColor)
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.toolTip = entry.path
        pathLabel.lineBreakMode = .byTruncatingMiddle

        // Directory hint (dimmed prefix)
        let dir = (entry.path as NSString).deletingLastPathComponent
        let dirLabel = makeLabel(dir.isEmpty ? "" : "\(dir)/", font: AppFont.regular(10), color: .tertiaryLabelColor)
        dirLabel.translatesAutoresizingMaskIntoConstraints = false
        dirLabel.lineBreakMode = .byTruncatingHead

        row.addSubview(badge)
        row.addSubview(dirLabel)
        row.addSubview(pathLabel)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 22),
            badge.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 18),
            badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 14),
            dirLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            dirLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: dirLabel.trailingAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -12),
            pathLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        return row
    }

    // MARK: - Commit log section

    private static let commitMarkerID = "commit-section-marker"

    private func removeCommitSection() {
        var removing = false
        var toRemove: [NSView] = []
        for v in stack.arrangedSubviews {
            if v.identifier?.rawValue == Self.commitMarkerID {
                removing = true
            }
            if removing {
                toRemove.append(v)
            }
        }
        for v in toRemove {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    private func addCommitSection(_ commits: [GitStatus.Commit]) {
        guard !commits.isEmpty else { return }

        // Divider (marked so removeCommitSection can find it)
        let div = NSBox()
        div.boxType = .separator
        div.translatesAutoresizingMaskIntoConstraints = false
        div.identifier = NSUserInterfaceItemIdentifier(Self.commitMarkerID)
        stack.addArrangedSubview(div)
        div.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14).isActive = true
        div.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14).isActive = true
        div.heightAnchor.constraint(equalToConstant: 1).isActive = true

        // Header
        let header = makeLabel("  COMMITS (\(commits.count))", font: AppFont.semibold(10), color: .tertiaryLabelColor)
        header.translatesAutoresizingMaskIntoConstraints = false
        let headerRow = NSView()
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addSubview(header)
        NSLayoutConstraint.activate([
            headerRow.heightAnchor.constraint(equalToConstant: 28),
            header.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: 14),
            header.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
        ])
        stack.addArrangedSubview(headerRow)
        headerRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        headerRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true

        // Commit rows
        for commit in commits {
            let row = makeCommitRow(commit)
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }

    private func makeCommitRow(_ commit: GitStatus.Commit) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let hash = makeLabel(commit.hash, font: AppFont.regular(10), color: .systemYellow)
        hash.translatesAutoresizingMaskIntoConstraints = false

        let msg = makeLabel(commit.message, font: AppFont.regular(11), color: .labelColor)
        msg.translatesAutoresizingMaskIntoConstraints = false
        msg.lineBreakMode = .byWordWrapping
        msg.maximumNumberOfLines = 2
        msg.preferredMaxLayoutWidth = 200

        // Show date as tooltip on hover
        row.toolTip = "\(commit.author) • \(commit.relDate)"

        row.addSubview(hash)
        row.addSubview(msg)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
            hash.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 18),
            hash.topAnchor.constraint(equalTo: row.topAnchor, constant: 3),
            hash.widthAnchor.constraint(equalToConstant: 56),
            msg.leadingAnchor.constraint(equalTo: hash.trailingAnchor, constant: 6),
            msg.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            msg.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            msg.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
        ])

        return row
    }

    // MARK: - Helpers

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let tf = NSTextField(labelWithString: text)
        tf.font = font
        tf.textColor = color
        return tf
    }

    private func wrapRow(_ view: NSView) -> NSView {
        let row = NSView()
        row.addSubview(view)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 32),
            view.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            view.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func statusChar(_ s: GitStatus.Entry.Status) -> String {
        switch s {
        case .modified:  return "M"
        case .added:     return "A"
        case .deleted:   return "D"
        case .renamed:   return "R"
        case .copied:    return "C"
        case .untracked: return "?"
        }
    }
}
