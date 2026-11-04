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

/// Rings shown where the user presses. One gesture, three phases:
///
/// - **Press**: a ring appears at the cursor and opens slightly.
/// - **Hold / drag**: the ring stays on the cursor and breathes; once the
///   press becomes a drag it shifts to the drag color, matching the trail.
/// - **Release**: the ring lets go and ripples out from where it is.
///
/// A quick click runs through all three in a moment and reads as a single
/// ripple. Times are monotonic seconds, independent of the trail clock.
public struct RippleSystem: Sendable {
    public static let duration: Double = 0.45
    public static let maxCount = 16
    /// How far a ring's glow reaches beyond its line, in points. Must cover
    /// the shader's quad: 2.5 × kRippleWideSigma (6) × the widest line
    /// (2.5 pt) + 2, rounded up. Used to cull rings per display.
    public static let glowReach: CGFloat = 40
    /// How far a held ring opens, as a fraction of the full ripple size.
    static let heldGrowth = 0.4
    /// Time for a held ring to open, and for its color to shift on drag.
    static let openTime = 0.18
    static let colorShiftTime = 0.15

    /// A ring rippling out after release (or an instant click).
    private struct Ripple: Sendable {
        var center: CGPoint
        var start: Double
        var color: TrailColor
        /// Growth (fraction of full size) the ripple starts from.
        var fromGrowth: Double
        /// Show the brief "press" disc (instant clicks only).
        var pressDisc: Bool
    }

    /// The ring under a held button.
    private struct Held: Sendable {
        var center: CGPoint
        var start: Double
        var color: TrailColor
        var dragColor: TrailColor?
        var dragStart: Double?
    }

    private var ripples: [Ripple] = []
    private var held: Held?

    public init() {}

    public var isEmpty: Bool { ripples.isEmpty && held == nil }
    public var isHolding: Bool { held != nil }
    public var count: Int { ripples.count + (held == nil ? 0 : 1) }

    /// An instant click: a ripple that starts small with a press disc.
    public mutating func add(at center: CGPoint, time: Double, color: TrailColor) {
        append(Ripple(center: center, start: time, color: color, fromGrowth: 0.2, pressDisc: true))
    }

    /// A button went down: start a held ring. Any ring still held (a second
    /// button) is released first.
    public mutating func press(at center: CGPoint, time: Double, color: TrailColor) {
        if held != nil { release(at: nil, time: time) }
        held = Held(center: center, start: time, color: color)
    }

    /// Keeps the held ring on the cursor. Pass `dragColor` once the press
    /// has become a drag; the ring shifts to it.
    public mutating func move(to center: CGPoint, time: Double, dragColor: TrailColor?) {
        guard var ring = held else { return }
        ring.center = center
        if let dragColor, ring.dragStart == nil {
            ring.dragColor = dragColor
            ring.dragStart = time
        }
        held = ring
    }

    /// The button came up: the held ring ripples out from its current size
    /// and color, at `center` (or where it was).
    public mutating func release(at center: CGPoint?, time: Double) {
        guard let ring = held else { return }
        held = nil
        append(Ripple(
            center: center ?? ring.center,
            start: time,
            color: Self.color(of: ring, at: time),
            fromGrowth: Self.growth(of: ring, at: time, reduceMotion: false),
            pressDisc: false
        ))
    }

    public mutating func removeAll() {
        ripples.removeAll()
        held = nil
    }

    /// Drops finished ripples.
    public mutating func prune(now: Double) {
        ripples.removeAll { now - $0.start >= Self.duration }
    }

    /// The rings to draw at `now`. `size` is the final diameter in points.
    /// With `reduceMotion`, rings fade in place at full size instead of
    /// growing, and held rings don't breathe.
    public func instances(now: Double, size: Double, reduceMotion: Bool = false) -> [RippleInstance] {
        var result: [RippleInstance] = ripples.compactMap { ripple in
            let t = (now - ripple.start) / Self.duration
            guard t >= 0, t < 1 else { return nil }
            return Self.instance(
                center: ripple.center, color: ripple.color, progress: t, size: size,
                fromGrowth: ripple.fromGrowth, pressDisc: ripple.pressDisc, reduceMotion: reduceMotion
            )
        }
        if let ring = held {
            let age = max(now - ring.start, 0)
            let breath = reduceMotion ? 1 : 1 + 0.05 * sin(age * 2 * .pi * 1.1)
            let growth = Self.growth(of: ring, at: now, reduceMotion: reduceMotion)
            result.append(RippleInstance(
                center: SIMD2(Float(ring.center.x), Float(ring.center.y)),
                radius: Float(size / 2 * growth * breath),
                width: 2.5,
                alpha: Float(min(age / 0.05, 1) * 0.95),
                fill: reduceMotion ? 0 : 0.12,
                color: Self.color(of: ring, at: now).simd
            ))
        }
        return result
    }

    private mutating func append(_ ripple: Ripple) {
        ripples.append(ripple)
        if ripples.count > Self.maxCount {
            ripples.removeFirst(ripples.count - Self.maxCount)
        }
    }

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - min(max(t, 0), 1), 3) }

    private static func growth(of ring: Held, at time: Double, reduceMotion: Bool) -> Double {
        if reduceMotion { return heldGrowth }
        return 0.2 + (heldGrowth - 0.2) * easeOut((time - ring.start) / openTime)
    }

    private static func color(of ring: Held, at time: Double) -> TrailColor {
        guard let target = ring.dragColor, let start = ring.dragStart else { return ring.color }
        return ring.color.mixed(with: target, by: Float(min(max((time - start) / colorShiftTime, 0), 1)))
    }

    /// A releasing ring's shape at `progress` (0…1) through its life.
    static func instance(
        center: CGPoint, color: TrailColor, progress t: Double, size: Double,
        fromGrowth: Double = 0.2, pressDisc: Bool = true, reduceMotion: Bool
    ) -> RippleInstance {
        let growth = reduceMotion ? 1 : fromGrowth + (1 - fromGrowth) * easeOut(t)
        let radius = size / 2 * growth
        let width = 2.5 + (1 - 2.5) * t
        let alpha = pow(1 - t, 1.5)
        // A brief filled disc gives an instant click a "press" feel.
        let fill = (reduceMotion || !pressDisc) ? 0 : 0.2 * (1 - min(t / 0.3, 1))
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

extension TrailColor {
    func mixed(with other: TrailColor, by f: Float) -> TrailColor {
        if f >= 1 { return other }
        if f <= 0 { return self }
        return TrailColor(red: red + (other.red - red) * f, green: green + (other.green - green) * f, blue: blue + (other.blue - blue) * f)
    }
}
