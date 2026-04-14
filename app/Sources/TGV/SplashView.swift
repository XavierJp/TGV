import AppKit

/// Renders the TGV gradient banner — same colors and ASCII as src/banner.rs.
/// Used as a splash screen during SSH connection.
final class SplashView: NSView {
    private let bannerLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var retryAction: (() -> Void)?

    private static let gradient: [NSColor] = [
        NSColor(srgbRed: 0x83/255, green: 0x3A/255, blue: 0xB4/255, alpha: 1),
        NSColor(srgbRed: 0x9C/255, green: 0x2E/255, blue: 0x9E/255, alpha: 1),
        NSColor(srgbRed: 0xB5/255, green: 0x23/255, blue: 0x88/255, alpha: 1),
        NSColor(srgbRed: 0xD0/255, green: 0x1A/255, blue: 0x5E/255, alpha: 1),
        NSColor(srgbRed: 0xE9/255, green: 0x1D/255, blue: 0x3A/255, alpha: 1),
        NSColor(srgbRed: 0xF4/255, green: 0x6A/255, blue: 0x28/255, alpha: 1),
    ]

    private static let bannerLines: [String] = [
        "████████╗ ██████╗ ██╗   ██╗",
        "╚══██╔══╝██╔════╝ ██║   ██║",
        "   ██║   ██║  ███╗██║   ██║",
        "   ██║   ██║   ██║╚██╗ ██╔╝",
        "   ██║   ╚██████╔╝ ╚████╔╝ ",
        "   ╚═╝    ╚═════╝   ╚═══╝  ",
    ]

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

        bannerLabel.attributedStringValue = Self.makeBannerString()
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerLabel.alignment = .center
        bannerLabel.maximumNumberOfLines = 6
        addSubview(bannerLabel)

        subtitleLabel.attributedStringValue = NSAttributedString(
            string: "Terminal à Grande Vitesse",
            attributes: [
                .foregroundColor: Self.gradient[3],
                .font: NSFontManager.shared.font(
                    withFamily: NSFont.systemFont(ofSize: 14).familyName ?? "System",
                    traits: [.italicFontMask],
                    weight: 5,
                    size: 14
                ) ?? NSFont.systemFont(ofSize: 14),
            ]
        )
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.alignment = .center
        addSubview(subtitleLabel)

        statusLabel.stringValue = "Connecting…"
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        retryButton.bezelStyle = .rounded
        retryButton.font = NSFont.systemFont(ofSize: 13)
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.isHidden = true
        addSubview(retryButton)

        NSLayoutConstraint.activate([
            bannerLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            bannerLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -30),

            subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: bannerLabel.bottomAnchor, constant: 20),

            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 32),

            retryButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16),
        ])
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func setError(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.textColor = .systemRed
    }

    func showRetry(_ action: @escaping () -> Void) {
        retryAction = action
        retryButton.isHidden = false
    }

    func hideRetry() {
        retryButton.isHidden = true
        statusLabel.textColor = .secondaryLabelColor
    }

    @objc private func retryTapped() {
        retryAction?()
    }

    /// Build an attributed string of the 6-line banner with the gradient applied per line.
    private static func makeBannerString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 18, weight: .bold)

        for (i, line) in bannerLines.enumerated() {
            let color = gradient[i]
            result.append(NSAttributedString(
                string: line,
                attributes: [.foregroundColor: color, .font: font]
            ))
            if i < bannerLines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            }
        }
        return result
    }
}
