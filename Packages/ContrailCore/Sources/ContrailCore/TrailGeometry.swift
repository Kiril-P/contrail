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
    /// Distance between interpolated points along the curve, in points.
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

    /// Half width of the trail core at a given age.
    public static func radius(age: Double, settings: TrailSettings) -> Float {
        let taper = min(max(settings.taper, 0), 1)
        let factor = 1 - taper * pow(min(max(age, 0), 1), 0.9)
        return Float(max(settings.width * 0.5 * factor, 0.15))
    }

    private static func appendStroke(_ stroke: ArraySlice<TrailPoint>, settings: TrailSettings, into segments: inout [TrailSegment]) {
        let pts = Array(stroke)
        guard let first = pts.first else { return }

        if pts.count == 1 {
            // A single sample renders as a dot.
            let p = SIMD2<Float>(Float(first.point.x), Float(first.point.y))
            let r = radius(age: first.age, settings: settings)
            let u = Float(first.age)
            segments.append(TrailSegment(p0: p, p1: p, r0: r, r1: r, u0: u, u1: u))
            return
        }

        for i in 0..<(pts.count - 1) {
            let p1 = pts[i].point
            let p2 = pts[i + 1].point
            let p0 = i > 0 ? pts[i - 1].point : reflect(p2, about: p1)
            let p3 = i + 2 < pts.count ? pts[i + 2].point : reflect(p1, about: p2)
            let a1 = pts[i].age
            let a2 = pts[i + 1].age

            let distance = hypot(p2.x - p1.x, p2.y - p1.y)
            let steps = min(max(Int((distance / spacing).rounded(.up)), 1), maxSubdivisions)

            var previous = p1
            var previousAge = a1
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = step == steps ? p2 : catmullRom(p0, p1, p2, p3, t: t)
                let age = a1 + (a2 - a1) * Double(t)
                segments.append(TrailSegment(
                    p0: SIMD2(Float(previous.x), Float(previous.y)),
                    p1: SIMD2(Float(point.x), Float(point.y)),
                    r0: radius(age: previousAge, settings: settings),
                    r1: radius(age: age, settings: settings),
                    u0: Float(previousAge),
                    u1: Float(age)
                ))
                previous = point
                previousAge = age
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
