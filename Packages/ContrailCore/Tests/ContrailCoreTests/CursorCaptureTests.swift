import CoreGraphics
import Testing
@testable import ContrailCore

struct CursorCaptureTests {
    /// Feeds moves of `step` (AppKit deltas, y down); `follow` says where the
    /// cursor actually ends up after each move.
    private func feed(_ capture: inout CursorCapture, from start: CGPoint, count: Int, step: CGVector,
                      edge: Bool = false, follow: (CGPoint, CGVector) -> CGPoint) {
        var location = start
        _ = capture.moved(location: location, delta: .zero, atScreenEdge: edge)
        for _ in 0..<count {
            location = follow(location, step)
            _ = capture.moved(location: location, delta: step, atScreenEdge: edge)
        }
    }

    private let normal: (CGPoint, CGVector) -> CGPoint = { p, d in CGPoint(x: p.x + d.dx, y: p.y - d.dy) }

    @Test func normalMovementIsNeverCaptured() {
        var capture = CursorCapture()
        feed(&capture, from: CGPoint(x: 500, y: 500), count: 200, step: CGVector(dx: 3, dy: -2), follow: normal)
        #expect(!capture.isCaptured)
    }

    @Test func aDetachedCursorIsCaptured() {
        var capture = CursorCapture()
        feed(&capture, from: CGPoint(x: 500, y: 500), count: 30, step: CGVector(dx: 4, dy: 1)) { p, _ in p }
        #expect(capture.isCaptured)
    }

    @Test func aCursorWarpedToTheMiddleIsCaptured() {
        var capture = CursorCapture()
        let middle = CGPoint(x: 800, y: 500)
        var i = 0
        // Each event lands at the middle plus that event's movement, with
        // movement varying as it does when aiming.
        var location = middle
        _ = capture.moved(location: location, delta: .zero, atScreenEdge: false)
        for _ in 0..<40 {
            i += 1
            let d = CGVector(dx: Double(3 + i % 5), dy: Double(i % 3) - 1)
            location = CGPoint(x: middle.x + d.dx, y: middle.y - d.dy)
            _ = capture.moved(location: location, delta: d, atScreenEdge: false)
        }
        #expect(capture.isCaptured)
    }

    @Test func pushingAgainstTheScreenEdgeIsNotCapture() {
        var capture = CursorCapture()
        feed(&capture, from: CGPoint(x: 0, y: 400), count: 100, step: CGVector(dx: -5, dy: 0), edge: true) { p, _ in p }
        #expect(!capture.isCaptured)
    }

    @Test func movingFreelyAgainReleases() {
        var capture = CursorCapture()
        feed(&capture, from: CGPoint(x: 500, y: 500), count: 30, step: CGVector(dx: 4, dy: 0)) { p, _ in p }
        #expect(capture.isCaptured)
        feed(&capture, from: CGPoint(x: 500, y: 500), count: 3, step: CGVector(dx: 4, dy: 0), follow: normal)
        #expect(capture.isCaptured)          // a little matching movement isn't enough
        feed(&capture, from: CGPoint(x: 500, y: 500), count: 10, step: CGVector(dx: 4, dy: 0), follow: normal)
        #expect(!capture.isCaptured)
    }

    @Test func occasionalGlitchesDontAddUp() {
        var capture = CursorCapture()
        // A dropped event now and then (a jump that doesn't match), in
        // between plenty of normal movement, never adds up to a capture.
        for round in 0..<50 {
            feed(&capture, from: CGPoint(x: 300 + Double(round), y: 300), count: 10,
                 step: CGVector(dx: 3, dy: 0), follow: normal)
            _ = capture.moved(location: CGPoint(x: 900, y: 900), delta: CGVector(dx: 30, dy: 0), atScreenEdge: false)
        }
        #expect(!capture.isCaptured)
    }

    @Test func gamesAreRecognizedWithoutACategory() {
        #expect(FrontmostApp.looksLikeGame(info: ["LSApplicationCategoryType": "public.app-category.games"], bundlePath: nil))
        #expect(FrontmostApp.looksLikeGame(info: ["GCSupportsGameMode": true], bundlePath: nil))
        #expect(FrontmostApp.looksLikeGame(info: ["GCSupportedGameControllers": [["ProfileName": "ExtendedGamepad"]]], bundlePath: nil))
        #expect(FrontmostApp.looksLikeGame(
            info: [:], bundlePath: "/Users/me/Library/Application Support/Steam/steamapps/common/Game/Game.app"))
        #expect(!FrontmostApp.looksLikeGame(info: ["LSApplicationCategoryType": "public.app-category.productivity"],
                                            bundlePath: "/Applications/Keynote.app"))
        #expect(!FrontmostApp.looksLikeGame(info: ["GCSupportsGameMode": false], bundlePath: nil))
    }
}
