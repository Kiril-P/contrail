import CoreGraphics
import Foundation

/// Notices when an app has captured the mouse, as first-person games do,
/// using only the mouse events every app can observe (no permission).
///
/// Games capture the mouse with `CGAssociateMouseAndMouseCursorPosition(false)`:
/// mouse events keep reporting movement (`deltaX`/`deltaY`) while the cursor
/// stays exactly where it is. That one pattern is all this looks for. Any
/// other disagreement between movement and position (tablets, remote
/// control, pointer utilities, missed events) is ignored, because turning
/// the trail off by mistake is much worse than missing a game.
///
/// Pushing against a screen edge also leaves the cursor still, so events at
/// an edge count for nothing.
public struct CursorCapture: Sendable {
    /// Evidence needed before the mouse counts as captured: this many
    /// still-cursor events, adding up to at least this much movement.
    static let captureEvents = 6
    static let captureTravel = 40.0
    /// Real cursor movement, in points, before it counts as free again.
    static let releaseTravel = 24.0
    /// Events further apart than this aren't compared: something may have
    /// happened in between that we didn't see.
    static let maxGap = 0.1

    public private(set) var isCaptured = false
    private var previous: (location: CGPoint, time: Double)?
    private var stillEvents = 0
    private var stillTravel = 0.0
    private var freeTravel = 0.0

    public init() {}

    /// Feeds one global mouse-moved or dragged event. `location` is in
    /// screen coordinates, `delta` is the event's deltaX/deltaY, and `time`
    /// its timestamp. Returns true if `isCaptured` changed.
    public mutating func moved(location: CGPoint, delta: CGVector, time: Double, atScreenEdge: Bool) -> Bool {
        defer { previous = (location, time) }
        guard let previous, time - previous.time <= Self.maxGap, time >= previous.time else { return false }
        let amount = hypot(delta.dx, delta.dy)
        let moved = hypot(location.x - previous.location.x, location.y - previous.location.y)
        let was = isCaptured
        if moved >= 1 {
            // The cursor really moved: whatever this is, it isn't a capture.
            stillEvents = 0
            stillTravel = 0
            freeTravel += moved
            if freeTravel >= Self.releaseTravel { isCaptured = false }
        } else if moved < 0.5, amount >= 1, !atScreenEdge {
            // Movement reported, cursor didn't budge.
            freeTravel = 0
            stillEvents += 1
            stillTravel += amount
            if stillEvents >= Self.captureEvents && stillTravel >= Self.captureTravel { isCaptured = true }
        }
        return isCaptured != was
    }

    /// Forgets the last position, e.g. after movement this didn't see.
    public mutating func forgetPosition() {
        previous = nil
    }

    /// Forgets everything, e.g. when another app comes to the front.
    public mutating func reset() {
        self = CursorCapture()
    }
}
