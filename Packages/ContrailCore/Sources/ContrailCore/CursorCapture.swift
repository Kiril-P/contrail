import CoreGraphics
import Foundation

/// Notices when an app has captured the mouse, as first-person games do,
/// using only the mouse events every app can observe (no permission).
///
/// A captured mouse still reports movement (`deltaX`/`deltaY`), but the
/// cursor doesn't follow it: the game either detaches the cursor so it stays
/// put, or warps it back to the middle after every move. Either way the
/// cursor's position stops matching the movement. Normal use always matches.
///
/// The one other way to get a mismatch is pushing against the edge of the
/// screen, so events at an edge count for neither side.
public struct CursorCapture: Sendable {
    /// Mismatched movement, in points, before the mouse counts as captured.
    static let captureTravel = 40.0
    /// Matching movement, in points, before it counts as free again.
    static let releaseTravel = 24.0

    public private(set) var isCaptured = false
    private var previous: CGPoint?
    private var mismatched = 0.0
    private var matched = 0.0

    public init() {}

    /// Feeds one mouse-moved or dragged event. `location` is in AppKit
    /// screen coordinates (y up); `delta` is the event's deltaX/deltaY
    /// (y down, as AppKit reports it). Returns true if `isCaptured` changed.
    public mutating func moved(location: CGPoint, delta: CGVector, atScreenEdge: Bool) -> Bool {
        defer { previous = location }
        guard let previous, !atScreenEdge else { return false }
        let amount = hypot(delta.dx, delta.dy)
        guard amount >= 1 else { return false }
        // Where the cursor went, versus where the movement says it should
        // have gone. deltaY grows downwards and screen y upwards; accept
        // either sign anyway, so a device that reports it the other way
        // round can never look captured just by moving vertically.
        let moved = CGVector(dx: location.x - previous.x, dy: location.y - previous.y)
        let error = min(hypot(moved.dx - delta.dx, moved.dy + delta.dy),
                        hypot(moved.dx - delta.dx, moved.dy - delta.dy))
        let was = isCaptured
        if error > max(2, amount * 0.5) {
            mismatched += amount
            matched = 0
            if mismatched >= Self.captureTravel { isCaptured = true }
        } else {
            matched += amount
            if matched >= Self.releaseTravel {
                mismatched = 0
                isCaptured = false
            }
        }
        return isCaptured != was
    }

    /// Forgets everything, e.g. when another app comes to the front.
    public mutating func reset() {
        self = CursorCapture()
    }
}
