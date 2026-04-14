import AppKit
import SwiftTerm

/// Tokyo Night color palette for SwiftTerm.
/// Palette order is the 16 ANSI colors: black, red, green, yellow, blue, magenta, cyan, white,
/// then the 8 "bright" variants in the same order.
enum TerminalTheme {
    static let tokyoNight = Theme(
        background: rgb(0x1a, 0x1b, 0x26),
        foreground: rgb(0xc0, 0xca, 0xf5),
        cursor:     rgb(0xc0, 0xca, 0xf5),
        ansi: [
            // Normal
            color8(0x15, 0x16, 0x1e),  // 0 black
            color8(0xf7, 0x76, 0x8e),  // 1 red
            color8(0x9e, 0xce, 0x6a),  // 2 green
            color8(0xe0, 0xaf, 0x68),  // 3 yellow
            color8(0x7a, 0xa2, 0xf7),  // 4 blue
            color8(0xbb, 0x9a, 0xf7),  // 5 magenta
            color8(0x7d, 0xcf, 0xff),  // 6 cyan
            color8(0xa9, 0xb1, 0xd6),  // 7 white
            // Bright
            color8(0x41, 0x48, 0x68),  // 8 bright black
            color8(0xf7, 0x76, 0x8e),  // 9 bright red
            color8(0x9e, 0xce, 0x6a),  // 10 bright green
            color8(0xe0, 0xaf, 0x68),  // 11 bright yellow
            color8(0x7a, 0xa2, 0xf7),  // 12 bright blue
            color8(0xbb, 0x9a, 0xf7),  // 13 bright magenta
            color8(0x7d, 0xcf, 0xff),  // 14 bright cyan
            color8(0xc0, 0xca, 0xf5),  // 15 bright white
        ]
    )

    struct Theme {
        let background: NSColor
        let foreground: NSColor
        let cursor: NSColor
        let ansi: [SwiftTerm.Color]  // 16 colors
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
    }

    private static func color8(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
        // SwiftTerm.Color uses 16-bit components (0..65535)
        SwiftTerm.Color(
            red: UInt16(r) * 257,
            green: UInt16(g) * 257,
            blue: UInt16(b) * 257
        )
    }
}

extension TerminalView {
    /// Apply a TerminalTheme to this terminal view.
    func applyTheme(_ theme: TerminalTheme.Theme) {
        nativeBackgroundColor = theme.background
        nativeForegroundColor = theme.foreground
        caretColor = theme.cursor
        installColors(theme.ansi)
    }
}
