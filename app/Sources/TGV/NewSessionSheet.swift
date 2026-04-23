import AppKit
import Core

/// New-session sheet: a short title and a prompt for codex.
/// Title is required; prompt is optional. The branch is derived from the title.
/// Enter in the title field focuses the prompt; Shift+Enter submits.
final class NewSessionSheet: NSWindowController, NSTextFieldDelegate, NSTextViewDelegate {
    private let onSubmit: (_ title: String, _ prompt: String) -> Void

    private let titleField = NSTextField()
    private let promptTextView = NSTextView()
    private let promptScroll = NSScrollView()
    private let createButton = NSButton(title: "Create session", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init(onSubmit: @escaping (_ title: String, _ prompt: String) -> Void) {
        self.onSubmit = onSubmit

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "New Session"
        super.init(window: window)

        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let heading = NSTextField(labelWithString: "New Session")
        heading.font = AppFont.semibold(16)
        heading.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Title")
        titleLabel.font = AppFont.medium(11)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        titleField.placeholderString = "e.g. Add dark mode"
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.delegate = self
        titleField.font = AppFont.regular(13)

        let promptLabel = NSTextField(labelWithString: "Prompt")
        promptLabel.font = AppFont.medium(11)
        promptLabel.textColor = .secondaryLabelColor
        promptLabel.translatesAutoresizingMaskIntoConstraints = false

        promptTextView.isRichText = false
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false
        promptTextView.isAutomaticDashSubstitutionEnabled = false
        promptTextView.isAutomaticTextReplacementEnabled = false
        promptTextView.font = AppFont.regular(13)
        promptTextView.textContainerInset = NSSize(width: 6, height: 6)
        promptTextView.delegate = self
        promptTextView.allowsUndo = true

        promptScroll.documentView = promptTextView
        promptScroll.hasVerticalScroller = true
        promptScroll.borderType = .bezelBorder
        promptScroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "⇧↩ to create  ·  esc to cancel")
        hint.font = AppFont.regular(10)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        createButton.target = self
        createButton.action = #selector(create)
        createButton.bezelStyle = .rounded
        createButton.keyEquivalent = "\r"
        createButton.keyEquivalentModifierMask = [.shift]
        createButton.isEnabled = false
        createButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1B}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(heading)
        contentView.addSubview(titleLabel)
        contentView.addSubview(titleField)
        contentView.addSubview(promptLabel)
        contentView.addSubview(promptScroll)
        contentView.addSubview(hint)
        contentView.addSubview(cancelButton)
        contentView.addSubview(createButton)

        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            titleLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            titleField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            titleField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            promptLabel.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 14),
            promptLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            promptScroll.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 4),
            promptScroll.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            promptScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            promptScroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -12),

            hint.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            hint.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -14),

            createButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            createButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            cancelButton.trailingAnchor.constraint(equalTo: createButton.leadingAnchor, constant: -8),
        ])

        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self?.titleField)
        }
    }

    private func updateCreateEnabled() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        createButton.isEnabled = !title.isEmpty
    }

    @objc private func create() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let prompt = promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmit(title, prompt)
        window?.sheetParent?.endSheet(window!, returnCode: .OK)
    }

    @objc private func cancel() {
        window?.sheetParent?.endSheet(window!, returnCode: .cancel)
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        updateCreateEnabled()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Return in title jumps to the prompt field.
            window?.makeFirstResponder(promptTextView)
            return true
        }
        return false
    }

    // MARK: - NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Shift+Enter submits from the prompt field. Depending on macOS version
        // and keyboard layout, Shift+Return can be routed as insertLineBreak:,
        // insertNewlineIgnoringFieldEditor:, or insertNewline: with the shift
        // modifier — catch all three. Plain Enter (no shift) still falls through
        // to the default, which inserts a newline.
        let isNewlineish = commandSelector == #selector(NSResponder.insertLineBreak(_:))
            || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            || commandSelector == #selector(NSResponder.insertNewline(_:))
        guard isNewlineish else { return false }
        guard let event = NSApp.currentEvent, event.modifierFlags.contains(.shift) else {
            return false
        }
        create()
        return true
    }
}
