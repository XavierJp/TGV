import AppKit

/// Writes the TGV app icon as a macOS `.iconset` directory ready for `iconutil -c icns`.
enum IconExport {
    /// Standard iconset sizes required by iconutil.
    /// Each entry is (displaySize, scale) → file name `icon_<display>x<display>[@2x].png`.
    private static let sizes: [(Int, Int)] = [
        (16, 1), (16, 2),
        (32, 1), (32, 2),
        (128, 1), (128, 2),
        (256, 1), (256, 2),
        (512, 1), (512, 2),
    ]

    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (display, scale) in sizes {
            let pixel = display * scale
            let suffix = scale == 1 ? "" : "@2x"
            let url = dir.appendingPathComponent("icon_\(display)x\(display)\(suffix).png")
            try writePNG(size: pixel, to: url)
        }
    }

    private static func writePNG(size: Int, to url: URL) throws {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32
        ) else {
            throw NSError(domain: "IconExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "NSBitmapImageRep init failed"])
        }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let img = TrainIcon.makeAppIcon(size: CGFloat(size))
        img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IconExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
        }
        try data.write(to: url)
    }
}
