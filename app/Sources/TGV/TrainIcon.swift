import AppKit

/// Renders the Lucide train-front icon as an 18×18 template NSImage for the menu bar.
enum TrainIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s: CGFloat = 18.0 / 24.0
            ctx.scaleBy(x: s, y: s)
            // Flip Y since SVG is top-down
            ctx.translateBy(x: 0, y: 24)
            ctx.scaleBy(x: 1, y: -1)

            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(2)
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

            return true
        }
        img.isTemplate = true
        return img
    }
}
