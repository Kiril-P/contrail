import CoreGraphics
import Foundation

/// One ring to draw, laid out to match `Ripple` in the Metal shader (48 bytes).
public struct RippleInstance: Equatable, Sendable {
    public var center: SIMD2<Float>
    /// Ring radius, in points.
    public var radius: Float
    /// Ring line width, in points.
    public var width: Float
    /// Overall opacity, 0…1.
    public var alpha: Float
    /// Opacity of the filled "press" disc inside the ring, 0…1.
    public var fill: Float
    public var padding: SIMD2<Float> = .zero
    public var color: SIMD4<Float>

    /// Bounding box of the ring line (without glow).
    public var bounds: CGRect {
        let r = CGFloat(radius + width)
        return CGRect(x: CGFloat(center.x) - r, y: CGFloat(center.y) - r, width: 2 * r, height: 2 * r)
    }
}

/// Expanding rings shown where the user clicks. Times are monotonic seconds,
/// independent of the trail clock (which pauses while the trail lingers).
public struct RippleSystem: Sendable {
    public static let duration: Double = 0.45
    public static let maxCount = 16
    /// How far a ring's glow reaches beyond its line, in points. Must cover
    /// the shader's quad: 2.5 × kRippleWideSigma (6) × the widest line
    /// (2.5 pt) + 2, rounded up. Used to cull rings per display.
    public static let glowReach: CGFloat = 40

    private struct Ripple: Sendable {
        var center: CGPoint
        var start: Double
        var color: TrailColor
    }

    private var ripples: [Ripple] = []

    public init() {}

    public var isEmpty: Bool { ripples.isEmpty }
    public var count: Int { ripples.count }

    public mutating func add(at center: CGPoint, time: Double, color: TrailColor) {
        ripples.append(Ripple(center: center, start: time, color: color))
        if ripples.count > Self.maxCount {
            ripples.removeFirst(ripples.count - Self.maxCount)
        }
    }

    public mutating func removeAll() {
        ripples.removeAll()
    }

    /// Drops finished ripples.
    public mutating func prune(now: Double) {
        ripples.removeAll { now - $0.start >= Self.duration }
    }

    /// The rings to draw at `now`. `size` is the final diameter in points.
    /// With `reduceMotion`, rings fade in place at full size instead of growing.
    public func instances(now: Double, size: Double, reduceMotion: Bool = false) -> [RippleInstance] {
        ripples.compactMap { ripple in
            let t = (now - ripple.start) / Self.duration
            guard t >= 0, t < 1 else { return nil }
            return Self.instance(center: ripple.center, color: ripple.color, progress: t, size: size, reduceMotion: reduceMotion)
        }
    }

    /// The ring's shape at `progress` (0…1) through its life.
    static func instance(center: CGPoint, color: TrailColor, progress t: Double, size: Double, reduceMotion: Bool) -> RippleInstance {
        let eased = 1 - pow(1 - t, 3)
        let growth = reduceMotion ? 1 : 0.2 + 0.8 * eased
        let radius = size / 2 * growth
        let width = 2.5 + (1 - 2.5) * t
        let alpha = pow(1 - t, 1.5)
        // A brief filled disc gives the click a "press" feel.
        let fill = reduceMotion ? 0 : 0.2 * (1 - min(t / 0.3, 1))
        return RippleInstance(
            center: SIMD2(Float(center.x), Float(center.y)),
            radius: Float(radius),
            width: Float(width),
            alpha: Float(alpha),
            fill: Float(fill),
            color: color.simd
        )
    }
}
