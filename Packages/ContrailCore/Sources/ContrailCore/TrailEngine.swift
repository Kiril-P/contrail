import CoreGraphics
import Foundation

/// One recorded (and smoothed) cursor position.
public struct TrailSample: Equatable, Sendable {
    public var point: CGPoint
    /// Time on the engine's trail clock, which pauses while the trail lingers.
    public var time: Double
    /// True when this sample must not be connected to the previous one
    /// (first sample, or after the cursor teleported).
    public var startsStroke: Bool
    /// Distance travelled along the stroke since it started, in points. Fixed
    /// when the sample is recorded, so patterns along the path (dots, ribbon
    /// twists) stay put instead of sliding as the tail retracts.
    public var distance: Double = 0
}

/// A point on the visible part of the trail.
public struct TrailPoint: Equatable, Sendable {
    public var point: CGPoint
    /// 0 at the head (newest), 1 at the very end of the tail.
    public var age: Double
    public var startsStroke: Bool
    /// Distance along the stroke from its start, in points.
    public var distance: Double

    public init(point: CGPoint, age: Double, startsStroke: Bool, distance: Double = 0) {
        self.point = point
        self.age = age
        self.startsStroke = startsStroke
        self.distance = distance
    }
}

/// Turns a stream of cursor positions into a time-bounded trail.
///
/// The trail's length is measured in *time* (seconds of motion), so it looks the
/// same at 60 Hz and 120 Hz. When the cursor stops, the trail clock can pause for
/// `linger` seconds before the tail retracts into the head.
public struct TrailEngine: Sendable {
    /// Jumps longer than this within a single update are treated as a warp
    /// (display change, `CGWarpMouseCursorPosition`, wake from sleep) and are
    /// not connected with a giant streak.
    public static let teleportDistance: CGFloat = 1200
    public static let maxSamples = 4096
    /// Movement below this (in points) counts as standing still.
    static let stillThreshold: CGFloat = 0.01
    /// Smoothed positions closer than this to the previous sample are dropped.
    static let minSampleSpacing: CGFloat = 0.2
    /// Largest frame gap the clock will advance by; avoids jumps after a stall.
    static let maxStep: Double = 0.1
    /// How long the cursor must report no movement before it counts as
    /// stopped. Displays often refresh faster than the mouse reports, so a
    /// single unchanged frame is not a stop.
    static let stopGrace: Double = 0.08

    public private(set) var samples: [TrailSample] = []
    public private(set) var clock: Double = 0

    private var lastRealTime: Double?
    private var lastRaw: CGPoint?
    private var stillSince: Double?
    private var filter = PointFilter()
    private var pendingBreak = true
    private var lastAppended: CGPoint?

    public init() {}

    /// True when nothing is visible.
    public var isEmpty: Bool { samples.isEmpty }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        filter.reset()
        lastRealTime = nil
        lastRaw = nil
        stillSince = nil
        pendingBreak = true
        lastAppended = nil
    }

    /// Feeds the current cursor position. Call once per display frame while the
    /// trail is active. `now` is a monotonic time in seconds.
    public mutating func update(cursor raw: CGPoint, now: Double, settings: TrailSettings) {
        let dt = lastRealTime.map { min(max(now - $0, 0), Self.maxStep) } ?? 0
        lastRealTime = now

        let jump = lastRaw.map { hypot(raw.x - $0.x, raw.y - $0.y) } ?? .infinity
        if lastRaw != nil, jump > Self.teleportDistance {
            filter.reset()
            pendingBreak = true
        }
        lastRaw = raw

        if jump > Self.stillThreshold {
            stillSince = nil
        } else if stillSince == nil {
            stillSince = now
        }
        let lingering = stillSince.map {
            let stillFor = now - $0
            return stillFor >= Self.stopGrace && stillFor < Self.stopGrace + settings.linger
        } ?? false
        if !lingering {
            clock += dt
        }

        filter.configure(followSpeed: settings.followSpeed)
        let smoothed = filter.filter(raw, time: now)

        // Only record a sample when the (smoothed) position actually changed, so
        // a resting cursor lets the trail drain completely.
        let hasMoved = lastAppended.map {
            hypot(smoothed.x - $0.x, smoothed.y - $0.y) >= Self.minSampleSpacing
        } ?? true
        if hasMoved {
            let startsStroke = pendingBreak || samples.isEmpty
            let distance: Double
            if startsStroke {
                distance = 0
            } else if let last = samples.last {
                distance = last.distance + Double(hypot(smoothed.x - last.point.x, smoothed.y - last.point.y))
            } else {
                distance = 0
            }
            samples.append(TrailSample(point: smoothed, time: clock, startsStroke: startsStroke, distance: distance))
            pendingBreak = false
            lastAppended = smoothed
        }

        prune(length: settings.length)
    }

    private mutating func prune(length: Double) {
        let cutoff = clock - length
        guard let firstFresh = samples.firstIndex(where: { $0.time >= cutoff }) else {
            samples.removeAll(keepingCapacity: true)
            pendingBreak = true
            return
        }
        // Keep one stale sample so the tail end can be interpolated smoothly.
        let keepFrom = max(0, firstFresh - 1)
        if keepFrom > 0 {
            samples.removeFirst(keepFrom)
        }
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
            samples[0].startsStroke = true
        }
    }

    /// The visible trail, oldest point first, with the tail cut exactly at
    /// `length` seconds so it retracts smoothly instead of popping.
    public func visiblePoints(length: Double) -> [TrailPoint] {
        guard length > 0, !samples.isEmpty else { return [] }
        let cutoff = clock - length
        var points: [TrailPoint] = []
        points.reserveCapacity(samples.count)

        for index in samples.indices {
            let sample = samples[index]
            if sample.time < cutoff {
                let nextIndex = index + 1
                if nextIndex < samples.count {
                    let next = samples[nextIndex]
                    if next.time >= cutoff, !next.startsStroke {
                        let span = next.time - sample.time
                        let f = CGFloat(span > 0 ? (cutoff - sample.time) / span : 1)
                        let p = CGPoint(
                            x: sample.point.x + (next.point.x - sample.point.x) * f,
                            y: sample.point.y + (next.point.y - sample.point.y) * f
                        )
                        let d = sample.distance + (next.distance - sample.distance) * Double(f)
                        points.append(TrailPoint(point: p, age: 1, startsStroke: true, distance: d))
                    }
                }
                continue
            }
            let age = min(max((clock - sample.time) / length, 0), 1)
            points.append(TrailPoint(point: sample.point, age: age, startsStroke: sample.startsStroke || points.isEmpty, distance: sample.distance))
        }
        return points
    }
}
