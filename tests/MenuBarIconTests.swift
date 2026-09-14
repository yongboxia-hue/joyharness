import AppKit

@main
enum MenuBarIconTests {
    @MainActor
    static func main() {
        let images = [
            MenuBarIconRenderer.image(badge: .none),
            MenuBarIconRenderer.image(badge: .paused),
            MenuBarIconRenderer.image(badge: .warning),
        ]
        let normal = alphaMetrics(for: images[0])
        let paused = alphaMetrics(for: images[1])
        let warning = alphaMetrics(for: images[2])

        precondition(normal.cornerAlpha == 0, "Menu-bar canvas must remain transparent")
        precondition(normal.visiblePixels > 0, "Menu-bar mark must contain visible pixels")
        precondition(normal.visiblePixels < normal.totalPixels / 2, "Menu-bar mark must not fill its canvas")
        precondition(paused.visiblePixels > normal.visiblePixels, "Paused badge was not rendered")
        precondition(warning.visiblePixels > normal.visiblePixels, "Warning badge was not rendered")
        if CommandLine.arguments.count > 1 {
            writePreview(images: images, to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("Menu-bar icon transparency and status badges passed.")
    }

    @MainActor
    private static func writePreview(images: [NSImage], to url: URL) {
        let scale: CGFloat = 4
        let iconSize = NSSize(width: 22 * scale, height: 18 * scale)
        let padding: CGFloat = 24
        let canvasSize = NSSize(
            width: padding * 4 + iconSize.width * CGFloat(images.count),
            height: padding * 2 + iconSize.height
        )
        let preview = NSImage(size: canvasSize, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            for (index, image) in images.enumerated() {
                image.draw(
                    in: NSRect(
                        x: padding + CGFloat(index) * (iconSize.width + padding),
                        y: padding,
                        width: iconSize.width,
                        height: iconSize.height
                    ),
                    from: NSRect(origin: .zero, size: image.size),
                    operation: .sourceOver,
                    fraction: 1
                )
            }
            return true
        }
        guard
            let tiff = preview.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            fatalError("Could not render icon preview")
        }
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            fatalError("Could not write icon preview: \(error)")
        }
    }

    @MainActor
    private static func alphaMetrics(for image: NSImage) -> (cornerAlpha: Int, visiblePixels: Int, totalPixels: Int) {
        let width = 240
        let height = 200
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            fatalError("Could not allocate icon bitmap")
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        var visiblePixels = 0
        for y in 0..<height {
            for x in 0..<width where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
                visiblePixels += 1
            }
        }
        let cornerAlpha = Int((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 0) * 255)
        return (cornerAlpha, visiblePixels, width * height)
    }
}
