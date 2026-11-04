import CoreGraphics
import Foundation
import Testing
@testable import ContrailCore

@Suite struct TrailEngineTests {
    let settings = TrailSettings(length: 0.5, followSpeed: 1, linger: 0)

    @Test func trailRetractsAfterCursorStops() {
        var engine = TrailEngine()
        var now = 0.0
        for i in 0..<30 {
            engine.update(cursor: CGPoint(x: Double(i) * 10, y: 0), now: now, settings: settings)
            now += 1 / 60
        }
        #expect(!engine.visiblePoints(length: settings.length).isEmpty)

        // Hold still for longer than the trail length.
        for _ in 0..<60 {
            engine.update(cursor: CGPoint(x: 290, y: 0), now: now, settings: settings)
            now += 1 / 60
        }
        #expect(engine.isEmpty)
        #expect(engine.visiblePoints(length: settings.length).isEmpty)
    }

    @Test func lingerHoldsTrailWhileStill() {
        var lingering = settings
        lingering.linger = 2
        var engine = TrailEngine()
        var now = 0.0
        for i in 0..<30 {
            engine.update(cursor: CGPoint(x: Double(i) * 10, y: 0), now: now, settings: lingering)
            now += 1 / 60
        }
        // The hold starts once the cursor has been still for the grace period.
        for _ in 0..<6 {
            engine.update(cursor: CGPoint(x: 290, y: 0), now: now, settings: lingering)
            now += 1 / 60
        }
        let before = engine.visiblePoints(length: lingering.length)
        for _ in 0..<60 {
            engine.update(cursor: CGPoint(x: 290, y: 0), now: now, settings: lingering)
            now += 1 / 60
        }
        #expect(engine.visiblePoints(length: lingering.length) == before)
    }

    /// A 120 Hz display with a 60 Hz mouse sees an unchanged position every
    /// other frame. That must not count as a stop, or Hold would stretch the trail.
    @Test func holdDoesNotDependOnDisplayRate() {
        func visibleLength(linger: Double) -> CGFloat {
            var s = settings
            s.linger = linger
            var engine = TrailEngine()
            var x = 0.0
            for frame in 0..<240 {
                if frame % 2 == 0 { x += 10 }
                engine.update(cursor: CGPoint(x: x, y: 0), now: Double(frame) / 120, settings: s)
            }
            let points = engine.visiblePoints(length: s.length)
            return (points.last?.point.x ?? 0) - (points.first?.point.x ?? 0)
        }
        let withoutHold = visibleLength(linger: 0)
        let withHold = visibleLength(linger: 0.5)
        #expect(withoutHold > 200)
        #expect(abs(withHold - withoutHold) < 15)
    }

    @Test func teleportStartsNewStroke() {
        var engine = TrailEngine()
        engine.update(cursor: CGPoint(x: 0, y: 0), now: 0, settings: settings)
        engine.update(cursor: CGPoint(x: 10, y: 0), now: 0.016, settings: settings)
        engine.update(cursor: CGPoint(x: 5000, y: 0), now: 0.032, settings: settings)
        engine.update(cursor: CGPoint(x: 5010, y: 0), now: 0.048, settings: settings)

        let points = engine.visiblePoints(length: settings.length)
        #expect(points.filter(\.startsStroke).count == 2)
        let segments = TrailGeometry.segments(for: points, settings: settings)
        // No capsule may bridge the jump.
        #expect(segments.allSatisfy { abs($0.p1.x - $0.p0.x) < 100 })
    }

    @Test func tailIsInterpolatedAtCutoff() {
        var engine = TrailEngine()
        var now = 0.0
        for i in 0..<120 {
            engine.update(cursor: CGPoint(x: Double(i) * 4, y: 0), now: now, settings: settings)
            now += 1 / 60
        }
        let points = engine.visiblePoints(length: settings.length)
        #expect(points.first?.age == 1)
        #expect(points.last?.age == 0)
        // Ages run from tail (1) to head (0) without going backwards.
        for (a, b) in zip(points, points.dropFirst()) {
            #expect(a.age >= b.age)
        }
    }
}

