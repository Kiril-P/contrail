import CoreGraphics
import Foundation

/// One capsule of the trail, laid out to match the `Segment` struct in the
/// Metal shader (32 bytes).
public struct TrailSegment: Equatable, Sendable {
    public var p0: SIMD2<Float>
    public var p1: SIMD2<Float>
    /// Half widths (core radius) at each end, in points.
    public var r0: Float
    public var r1: Float
    /// Trail age (0 head … 1 tail) at each end.
    public var u0: Float
    public var u1: Float

    public init(p0: SIMD2<Float>, p1: SIMD2<Float>, r0: Float, r1: Float, u0: Float, u1: Float) {
        self.p0 = p0
        self.p1 = p1
        self.r0 = r0
        self.r1 = r1
        self.u0 = u0
        self.u1 = u1
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
    }

    private static func appendStroke(_ stroke: ArraySlice<TrailPoint>, settings: TrailSettings, into segments: inout [TrailSegment]) {
        let pts = Array(stroke)
        guard let first = pts.first, let head = pts.last else { return }

        if settings.style == .dotted {
            // Dots go on the straight lines between recorded samples rather
            // than the spline: a spline segment changes shape when the next
            // sample arrives, which would nudge dots that are already shown.
            let polyline = pts.map { PathPoint(point: $0.point, age: $0.age, distance: $0.distance) }
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
            var path = [PathPoint(point: first.point, age: first.age, distance: first.distance)]
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
                            distance: pts[i].distance + (pts[i + 1].distance - pts[i].distance) * Double(t)
                        ))
                    }
                }
            }
            for (a, b) in zip(path, path.dropFirst()) {
                segments.append(TrailSegment(
                    p0: SIMD2(Float(a.point.x), Float(a.point.y)),
                    p1: SIMD2(Float(b.point.x), Float(b.point.y)),
                    r0: radius(age: a.age, distance: a.distance, settings: settings),
                    r1: radius(age: b.age, distance: b.distance, settings: settings),
                    u0: Float(a.age),
                    u1: Float(b.age)
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
        let r = settings.style == .comet
            ? Float(settings.width * 0.7)
            : radius(age: head.age, distance: head.distance, settings: settings)
        let u = Float(head.age)
        segments.append(TrailSegment(p0: p, p1: p, r0: r, r1: r, u0: u, u1: u))
    }

    /// Dotted style: a round dot wherever the stroke's distance crosses a
    /// multiple of the dot period. Dots are tied to stroke distance, so they
    /// stay where they were laid down while they fade.
    private static func appendDots(along path: [PathPoint], settings: TrailSettings, into segments: inout [TrailSegment]) {
        let period = dotPeriod(settings: settings)
        func dot(at point: CGPoint, age: Double, distance: Double) {
            let p = SIMD2<Float>(Float(point.x), Float(point.y))
            let r = radius(age: age, distance: distance, settings: settings) * 0.9
            segments.append(TrailSegment(p0: p, p1: p, r0: r, r1: r, u0: Float(age), u1: Float(age)))
        }
        for (a, b) in zip(path, path.dropFirst()) where b.distance > a.distance {
            var k = (a.distance / period).rounded(.up)
            while k * period < b.distance {
                let f = (k * period - a.distance) / (b.distance - a.distance)
                let point = CGPoint(
                    x: a.point.x + (b.point.x - a.point.x) * f,
                    y: a.point.y + (b.point.y - a.point.y) * f
                )
                dot(at: point, age: a.age + (b.age - a.age) * f, distance: k * period)
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
