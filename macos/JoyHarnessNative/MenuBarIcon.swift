import AppKit

enum MenuBarIconBadge {
    case none
    case paused
    case warning
}

@MainActor
enum MenuBarIconRenderer {
    static let displaySize = NSSize(width: 22, height: 18)
    private static let normalImage = render(badge: .none)
    private static let pausedImage = render(badge: .paused)
    private static let warningImage = render(badge: .warning)

    static func image(badge: MenuBarIconBadge) -> NSImage {
        switch badge {
        case .none: return normalImage
        case .paused: return pausedImage
        case .warning: return warningImage
        }
    }

    private static func render(badge: MenuBarIconBadge) -> NSImage {
        // Mirrors final-open-gap-menubar.svg while preserving a transparent template canvas.
        let image = NSImage(size: NSSize(width: 24, height: 20), flipped: true) { _ in
            drawJoyConPair()
            drawBadge(badge)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawJoyConPair() {
        NSColor.black.setStroke()
        NSColor.black.setFill()

        for rect in [
            NSRect(x: 3.1, y: 1.8, width: 6.3, height: 16.4),
            NSRect(x: 14.6, y: 1.8, width: 6.3, height: 16.4),
        ] {
            let outline = NSBezierPath(roundedRect: rect, xRadius: 3.15, yRadius: 3.15)
            outline.lineWidth = 1.55
            outline.lineCapStyle = .round
            outline.lineJoinStyle = .round
            outline.stroke()
        }

        fillCircle(center: NSPoint(x: 6.25, y: 6.1), radius: 1.15)
        for center in [
            NSPoint(x: 17.75, y: 5.1),
            NSPoint(x: 17.75, y: 7.1),
            NSPoint(x: 16.75, y: 6.1),
            NSPoint(x: 18.75, y: 6.1),
        ] {
            fillCircle(center: center, radius: 0.7)
        }
    }

    private static func drawBadge(_ badge: MenuBarIconBadge) {
        NSColor.black.setFill()
        switch badge {
        case .none:
            break
        case .paused:
            NSBezierPath(roundedRect: NSRect(x: 10.3, y: 13.6, width: 1.25, height: 4.6), xRadius: 0.45, yRadius: 0.45).fill()
            NSBezierPath(roundedRect: NSRect(x: 12.45, y: 13.6, width: 1.25, height: 4.6), xRadius: 0.45, yRadius: 0.45).fill()
        case .warning:
            NSBezierPath(roundedRect: NSRect(x: 11.35, y: 13.25, width: 1.3, height: 3.25), xRadius: 0.55, yRadius: 0.55).fill()
            fillCircle(center: NSPoint(x: 12, y: 17.65), radius: 0.72)
        }
    }

    private static func fillCircle(center: NSPoint, radius: CGFloat) {
        NSBezierPath(
            ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        ).fill()
    }
}
