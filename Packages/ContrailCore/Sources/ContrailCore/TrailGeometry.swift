import CoreGraphics
import Foundation

/// One capsule of the trail, laid out to match the `Segment` struct in the
/// Metal shader (40 bytes).
public struct TrailSegment: Equatable, Sendable {
    public var p0: SIMD2<Float>
    public var p1: SIMD2<Float>
    /// Half widths (core radius) at each end, in points.
    public var r0: Float
    public var r1: Float
    /// Trail age (0 head … 1 tail) at each end.
    public var u0: Float
    public var u1: Float
    /// Drag weight (0 normal … 1 dragged) at each end.
    public var d0: Float
    public var d1: Float

    public init(p0: SIMD2<Float>, p1: SIMD2<Float>, r0: Float, r1: Float, u0: Float, u1: Float, d0: Float = 0, d1: Float = 0) {
        self.p0 = p0
        self.p1 = p1
        self.r0 = r0
        self.r1 = r1
        self.u0 = u0
        self.u1 = u1
        self.d0 = d0
        self.d1 = d1
    }

    /// Bounding box of the core (without glow).
    public var bounds: CGRect {
        let r = CGFloat(max(r0, r1))
        let minX = CGFloat(min(p0.x, p1.x)) - r
        let minY = CGFloat(min(p0.y, p1.y)) - r
        let maxX = CGFloat(max(p0.x, p1.x)) + r
        let maxY = CGFloat(max(p0.y, p1.y)) + r
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

public enum TrailGeometry {
    /// Distance between interpolated points along the curve, in points. Keep
    /// it small: each capsule's round caps hold their endpoint's age, and
    /// wider spacing makes the steps visible as beads in the glow.
    public static let spacing: CGFloat = 2.5
    /// Upper bound on subdivisions between two samples.
    public static let maxSubdivisions = 24

    /// Converts visible trail points into tapered capsules, smoothing the path
    /// with a centripetal Catmull–Rom spline.
    public static func segments(for points: [TrailPoint], settings: TrailSettings) -> [TrailSegment] {
        var segments: [TrailSegment] = []
        guard !points.isEmpty else { return segments }
        segments.reserveCapacity(points.count * 2)

        var strokeStart = 0
        for index in 1...points.count {
            if index == points.count || points[index].startsStroke {
                appendStroke(points[strokeStart..<index], settings: settings, into: &segments)
                strokeStart = index
            }
        }
        return segments
    }

    /// Half width of the trail at a given age (and, for Ribbon, position
    /// along the stroke). The body stays full for most of its length and
    /// narrows to a hairline at the very end.
    public static func radius(age: Double, distance: Double = 0, settings: TrailSettings) -> Float {
        let taper = min(max(settings.taper, 0), 1)
        let exponent = 1.3 * taper
        let remaining = 1 - min(max(age, 0), 1)
        let factor = exponent > 0 ? max(0.05, pow(remaining, exponent)) : 1
        let width = settings.width
        switch settings.style {
        case .neon, .sparks, .dotted:
            return Float(max(width * 0.5 * factor, 0.1))
        case .ribbon:
            // Twice as wide as the tube, pinched where the band "turns".
            let twist = max(0.12, abs(cos(Double.pi * distance / (12 * width))))
            return Float(max(width * factor * twist, 0.1))
        case .comet:
            // A thin tail that thins out fast behind a big head.
            return Float(max(width * 0.275 * pow(remaining, 1.5), 0.1))
        }
    }

    /// Spacing between dots in the Dotted style, in points.
    public static func dotPeriod(settings: TrailSettings) -> Double {
        max(2.5 * settings.width, 8)
    }

    private struct PathPoint {
        var point: CGPoint
        var age: Double
        var distance: Double
        var drag: Double = 0
    }

    /// How much a dragged stretch widens: 1.6×, reduced so the style's
    /// widest point stays within the drag width cap. One factor for the
    /// whole trail, so tapers and ribbon twists keep their shape.
    static func dragScale(fullRadius: Double) -> Double {
        let cap = TrailSettings.dragMaxWidth / 2
        return min(max(cap / max(fullRadius, 0.001), 1), TrailSettings.dragWidthScale)
    }

    /// The widest radius a style reaches (before taper), for `dragScale`.
    static func fullRadius(settings: TrailSettings) -> Double {
        switch settings.style {
        case .neon, .sparks, .dotted: settings.width * 0.5
        case .ribbon: settings.width
        case .comet: settings.width * 0.275
        }
    }

    /// Radius at a path point, widened where the trail was dragged.
    private static func radius(at p: PathPoint, settings: TrailSettings) -> Float {
        let base = radius(age: p.age, distance: p.distance, settings: settings)
        guard p.drag > 0, settings.pressEffects else { return base }
        let scale = dragScale(fullRadius: fullRadius(settings: settings))
        return base * Float(1 + (scale - 1) * p.drag)
    }

    /// Softens the switch to and from the drag color over about four trail
    /// widths, so the two colors' halos don't meet head-on (with MAX
    /// blending that would flash a pale blob at each end of a drag).
    private static func smoothDrag(_ path: [PathPoint], settings: TrailSettings) -> [PathPoint] {
        guard settings.pressEffects, path.contains(where: { $0.drag > 0 }) else { return path }
        let half = max(settings.width * 2, 8)
        var result = path
        var lo = 0
        var hi = 0
        for i in path.indices {
            let d = path[i].distance
            while lo < path.count, path[lo].distance < d - half { lo += 1 }
            while hi < path.count, path[hi].distance <= d + half { hi += 1 }
            var sum = 0.0
            var weights = 0.0
            for j in lo..<hi {
                let w = 1 - abs(path[j].distance - d) / half
                sum += path[j].drag * w
                weights += w
            }
            result[i].drag = weights > 0 ? sum / weights : path[i].drag
        }
        return result
    }

    private static func dragWeight(_ p: PathPoint, settings: TrailSettings) -> Float {
        settings.pressEffects ? Float(p.drag) : 0
    }

    private static func appendStroke(_ stroke: ArraySlice<TrailPoint>, settings: TrailSettings, into segments: inout [TrailSegment]) {
        let pts = Array(stroke)
        guard let first = pts.first, let head = pts.last else { return }
        // The head's drag weight after smoothing.
        var headDrag = head.drag

        if settings.style == .dotted {
            // Dots go on the straight lines between recorded samples rather
            // than the spline: a spline segment changes shape when the next
            // sample arrives, which would nudge dots that are already shown.
            let polyline = smoothDrag(pts.map { PathPoint(point: $0.point, age: $0.age, distance: $0.distance, drag: $0.drag) }, settings: settings)
            headDrag = polyline.last?.drag ?? headDrag
            appendDots(along: polyline, settings: settings, into: &segments)
            // The head dot marks the cursor, unless it would sit on top of
            // the last dot laid in the visible part of this stroke.
            let period = dotPeriod(settings: settings)
            let lastDot = (head.distance / period).rounded(.down) * period
            let sinceLastDot = head.distance - lastDot
            if lastDot >= first.distance, sinceLastDot > 0, sinceLastDot < period * 0.5 {
                return
            }
        } else {
            // Smooth the stroke into closely spaced points.
            var path = [PathPoint(point: first.point, age: first.age, distance: first.distance, drag: first.drag)]
            if pts.count > 1 {
                for i in 0..<(pts.count - 1) {
                    let p1 = pts[i].point
                    let p2 = pts[i + 1].point
                    let p0 = i > 0 ? pts[i - 1].point : reflect(p2, about: p1)
                    let p3 = i + 2 < pts.count ? pts[i + 2].point : reflect(p1, about: p2)
                    let length = hypot(p2.x - p1.x, p2.y - p1.y)
                    let steps = min(max(Int((length / spacing).rounded(.up)), 1), maxSubdivisions)
                    for step in 1...steps {
                        let t = CGFloat(step) / CGFloat(steps)
                        path.append(PathPoint(
                            point: step == steps ? p2 : catmullRom(p0, p1, p2, p3, t: t),
                            age: pts[i].age + (pts[i + 1].age - pts[i].age) * Double(t),
                            distance: pts[i].distance + (pts[i + 1].distance - pts[i].distance) * Double(t),
                            drag: pts[i].drag + (pts[i + 1].drag - pts[i].drag) * Double(t)
                        ))
                    }
                }
            }
            path = smoothDrag(path, settings: settings)
            headDrag = path.last?.drag ?? headDrag
            for (a, b) in zip(path, path.dropFirst()) {
                segments.append(TrailSegment(
                    p0: SIMD2(Float(a.point.x), Float(a.point.y)),
                    p1: SIMD2(Float(b.point.x), Float(b.point.y)),
                    r0: radius(at: a, settings: settings),
                    r1: radius(at: b, settings: settings),
                    u0: Float(a.age),
                    u1: Float(b.age),
                    d0: dragWeight(a, settings: settings),
                    d1: dragWeight(b, settings: settings)
                ))
            }
        }

        // A zero-length capsule at the head. Each capsule blends from its older
        // to its newer end across its own length, and on slow movement that is
        // a fraction of a point, a sharp step across the whole halo. Every
        // other capsule's step is covered by the round cap of the capsule ahead
        // of it; this gives the newest one the same cover. Comet makes it the
        // comet's bright head.
        let p = SIMD2<Float>(Float(head.point.x), Float(head.point.y))
        let headPoint = PathPoint(point: head.point, age: head.age, distance: head.distance, drag: headDrag)
        var r = radius(at: headPoint, settings: settings)
        if settings.style == .comet {
            let headRadius = settings.width * 0.7
            let scale = settings.pressEffects ? dragScale(fullRadius: headRadius) : 1
            r = Float(headRadius * (1 + (scale - 1) * headDrag))
        }
        let u = Float(head.age)
        let d = dragWeight(headPoint, settings: settings)
        segments.append(TrailSegment(p0: p, p1: p, r0: r, r1: r, u0: u, u1: u, d0: d, d1: d))
    }

    /// Dotted style: a round dot wherever the stroke's distance crosses a
    /// multiple of the dot period. Dots are tied to stroke distance, so they
    /// stay where they were laid down while they fade.
    private static func appendDots(along path: [PathPoint], settings: TrailSettings, into segments: inout [TrailSegment]) {
        let period = dotPeriod(settings: settings)
        func dot(at point: CGPoint, age: Double, distance: Double, drag: Double) {
            let p = SIMD2<Float>(Float(point.x), Float(point.y))
            let at = PathPoint(point: point, age: age, distance: distance, drag: drag)
            let r = radius(at: at, settings: settings) * 0.9
            let d = dragWeight(at, settings: settings)
            segments.append(TrailSegment(p0: p, p1: p, r0: r, r1: r, u0: Float(age), u1: Float(age), d0: d, d1: d))
        }
        for (a, b) in zip(path, path.dropFirst()) where b.distance > a.distance {
            var k = (a.distance / period).rounded(.up)
            while k * period < b.distance {
                let f = (k * period - a.distance) / (b.distance - a.distance)
                let point = CGPoint(
                    x: a.point.x + (b.point.x - a.point.x) * f,
                    y: a.point.y + (b.point.y - a.point.y) * f
                )
                dot(at: point, age: a.age + (b.age - a.age) * f, distance: k * period, drag: a.drag + (b.drag - a.drag) * f)
                k += 1
            }
        }
    }

    static func reflect(_ point: CGPoint, about pivot: CGPoint) -> CGPoint {
        CGPoint(x: 2 * pivot.x - point.x, y: 2 * pivot.y - point.y)
    }

    /// Centripetal Catmull–Rom (alpha = 0.5) between p1 and p2, Barry–Goldman form.
    static func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, t: CGFloat) -> CGPoint {
        func knot(_ previous: CGFloat, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            previous + max(sqrt(hypot(b.x - a.x, b.y - a.y)), 1e-4)
        }
        func lerp(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat, _ t: CGFloat) -> CGPoint {
            let span = tb - ta
            let wa = (tb - t) / span
            let wb = (t - ta) / span
            return CGPoint(x: a.x * wa + b.x * wb, y: a.y * wa + b.y * wb)
        }
        let t0: CGFloat = 0
        let t1 = knot(t0, p0, p1)
        let t2 = knot(t1, p1, p2)
        let t3 = knot(t2, p2, p3)
        let tt = t1 + (t2 - t1) * t

        let a1 = lerp(p0, p1, t0, t1, tt)
        let a2 = lerp(p1, p2, t1, t2, tt)
        let a3 = lerp(p2, p3, t2, t3, tt)
        let b1 = lerp(a1, a2, t0, t2, tt)
        let b2 = lerp(a2, a3, t1, t3, tt)
        return lerp(b1, b2, t1, t2, tt)
    }
}
