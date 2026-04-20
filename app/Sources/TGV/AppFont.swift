import AppKit

/// Centralized font for the TGV UI — FiraCode Nerd Font Mono, with graceful
/// fallback to stock Fira Code and finally the system monospaced face.
enum AppFont {
    /// The resolved FiraCode family name (picked lazily at first use).
    private static let family: String = {
        for candidate in ["FiraCode Nerd Font Mono", "FiraCodeNerdFontMono", "Fira Code", "FiraCode"] {
            if NSFont(name: candidate, size: 10) != nil {
                return candidate
            }
        }
        return NSFont.monospacedSystemFont(ofSize: 10, weight: .regular).familyName ?? "Menlo"
    }()

    static func regular(_ size: CGFloat)  -> NSFont { font(size, weight: .regular) }
    static func medium(_ size: CGFloat)   -> NSFont { font(size, weight: .medium) }
    static func semibold(_ size: CGFloat) -> NSFont { font(size, weight: .semibold) }
    static func bold(_ size: CGFloat)     -> NSFont { font(size, weight: .bold) }

    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let f = NSFontManager.shared.font(
            withFamily: family,
            traits: [],
            weight: fontManagerWeight(weight),
            size: size
        ) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// NSFontManager uses a 0..15 weight scale where 5 is regular.
    private static func fontManagerWeight(_ w: NSFont.Weight) -> Int {
        switch w {
        case .ultraLight: return 2
        case .thin:       return 3
        case .light:      return 4
        case .medium:     return 6
        case .semibold:   return 8
        case .bold:       return 9
        case .heavy:      return 10
        case .black:      return 12
        default:          return 5
        }
    }
}
