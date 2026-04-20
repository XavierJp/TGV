import AppKit

/// Train-front icon (based on Lucide). Used for the menu bar (18×18 template)
/// and the Dock / .app icon (arbitrary size, gradient background).
enum TrainIcon {
    /// Menu bar: monochrome template, auto-inverts for light/dark menu bars.
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s: CGFloat = 18.0 / 24.0
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: 0, y: 24)
            ctx.scaleBy(x: 1, y: -1)
            drawTrainPaths(in: ctx, strokeColor: NSColor.black.cgColor, lineWidth: 2)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Dock / .app icon: rounded-rect gradient background with a white train glyph.
    /// Draws inside the macOS icon grid — 824×824 rounded rect centered on a
    /// 1024×1024 canvas (100 px margin on each side), so the icon visually
    /// matches the sizing of Apple's first-party Dock icons.
    static func makeAppIcon(size: CGFloat = 1024) -> NSImage {
        let pixelSize = NSSize(width: size, height: size)
        let img = NSImage(size: pixelSize, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // macOS icon grid: 100 px margin on a 1024 canvas → ~9.77% inset.
            let inset = size * (100.0 / 1024.0)
            let rectSize = size - 2 * inset
            let rect = CGRect(x: inset, y: inset, width: rectSize, height: rectSize)
            let radius = rectSize * 0.2237
            let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.saveGState()
            ctx.addPath(bgPath)
            ctx.clip()
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    NSColor(red: 0.17, green: 0.22, blue: 0.38, alpha: 1).cgColor,
                    NSColor(red: 0.05, green: 0.08, blue: 0.16, alpha: 1).cgColor,
                ] as CFArray,
                locations: [0, 1]
            )!
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: rect.maxY),
                end: CGPoint(x: 0, y: rect.minY),
                options: []
            )
            ctx.restoreGState()

            // Train glyph centered, ~62% of the inner rounded rect.
            let glyph = rectSize * 0.62
            let scale = glyph / 24.0
            let offset = (size - glyph) / 2.0
            ctx.saveGState()
            ctx.translateBy(x: offset, y: offset + glyph)
            ctx.scaleBy(x: scale, y: -scale)
            drawTrainPaths(in: ctx, strokeColor: NSColor.white.cgColor, lineWidth: 1.8)
            ctx.restoreGState()

            return true
        }
        return img
    }

    /// Lucide "train-front" paths, drawn in a 24×24 coord system (Y already flipped).
    private static func drawTrainPaths(in ctx: CGContext, strokeColor: CGColor, lineWidth: CGFloat) {
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        // Roof: M8 3.1V7 a4 4 0 0 0 8 0 V3.1
        ctx.move(to: CGPoint(x: 8, y: 3.1))
        ctx.addLine(to: CGPoint(x: 8, y: 7))
        ctx.addArc(center: CGPoint(x: 12, y: 7), radius: 4, startAngle: .pi, endAngle: 0, clockwise: true)
        ctx.addLine(to: CGPoint(x: 16, y: 3.1))
        ctx.strokePath()

        // Headlights
        ctx.move(to: CGPoint(x: 9, y: 15))
        ctx.addLine(to: CGPoint(x: 8, y: 14))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: 15, y: 15))
        ctx.addLine(to: CGPoint(x: 16, y: 14))
        ctx.strokePath()

        // Body
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 9, y: 19))
        body.addCurve(to: CGPoint(x: 4, y: 14),
                      control1: CGPoint(x: 6.2, y: 19),
                      control2: CGPoint(x: 4, y: 16.8))
        body.addLine(to: CGPoint(x: 4, y: 10))
        body.addArc(center: CGPoint(x: 12, y: 10), radius: 8,
                    startAngle: .pi, endAngle: 0, clockwise: false)
        body.addLine(to: CGPoint(x: 20, y: 14))
        body.addCurve(to: CGPoint(x: 15, y: 19),
                      control1: CGPoint(x: 20, y: 16.8),
                      control2: CGPoint(x: 17.8, y: 19))
        body.closeSubpath()
        ctx.addPath(body)
        ctx.strokePath()

        // Legs
        ctx.move(to: CGPoint(x: 8, y: 19))
        ctx.addLine(to: CGPoint(x: 6, y: 22))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: 16, y: 19))
        ctx.addLine(to: CGPoint(x: 18, y: 22))
        ctx.strokePath()
    }
}
