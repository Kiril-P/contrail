import CoreGraphics
import Testing
@testable import ContrailCore

struct CursorCaptureTests {
    /// Feeds `count` events of movement `step`, 8 ms apart from `time`;
    /// `follow` says where the cursor ends up after each one.
    private func feed(_ capture: inout CursorCapture, from start: CGPoint, time: inout Double, count: Int,
                      step: CGVector, edge: Bool = false, follow: (CGPoint, CGVector) -> CGPoint) {
        var location = start
        _ = capture.moved(location: location, delta: .zero, time: time, atScreenEdge: edge)
        for _ in 0..<count {
            time += 0.008
            location = follow(location, step)
            _ = capture.moved(location: location, delta: step, time: time, atScreenEdge: edge)
        }
    }

    private let normal: (CGPoint, CGVector) -> CGPoint = { p, d in CGPoint(x: p.x + d.dx, y: p.y - d.dy) }
    private let stuck: (CGPoint, CGVector) -> CGPoint = { p, _ in p }

    @Test func normalMovementIsNeverCaptured() {
        var capture = CursorCapture(), t = 0.0
        feed(&capture, from: CGPoint(x: 500, y: 500), time: &t, count: 200, step: CGVector(dx: 3, dy: -2), follow: normal)
        #expect(!capture.isCaptured)
    }

    @Test func aDetachedCursorIsCaptured() {
        var capture = CursorCapture(), t = 0.0
        feed(&capture, from: CGPoint(x: 500, y: 500), time: &t, count: 30, step: CGVector(dx: 4, dy: 1), follow: stuck)
        #expect(capture.isCaptured)
    }

    @Test func oneBigMismatchIsNotACapture() {
        // A single event whose movement adds up past the travel threshold.
        var capture = CursorCapture(), t = 0.0
        feed(&capture, from: CGPoint(x: 500, y: 500), time: &t, count: 1, step: CGVector(dx: 120, dy: 0), follow: stuck)
        #expect(!capture.isCaptured)
    }

    @Test func positionThatDisagreesButMovesIsIgnored() {
        // Tablets, remote control, utilities: the cursor moves, just not by
        // the reported delta. Never a capture.
        var capture = CursorCapture(), t = 0.0
        feed(&capture, from: CGPoint(x: 500, y: 500), time: &t, count: 100, step: CGVector(dx: 9, dy: 0)) { p, _ in
            CGPoint(x: p.x + 2, y: p.y + 1)
        }
        #expect(!capture.isCaptured)
    }

    @Test func pushingAgainstTheScreenEdgeIsNotCapture() {
        var capture = CursorCapture(), t = 0.0
        feed(&capture, from: CGPoint(x: 0, y: 400), time: &t, count: 100, step: CGVector(dx: -5, dy: 0), edge: true, follow: stuck)
        #expect(!capture.isCaptured)
    }

    @Test func eventsAfterAGapAreNotCompared() {
        // A long pause (or movement we didn't see) between events.
        var capture = CursorCapture(), t = 0.0
        for i in 0..<20 {
            t += 0.5
            _ = capture.moved(location: CGPoint(x: 500, y: 500), delta: CGVector(dx: 10, dy: 0), time: t, atScreenEdge: false)
            _ = i
        }
        #expect(!capture.isCaptured)
    }

    @Test func forgettingThePositionBreaksTheComparison() {
        var capture = CursorCapture(), t = 0.0
        for _ in 0..<20 {
            capture.forgetPosition()
            t += 0.008
            _ = capture.moved(location: CGPoint(x: 500, y: 500), delta: CGVector(dx: 10, dy: 0), time: t, atScreenEdge: false)
        }
        #expect(!capture.isCaptured)
    }

    @Test func movingFreelyAgainReleases() {
        var capture = CursorCapture(), t = 0.0
        feed(&capture, from: CGPoint(x: 500, y: 500), time: &t, count: 30, step: CGVector(dx: 4, dy: 0), follow: stuck)
        #expect(capture.isCaptured)
        feed(&capture, from: CGPoint(x: 500, y: 500), time: &t, count: 3, step: CGVector(dx: 4, dy: 0), follow: normal)
        #expect(capture.isCaptured)          // a little real movement isn't enough
        feed(&capture, from: CGPoint(x: 512, y: 500), time: &t, count: 10, step: CGVector(dx: 4, dy: 0), follow: normal)
        #expect(!capture.isCaptured)
    }

    @Test func gamesAreRecognizedWithoutACategory() {
        #expect(FrontmostApp.looksLikeGame(info: ["LSApplicationCategoryType": "public.app-category.games"]))
        #expect(FrontmostApp.looksLikeGame(info: ["LSSupportsGameMode": true]))
        #expect(FrontmostApp.looksLikeGame(info: ["GCSupportsGameMode": true]))
        #expect(FrontmostApp.looksLikeGame(info: ["GCSupportedGameControllers": [["ProfileName": "ExtendedGamepad"]]]))
        #expect(!FrontmostApp.looksLikeGame(info: ["LSApplicationCategoryType": "public.app-category.graphics-design"]))
        #expect(!FrontmostApp.looksLikeGame(info: ["LSSupportsGameMode": false]))
    }

    @Test func anExplicitOnBeatsAutomaticOff() {
        var settings = TrailSettings.default
        let keynote = FrontmostApp(bundleID: "com.apple.iWork.Keynote", name: "Keynote", isGame: false)
        settings.appRules = [AppRule(bundleID: "com.apple.iWork.Keynote", name: "Keynote", mode: .always)]
        #expect(ActivationPolicy.decide(settings: settings, frontmost: keynote, override: nil).isForcedOn)
        let game = FrontmostApp(bundleID: "com.example.game", name: "Game", isGame: true)
        #expect(ActivationPolicy.decide(settings: settings, frontmost: game, override: true).isForcedOn)
        #expect(!ActivationPolicy.decide(settings: settings, frontmost: game, override: nil).isForcedOn)
        let editor = FrontmostApp(bundleID: "com.example.editor", name: "Editor", isGame: false)
        #expect(!ActivationPolicy.decide(settings: settings, frontmost: editor, override: nil).isForcedOn)
    }
}
