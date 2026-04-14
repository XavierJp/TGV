import AppKit

/// An NSView subclass with a flipped coordinate system (origin at top-left).
/// Used as NSScrollView.documentView so content starts at the top, not bottom.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// An NSView that highlights on hover and calls a closure on click.
final class ClickableRowView: NSView {
    private let onClick: () -> Void
    private var tracking: NSTrackingArea?
    private var hovering = false

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = nil
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = hovering ? NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor : nil
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onClick()
        }
    }
}
