import AppKit
import Core

/// VS Code-style tab bar at the top of the main (center) column.
/// The "Agent" tab is always present and non-closable; file/diff tabs are
/// opened on demand and can be closed individually.
final class CenterHeaderView: NSView {
    struct TabItem: Equatable {
        let id: String
        let label: String
        let closable: Bool
    }

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onShowSidePanel: (() -> Void)?

    private let tabStrip = NSStackView()
    private let tabClip = NSView()
    private let showPanelButton = NSButton()

    private var tabs: [TabItem] = []
    private var activeID: String = "agent"
    private var tabViews: [String: TabItemView] = [:]

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

        tabStrip.orientation = .horizontal
        tabStrip.spacing = 0
        tabStrip.distribution = .fill
        tabStrip.alignment = .centerY
        tabStrip.translatesAutoresizingMaskIntoConstraints = false

        tabClip.wantsLayer = true
        tabClip.layer?.masksToBounds = true
        tabClip.translatesAutoresizingMaskIntoConstraints = false
        tabClip.isHidden = true
        tabClip.addSubview(tabStrip)

        if let img = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Show side panel") {
            showPanelButton.image = img
        } else {
            showPanelButton.title = "⇥"
        }
        showPanelButton.bezelStyle = .inline
        showPanelButton.isBordered = false
        showPanelButton.imagePosition = .imageOnly
        showPanelButton.contentTintColor = .secondaryLabelColor
        showPanelButton.target = self
        showPanelButton.action = #selector(showTapped)
        showPanelButton.translatesAutoresizingMaskIntoConstraints = false
        showPanelButton.isHidden = true

        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tabClip)
        addSubview(showPanelButton)
        addSubview(border)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),

            tabClip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            tabClip.trailingAnchor.constraint(equalTo: showPanelButton.leadingAnchor, constant: -4),
            tabClip.topAnchor.constraint(equalTo: topAnchor),
            tabClip.bottomAnchor.constraint(equalTo: bottomAnchor),

            tabStrip.leadingAnchor.constraint(equalTo: tabClip.leadingAnchor),
            tabStrip.topAnchor.constraint(equalTo: tabClip.topAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: tabClip.bottomAnchor),

            showPanelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            showPanelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            showPanelButton.widthAnchor.constraint(equalToConstant: 22),
            showPanelButton.heightAnchor.constraint(equalToConstant: 22),

            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    func bind(state: SessionState?) {
        tabClip.isHidden = state == nil
        if state == nil {
            setTabs([], activeID: "agent")
        }
    }

    /// Replace the tab set and highlight the active one. Tab views are reused
    /// across calls when their id survives so we don't thrash layer state.
    func setTabs(_ newTabs: [TabItem], activeID: String) {
        self.activeID = activeID

        if newTabs != tabs {
            tabs = newTabs
            for v in tabStrip.arrangedSubviews {
                tabStrip.removeArrangedSubview(v)
                v.removeFromSuperview()
            }
            var newViews: [String: TabItemView] = [:]
            for tab in newTabs {
                let view = tabViews[tab.id] ?? TabItemView(id: tab.id, label: tab.label, closable: tab.closable)
                view.updateLabel(tab.label)
                view.onSelect = { [weak self] in self?.onSelectTab?(tab.id) }
                view.onClose = { [weak self] in self?.onCloseTab?(tab.id) }
                newViews[tab.id] = view
                tabStrip.addArrangedSubview(view)
            }
            tabViews = newViews
        }

        for (id, view) in tabViews {
            view.isActive = (id == activeID)
        }
    }

    func setSidePanelVisible(_ visible: Bool) {
        showPanelButton.isHidden = visible
    }

    @objc private func showTapped() { onShowSidePanel?() }
}

private final class TabItemView: NSView {
    let id: String
    private let labelField = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let accentBar = NSView()
    private let closable: Bool

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    var isActive: Bool = false {
        didSet { updateAppearance() }
    }

    init(id: String, label: String, closable: Bool) {
        self.id = id
        self.closable = closable
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.stringValue = label
        labelField.font = AppFont.regular(12)
        labelField.textColor = .secondaryLabelColor
        labelField.alignment = .center
        labelField.lineBreakMode = .byTruncatingMiddle
        labelField.cell?.truncatesLastVisibleLine = true
        labelField.isBezeled = false
        labelField.drawsBackground = false
        labelField.isEditable = false
        labelField.isSelectable = false
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = NSColor(srgbRed: 0x7a/255, green: 0xa2/255, blue: 0xf7/255, alpha: 1).cgColor
        accentBar.isHidden = true

        addSubview(labelField)
        addSubview(accentBar)

        if closable {
            if let img = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab") {
                closeButton.image = img
            } else {
                closeButton.title = "×"
            }
            closeButton.bezelStyle = .inline
            closeButton.isBordered = false
            closeButton.imagePosition = .imageOnly
            closeButton.contentTintColor = .tertiaryLabelColor
            (closeButton.cell as? NSButtonCell)?.imageScaling = .scaleProportionallyDown
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.target = self
            closeButton.action = #selector(closeTapped)
            addSubview(closeButton)

            NSLayoutConstraint.activate([
                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                closeButton.widthAnchor.constraint(equalToConstant: 14),
                closeButton.heightAnchor.constraint(equalToConstant: 14),

                labelField.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            ])
        } else {
            NSLayoutConstraint.activate([
                labelField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            ])
        }

        let labelCenter = labelField.centerXAnchor.constraint(equalTo: centerXAnchor)
        labelCenter.priority = .defaultHigh

        NSLayoutConstraint.activate([
            labelField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelCenter,

            accentBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            accentBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            accentBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            accentBar.heightAnchor.constraint(equalToConstant: 2),

            heightAnchor.constraint(equalToConstant: 40),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])

        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func updateLabel(_ s: String) {
        labelField.stringValue = s
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    // Keep the NSTextField label from swallowing the click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sup = superview else { return super.hitTest(point) }
        let local = convert(point, from: sup)
        guard bounds.contains(local) else { return nil }
        if closable, closeButton.frame.contains(local) {
            return closeButton
        }
        return self
    }

    @objc private func closeTapped() {
        onClose?()
    }

    private func updateAppearance() {
        if isActive {
            layer?.backgroundColor = NSColor(srgbRed: 0x24/255, green: 0x26/255, blue: 0x35/255, alpha: 1).cgColor
            labelField.textColor = .labelColor
            accentBar.isHidden = false
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            labelField.textColor = .secondaryLabelColor
            accentBar.isHidden = true
        }
    }
}
