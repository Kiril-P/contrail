import AppKit

/// The menu-bar glyph: a pointer with a separate curved contrail behind it.
/// Always a template image so macOS tints it for light and dark menu bars.
/// When the trail is off, the contrail is drawn at 30% so the item still
/// looks clickable.
enum MenuBarIcon {
    static func image(enabled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            pointer().fill()
            // The tail and its round cap are filled one by one (the cap winds the
            // other way, so one combined path would punch a hole), inside a
            // transparency layer so the dimmed state doesn't darken the overlap.
            let context = NSGraphicsContext.current?.cgContext
            context?.saveGState()
            context?.setAlpha(enabled ? 1 : 0.3)
            context?.beginTransparencyLayer(auxiliaryInfo: nil)
            contrail().forEach { $0.fill() }
            context?.endTransparencyLayer()
            context?.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = enabled ? "Contrail, trail on" : "Contrail, trail off"
        return image
    }

    /// Classic arrow pointer, about 7 pt wide and 12 pt tall (top-left origin).
    private static func pointer() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8.5, y: 1.5))
        path.line(to: NSPoint(x: 8.5, y: 12.6))
        path.line(to: NSPoint(x: 10.9, y: 10.4))
        path.line(to: NSPoint(x: 12.5, y: 14.0))
        path.line(to: NSPoint(x: 14.2, y: 13.3))
        path.line(to: NSPoint(x: 12.6, y: 9.8))
        path.line(to: NSPoint(x: 15.8, y: 9.8))
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    /// A tapered crescent from the lower left toward the pointer, bowing toward
    /// the lower right, 2.1 pt thick at the pointer end with a round cap.
    private static func contrail() -> [NSBezierPath] {
        let start = NSPoint(x: 1.4, y: 16.6)
        let control = NSPoint(x: 4.9, y: 15.0)
        let end = NSPoint(x: 6.6, y: 11.4)
        let startWidth: CGFloat = 0.6
        let endWidth: CGFloat = 2.1

        func point(_ t: CGFloat) -> NSPoint {
            let u = 1 - t
            return NSPoint(
                x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
            )
        }
        func tangent(_ t: CGFloat) -> NSPoint {
            NSPoint(
                x: 2 * (1 - t) * (control.x - start.x) + 2 * t * (end.x - control.x),
                y: 2 * (1 - t) * (control.y - start.y) + 2 * t * (end.y - control.y)
            )
        }

        let steps = 24
        var left: [NSPoint] = []
        var right: [NSPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = point(t)
            let d = tangent(t)
            let length = max(hypot(d.x, d.y), 0.0001)
            let n = NSPoint(x: -d.y / length, y: d.x / length)
            let half = (startWidth + (endWidth - startWidth) * t) / 2
            left.append(NSPoint(x: p.x + n.x * half, y: p.y + n.y * half))
            right.append(NSPoint(x: p.x - n.x * half, y: p.y - n.y * half))
        }

        let path = NSBezierPath()
        path.move(to: left[0])
        for p in left.dropFirst() { path.line(to: p) }
        for p in right.reversed() { path.line(to: p) }
        path.close()
        let cap = NSBezierPath(ovalIn: NSRect(x: end.x - endWidth / 2, y: end.y - endWidth / 2, width: endWidth, height: endWidth))
        return [path, cap]
    }
}
