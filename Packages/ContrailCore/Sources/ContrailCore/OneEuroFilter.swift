import CoreGraphics
import Foundation

/// The 1€ filter (Casiez, Roussel & Vogel, CHI 2012): a low-pass filter whose
/// cutoff rises with speed, so slow movement is smoothed while fast movement
/// stays responsive.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff: Double

    private var value: Double?
    private var derivative: Double = 0
    private var time: Double?

    public init(minCutoff: Double = 1, beta: Double = 0.01, derivativeCutoff: Double = 1) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    public mutating func reset() {
        value = nil
        derivative = 0
        time = nil
    }

    public mutating func filter(_ input: Double, time now: Double) -> Double {
        guard let previous = value, let previousTime = time else {
            value = input
            time = now
            return input
        }
        let dt = now - previousTime
        guard dt > 0 else { return previous }

        let rawDerivative = (input - previous) / dt
        derivative += Self.smoothingFactor(cutoff: derivativeCutoff, dt: dt) * (rawDerivative - derivative)
        let cutoff = minCutoff + beta * abs(derivative)
        let filtered = previous + Self.smoothingFactor(cutoff: cutoff, dt: dt) * (input - previous)
        value = filtered
        time = now
        return filtered
    }

    static func smoothingFactor(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// Two independent 1€ filters, one per axis.
public struct PointFilter: Sendable {
    private var x = OneEuroFilter()
    private var y = OneEuroFilter()
    /// When true the filter passes input straight through.
    private var bypass = false

    public init() {}

    /// Maps the user-facing "follow speed" (0 = floaty, 1 = locked to the cursor)
    /// to filter parameters.
    public mutating func configure(followSpeed: Double) {
        let speed = min(max(followSpeed, 0), 1)
        bypass = speed >= 0.999
        let minCutoff = 1.5 * pow(40, speed)
        x.minCutoff = minCutoff
        y.minCutoff = minCutoff
        x.beta = 0.01
        y.beta = 0.01
    }

    public mutating func reset() {
        x.reset()
        y.reset()
    }

    public mutating func filter(_ point: CGPoint, time: Double) -> CGPoint {
        let fx = x.filter(Double(point.x), time: time)
        let fy = y.filter(Double(point.y), time: time)
        return bypass ? point : CGPoint(x: fx, y: fy)
    }
}
