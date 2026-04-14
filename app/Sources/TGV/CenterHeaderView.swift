import AppKit
import Core

/// Fixed 2-tab bar at the top of the main (center) column.
/// Tabs: Agent | Edit — always visible, centered, capsule style.
final class CenterHeaderView: NSView {
    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onShowSidePanel: (() -> Void)?

    private let segmented = NSSegmentedControl()
    private let showPanelButton = NSButton()

    private let tabIDs = ["agent", "edit"]
    private var tabLabels = ["Agent", "Edit"]

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

        segmented.segmentCount = 2
        for (i, label) in tabLabels.enumerated() {
            segmented.setLabel(label, forSegment: i)
        }
        segmented.segmentStyle = .capsule
        segmented.segmentDistribution = .fit
        segmented.trackingMode = .selectOne
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(segmentChanged)
        segmented.translatesAutoresizingMaskIntoConstraints = false
        segmented.isHidden = true

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

        addSubview(segmented)
        addSubview(showPanelButton)
        addSubview(border)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 40),

            segmented.centerXAnchor.constraint(equalTo: centerXAnchor),
            segmented.centerYAnchor.constraint(equalTo: centerYAnchor),

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

    func setSession(_ session: Session?) {
        segmented.isHidden = session == nil
        if session != nil {
            tabLabels = ["Agent", "Edit"]
            for (i, label) in tabLabels.enumerated() {
                segmented.setLabel(label, forSegment: i)
            }
            segmented.selectedSegment = 0
        }
    }

    /// Update the Edit tab label to show the current filename.
    func setEditTitle(_ filename: String) {
        tabLabels[1] = filename
        segmented.setLabel(filename, forSegment: 1)
    }

    func selectTab(id: String) {
        if let idx = tabIDs.firstIndex(of: id) {
            segmented.selectedSegment = idx
        }
    }

    func setSidePanelVisible(_ visible: Bool) {
        showPanelButton.isHidden = visible
    }

    @objc private func segmentChanged() {
        let idx = segmented.selectedSegment
        guard idx >= 0, idx < tabIDs.count else { return }
        onSelectTab?(tabIDs[idx])
    }

    @objc private func showTapped() { onShowSidePanel?() }
}
