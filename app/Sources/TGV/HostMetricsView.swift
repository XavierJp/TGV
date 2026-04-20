import AppKit
import Core

/// CPU / GPU / RAM / Disk bars displayed in the sidebar.
final class HostMetricsView: NSView {
    private let cpuRow = MetricRow(label: "CPU")
    private let gpuRow = MetricRow(label: "GPU")
    private let ramRow = MetricRow(label: "RAM")
    private let diskRow = MetricRow(label: "DSK")

    private var rows: [MetricRow] = []
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        rows = [cpuRow, gpuRow, ramRow, diskRow]

        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            stack.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        gpuRow.isHidden = true
    }

    func update(_ m: SessionManager.HostMetrics) {
        var cpuExtra = String(format: "%.0f%%", m.cpuPercent * 100)
        if let temp = m.cpuTemp {
            cpuExtra += String(format: " • %.0f°C", temp)
        }
        cpuRow.update(fraction: m.cpuPercent, value: cpuExtra)

        if let gpuUtil = m.gpuUtil {
            gpuRow.isHidden = false
            var extra = String(format: "%.0f%%", gpuUtil * 100)
            if let temp = m.gpuTemp {
                extra += String(format: " • %.0f°C", temp)
            }
            if let watts = m.gpuWatts {
                extra += String(format: " • %.0fW", watts)
            }
            if let used = m.gpuMemUsed, let total = m.gpuMemTotal {
                let usedGB = Double(used) / 1_073_741_824.0
                let totalGB = Double(total) / 1_073_741_824.0
                extra += String(format: " • %.1f/%.1fG", usedGB, totalGB)
            }
            gpuRow.update(fraction: gpuUtil, value: extra)
        } else {
            gpuRow.isHidden = true
        }

        let memUsedGB = Double(m.memUsed) / 1_073_741_824.0
        let memTotalGB = Double(m.memTotal) / 1_073_741_824.0
        ramRow.update(
            fraction: m.memFraction,
            value: String(format: "%.1f / %.1f GB", memUsedGB, memTotalGB)
        )

        let diskUsedGB = Double(m.diskUsed) / 1_073_741_824.0
        let diskTotalGB = Double(m.diskTotal) / 1_073_741_824.0
        diskRow.update(
            fraction: m.diskFraction,
            value: String(format: "%.0f / %.0f GB", diskUsedGB, diskTotalGB)
        )
    }

    func setError() {
        for row in rows { row.update(fraction: 0, value: "—") }
    }
}

private final class MetricRow: NSView {
    private let labelView = NSTextField(labelWithString: "")
    private let valueView = NSTextField(labelWithString: "—")
    private let bar = BarView()

    init(label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        labelView.stringValue = label
        labelView.font = AppFont.medium(12)
        labelView.textColor = .secondaryLabelColor
        labelView.translatesAutoresizingMaskIntoConstraints = false

        valueView.font = AppFont.regular(11)
        valueView.textColor = .tertiaryLabelColor
        valueView.translatesAutoresizingMaskIntoConstraints = false
        valueView.alignment = .right

        bar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelView)
        addSubview(valueView)
        addSubview(bar)

        NSLayoutConstraint.activate([
            labelView.topAnchor.constraint(equalTo: topAnchor),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),

            valueView.topAnchor.constraint(equalTo: topAnchor),
            valueView.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueView.leadingAnchor.constraint(greaterThanOrEqualTo: labelView.trailingAnchor, constant: 8),

            bar.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: 2),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 4),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(fraction: Double, value: String) {
        valueView.stringValue = value
        bar.fraction = fraction
        bar.tint = colorForFraction(fraction)
        bar.needsDisplay = true
    }

    private func colorForFraction(_ f: Double) -> NSColor {
        if f >= 0.85 { return .systemRed }
        if f >= 0.65 { return .systemOrange }
        return .systemGreen
    }
}

private final class BarView: NSView {
    var fraction: Double = 0
    var tint: NSColor = .systemGreen

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius: CGFloat = bounds.height / 2

        NSColor.tertiaryLabelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let f = max(0, min(1, fraction))
        guard f > 0 else { return }
        let width = max(bounds.height, bounds.width * CGFloat(f))
        let fgRect = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        tint.setFill()
        NSBezierPath(roundedRect: fgRect, xRadius: radius, yRadius: radius).fill()
    }
}
