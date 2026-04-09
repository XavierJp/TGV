import AppKit
import Network

// MARK: - Config

struct TGVConfig {
    let host: String
    let user: String
    let repoURL: String

    var sshTarget: String { "\(user)@\(host)" }

    static func load() -> TGVConfig? {
        let path = NSString(string: "~/.tgv/config.toml").expandingTildeInPath
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

        func parse(_ key: String) -> String? {
            let pattern = "^\(key)\\s*="
            let regex = try? NSRegularExpression(pattern: pattern)
            for line in contents.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let range = NSRange(trimmed.startIndex..., in: trimmed)
                guard regex?.firstMatch(in: trimmed, range: range) != nil else { continue }
                let parts = trimmed.components(separatedBy: "=")
                guard parts.count >= 2 else { continue }
                return parts.dropFirst().joined(separator: "=")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            return nil
        }

        guard let host = parse("host"), let user = parse("user") else { return nil }
        let repo = parse("url") ?? ""
        return TGVConfig(host: host, user: user, repoURL: repo)
    }
}

// MARK: - Session

struct Session {
    let name: String
    let branch: String
    let running: Bool
    let displayName: String?
}

// MARK: - SSH

enum SSH {
    static func run(target: String, command: String) -> (ok: Bool, stdout: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = [
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "BatchMode=yes",
            target,
            command,
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return (false, "")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (proc.terminationStatus == 0, output)
    }
}

// MARK: - Icon

/// Render the Lucide train-front icon as an NSImage for the menu bar (18x18, template)
func makeTrainIcon() -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let img = NSImage(size: size, flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let s: CGFloat = 18.0 / 24.0 // scale from 24x24 SVG to 18x18
        ctx.scaleBy(x: s, y: s)
        // Flip Y since SVG is top-down
        ctx.translateBy(x: 0, y: 24)
        ctx.scaleBy(x: 1, y: -1)

        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // path d="M8 3.1V7a4 4 0 0 0 8 0V3.1"
        ctx.move(to: CGPoint(x: 8, y: 3.1))
        ctx.addLine(to: CGPoint(x: 8, y: 7))
        ctx.addArc(center: CGPoint(x: 12, y: 7), radius: 4, startAngle: .pi, endAngle: 0, clockwise: true)
        ctx.addLine(to: CGPoint(x: 16, y: 3.1))
        ctx.strokePath()

        // path d="m9 15-1-1"
        ctx.move(to: CGPoint(x: 9, y: 15))
        ctx.addLine(to: CGPoint(x: 8, y: 14))
        ctx.strokePath()

        // path d="m15 15 1-1"
        ctx.move(to: CGPoint(x: 15, y: 15))
        ctx.addLine(to: CGPoint(x: 16, y: 14))
        ctx.strokePath()

        // path d="M9 19c-2.8 0-5-2.2-5-5v-4a8 8 0 0 1 16 0v4c0 2.8-2.2 5-5 5Z"
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 9, y: 19))
        body.addCurve(to: CGPoint(x: 4, y: 14), control1: CGPoint(x: 6.2, y: 19), control2: CGPoint(x: 4, y: 16.8))
        body.addLine(to: CGPoint(x: 4, y: 10))
        // arc: a8 8 0 0 1 16 0 → from (4,10) to (20,10) via 8-radius arc
        body.addArc(center: CGPoint(x: 12, y: 10), radius: 8, startAngle: .pi, endAngle: 0, clockwise: false)
        body.addLine(to: CGPoint(x: 20, y: 14))
        body.addCurve(to: CGPoint(x: 15, y: 19), control1: CGPoint(x: 20, y: 16.8), control2: CGPoint(x: 17.8, y: 19))
        body.closeSubpath()
        ctx.addPath(body)
        ctx.strokePath()

        // path d="m8 19-2 3"
        ctx.move(to: CGPoint(x: 8, y: 19))
        ctx.addLine(to: CGPoint(x: 6, y: 22))
        ctx.strokePath()

        // path d="m16 19 2 3"
        ctx.move(to: CGPoint(x: 16, y: 19))
        ctx.addLine(to: CGPoint(x: 18, y: 22))
        ctx.strokePath()

        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private let monitor = NWPathMonitor()
    private var config: TGVConfig?
    private var sessions: [Session] = []
    private var lastNetworkOk = true
    private let icon = makeTrainIcon()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = icon
            button.imagePosition = .imageLeading
        }

        config = TGVConfig.load()
        buildMenu(loading: false)

        // Periodic refresh
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // Network monitor — refresh when connectivity changes
        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            guard let self = self else { return }
            if ok && !self.lastNetworkOk {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.refresh()
                }
            }
            self.lastNetworkOk = ok
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))

        refresh()
    }

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let config = self.config else {
                DispatchQueue.main.async { self?.buildMenu(loading: false) }
                return
            }

            let dockerCmd = "docker ps -a --filter label=tgv.repo --format '{{.Names}}\\t{{.Label \"tgv.branch\"}}\\t{{.Status}}'"
            let result = SSH.run(target: config.sshTarget, command: dockerCmd)

            guard result.ok else {
                DispatchQueue.main.async {
                    self.sessions = []
                    self.buildMenu(loading: false, error: "Could not connect")
                }
                return
            }

            // Fetch display names in one call
            let namesResult = SSH.run(
                target: config.sshTarget,
                command: "for f in /tmp/tgv-meta/*.name; do [ -f \"$f\" ] && echo \"$(basename \"$f\" .name)=$(cat \"$f\")\"; done 2>/dev/null"
            )
            var displayNames: [String: String] = [:]
            if namesResult.ok {
                for line in namesResult.stdout.components(separatedBy: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        displayNames[String(parts[0])] = String(parts[1])
                    }
                }
            }

            var parsed: [Session] = []
            for line in result.stdout.components(separatedBy: "\n") {
                let cols = line.components(separatedBy: "\t")
                guard cols.count >= 3 else { continue }
                let name = cols[0].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                let branch = cols[1].trimmingCharacters(in: .whitespaces)
                let status = cols[2]
                parsed.append(Session(
                    name: name,
                    branch: branch,
                    running: status.contains("Up"),
                    displayName: displayNames[name]
                ))
            }

            DispatchQueue.main.async {
                self.sessions = parsed
                self.buildMenu(loading: false)
            }
        }
    }

    private func buildMenu(loading: Bool, error: String? = nil) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let running = sessions.filter(\.running).count

        // Update title
        if error != nil {
            statusItem.button?.title = ""
        } else if running > 0 {
            statusItem.button?.title = "\(running)"
        } else {
            statusItem.button?.title = ""
        }

        // Server info
        if let config = config {
            let header = NSMenuItem(title: config.sshTarget, action: nil, keyEquivalent: "")
            header.attributedTitle = NSAttributedString(
                string: config.sshTarget,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 11)]
            )
            menu.addItem(header)
            menu.addItem(.separator())
        }

        // Sessions
        if let err = error {
            let errItem = NSMenuItem(title: err, action: nil, keyEquivalent: "")
            let attributed = NSMutableAttributedString()
            attributed.append(NSAttributedString(
                string: "✕",
                attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 13)]
            ))
            attributed.append(NSAttributedString(
                string: "  \(err)",
                attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.menuFont(ofSize: 13)]
            ))
            errItem.attributedTitle = attributed
            errItem.isEnabled = false
            menu.addItem(errItem)
        } else if sessions.isEmpty {
            let empty = NSMenuItem(title: "No sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for session in sessions {
            let icon = session.running ? "●" : "○"
            let text: String
            if let dn = session.displayName {
                text = "  \(dn) (\(session.branch))"
            } else {
                text = "  \(session.branch)"
            }

            let item = NSMenuItem(title: "\(icon)\(text)", action: #selector(sessionClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.name

            let iconColor: NSColor = session.running ? .systemGreen : .tertiaryLabelColor
            let attributed = NSMutableAttributedString()
            attributed.append(NSAttributedString(
                string: icon,
                attributes: [.foregroundColor: iconColor, .font: NSFont.menuFont(ofSize: 13)]
            ))
            attributed.append(NSAttributedString(
                string: text,
                attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.menuFont(ofSize: 13)]
            ))
            item.attributedTitle = attributed

            menu.addItem(item)
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open TGV", action: #selector(openTGV), keyEquivalent: "t")
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    @objc private func sessionClicked(_ sender: NSMenuItem) {
        openTerminal(command: "tgv")
    }

    @objc private func openTGV() {
        openTerminal(command: "tgv")
    }

    @objc private func refreshClicked() {
        refresh()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func openTerminal(command: String) {
        let script = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

// MARK: - Main

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