@Suite struct GeometryTests {
    @Test func catmullRomPassesThroughControlPoints() {
        let p = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 5), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 8)]
        let start = TrailGeometry.catmullRom(p[0], p[1], p[2], p[3], t: 0)
        let end = TrailGeometry.catmullRom(p[0], p[1], p[2], p[3], t: 1)
        #expect(abs(start.x - 10) < 1e-6 && abs(start.y - 5) < 1e-6)
        #expect(abs(end.x - 20) < 1e-6 && abs(end.y) < 1e-6)
    }

    @Test func taperNarrowsTowardTail() {
        let s = TrailSettings(width: 10, taper: 1)
        #expect(TrailGeometry.radius(age: 0, settings: s) == 5)
        #expect(TrailGeometry.radius(age: 1, settings: s) <= 0.25)
        #expect(TrailGeometry.radius(age: 0.5, settings: s) > TrailGeometry.radius(age: 0.9, settings: s))
        let uniform = TrailSettings(width: 10, taper: 0)
        #expect(TrailGeometry.radius(age: 1, settings: uniform) == 5)
    }

    @Test func singlePointMakesDot() {
        let segments = TrailGeometry.segments(
            for: [TrailPoint(point: CGPoint(x: 3, y: 4), age: 0, startsStroke: true)],
            settings: .default
        )
        #expect(segments.count == 1)
        #expect(segments[0].p0 == segments[0].p1)
    }

    @Test func strokeEndsWithRoundHead() {
        let points = [
            TrailPoint(point: CGPoint(x: 0, y: 0), age: 1, startsStroke: true),
            TrailPoint(point: CGPoint(x: 0.3, y: 0), age: 0.5, startsStroke: false),
            TrailPoint(point: CGPoint(x: 0.6, y: 0), age: 0, startsStroke: false),
        ]
        let segments = TrailGeometry.segments(for: points, settings: .default)
        let head = segments.last!
        #expect(head.p0 == head.p1)
        #expect(head.p0 == SIMD2<Float>(0.6, 0))
        #expect(head.u0 == 0 && head.r0 == TrailGeometry.radius(age: 0, settings: .default))
    }

    @Test func everyStrokeGetsItsOwnHead() {
        let points = [
            TrailPoint(point: CGPoint(x: 0, y: 0), age: 1, startsStroke: true),
            TrailPoint(point: CGPoint(x: 5, y: 0), age: 0.6, startsStroke: false),
            TrailPoint(point: CGPoint(x: 900, y: 0), age: 0.4, startsStroke: true),
            TrailPoint(point: CGPoint(x: 905, y: 0), age: 0, startsStroke: false),
        ]
        let dots = TrailGeometry.segments(for: points, settings: .default).filter { $0.p0 == $0.p1 }
        #expect(dots.map(\.p0) == [SIMD2<Float>(5, 0), SIMD2<Float>(905, 0)])
    }

    @Test func segmentLayoutMatchesShader() {
        #expect(MemoryLayout<TrailSegment>.stride == 32)
    }
}

@Suite struct SettingsTests {
    @Test func decodesPartialJSONWithDefaults() throws {
        let json = #"{"width": 9, "presetID": "cyan"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(TrailSettings.self, from: json)
        #expect(s.width == 9)
        #expect(s.presetID == "cyan")
        #expect(s.length == TrailSettings.default.length)
    }

    @Test func clampsOutOfRangeValues() {
        var s = TrailSettings()
        s.width = 500
        s.opacity = -1
        s.length = .nan
        s.presetID = "does-not-exist"
        let c = s.clamped()
        #expect(c.width == TrailSettings.widthRange.upperBound)
        #expect(c.opacity == TrailSettings.opacityRange.lowerBound)
        #expect(c.length == TrailSettings.lengthRange.lowerBound)
        #expect(c.presetID == ColorPreset.defaultID)
    }

    @Test func roundTrips() throws {
        let s = TrailSettings(presetID: "sunset", width: 11, highContrast: true)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(TrailSettings.self, from: data) == s)
    }

    @Test func gradientInterpolates() {
        let preset = ColorPreset(id: "t", name: "T", stops: [TrailColor(red: 0, green: 0, blue: 0), TrailColor(red: 1, green: 1, blue: 1)])
        #expect(preset.color(at: 0.5).red == 0.5)
        #expect(preset.color(at: 2).red == 1)
    }

    @Test func presetIDsAreUnique() {
        #expect(Set(ColorPreset.all.map(\.id)).count == ColorPreset.all.count)
        #expect(ColorPreset.all.count == 9)
    }
}
