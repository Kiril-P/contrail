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

@Suite struct RippleTests {
    let cyan = TrailColor(hex: 0x28DCFF)

    @Test func ripplesExpandFadeAndExpire() {
        var system = RippleSystem()
        system.add(at: CGPoint(x: 10, y: 20), time: 0, color: cyan)
        let early = system.instances(now: 0.05, size: 56)[0]
        let late = system.instances(now: 0.4, size: 56)[0]
        #expect(early.radius < late.radius)
        #expect(early.alpha > late.alpha)
        #expect(late.radius <= 28)
        #expect(early.fill > 0 && late.fill == 0)

        system.prune(now: RippleSystem.duration)
        #expect(system.isEmpty)
    }

    @Test func reduceMotionFadesInPlace() {
        var system = RippleSystem()
        system.add(at: .zero, time: 0, color: cyan)
        let a = system.instances(now: 0.05, size: 56, reduceMotion: true)[0]
        let b = system.instances(now: 0.4, size: 56, reduceMotion: true)[0]
        #expect(a.radius == 28 && b.radius == 28)
        #expect(a.alpha > b.alpha)
    }

    @Test func liveRipplesAreCapped() {
        var system = RippleSystem()
        for i in 0..<40 {
            system.add(at: CGPoint(x: i, y: 0), time: Double(i) * 0.001, color: cyan)
        }
        #expect(system.count == RippleSystem.maxCount)
    }

    @Test func rippleLayoutMatchesShader() {
        #expect(MemoryLayout<RippleInstance>.stride == 48)
    }

    @Test func rippleColors() {
        let s = TrailSettings(presetID: "lime", rightClickPresetID: "amber")
        #expect(s.rippleColor(primary: true) == ColorPreset.preset(id: "lime")!.stops[0])
        #expect(s.rippleColor(primary: false) == ColorPreset.preset(id: "amber")!.stops[0])
    }
}

@Suite struct StyleTests {
    /// Drags right at 600 pt/s for `frames` frames at 120 Hz.
    func drag(_ settings: TrailSettings, frames: Int = 60) -> TrailEngine {
        var engine = TrailEngine()
        for frame in 0..<frames {
            engine.update(cursor: CGPoint(x: Double(frame) * 5, y: 0), now: Double(frame) / 120, settings: settings)
        }
        return engine
    }

    @Test func distanceIsAnchoredToTheStroke() {
        let settings = TrailSettings(length: 0.2, followSpeed: 1)
        let engine = drag(settings, frames: 120)
        let points = engine.visiblePoints(length: settings.length)
        // Distances keep counting from where the stroke began, not from the
        // current tail, so they don't shift as the tail retracts.
        #expect(points.first!.distance > 400)
        for (a, b) in zip(points, points.dropFirst()) {
            #expect(b.distance >= a.distance)
            #expect(abs((b.distance - a.distance) - Double(b.point.x - a.point.x)) < 0.01)
        }
    }

    @Test func dotsSitOnFixedMultiplesOfThePeriod() {
        var settings = TrailSettings(width: 8, followSpeed: 1)
        settings.style = .dotted
        let engine = drag(settings)
        let segments = TrailGeometry.segments(for: engine.visiblePoints(length: settings.length), settings: settings)
        let period = Float(TrailGeometry.dotPeriod(settings: settings))
        #expect(segments.allSatisfy { $0.p0 == $0.p1 })
        // Every dot except the head lies on a multiple of the period
        // (the path is the x axis starting at 0).
        for dot in segments.dropLast() {
            let k = (dot.p0.x / period).rounded()
            #expect(abs(dot.p0.x - k * period) < 0.01)
        }
        #expect(segments.count > 5)
    }

    @Test func ribbonTwistsAlongTheStroke() {
        var settings = TrailSettings(width: 10, taper: 0)
        settings.style = .ribbon
        let wide = TrailGeometry.radius(age: 0, distance: 0, settings: settings)
        let pinched = TrailGeometry.radius(age: 0, distance: 60, settings: settings)
        #expect(wide == 10)
        #expect(pinched < 2)
    }

    @Test func cometHasABigHeadAndThinTail() {
        var settings = TrailSettings(width: 10, followSpeed: 1)
        settings.style = .comet
        let engine = drag(settings)
        let segments = TrailGeometry.segments(for: engine.visiblePoints(length: settings.length), settings: settings)
        #expect(segments.last!.r0 == 7)
        #expect(segments.dropLast().allSatisfy { $0.r0 <= 2.75 })
    }

    @Test func unknownStyleDecodesAsNeon() throws {
        let json = #"{"style": "holographic"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(TrailSettings.self, from: json).style == .neon)
    }
}

@Suite struct ParticleTests {
    func settings(_ style: TrailStyle, sparks: Double = 1) -> TrailSettings {
        var s = TrailSettings()
        s.style = style
        s.sparks = sparks
        return s
    }

    @Test func emitsOnlyWhileTheHeadMoves() {
        var system = ParticleSystem(seed: 1)
        let s = settings(.sparks)
        system.update(head: CGPoint(x: 0, y: 0), dt: 1 / 120, settings: s)
        system.update(head: CGPoint(x: 100, y: 0), dt: 1 / 120, settings: s)
        let afterMove = system.count
        #expect(afterMove > 0)
        system.update(head: CGPoint(x: 100, y: 0), dt: 1 / 120, settings: s)
        #expect(system.count == afterMove)
    }

    @Test func particlesDieOut() {
        var system = ParticleSystem(seed: 2)
        let s = settings(.comet)
        system.update(head: CGPoint(x: 0, y: 0), dt: 1 / 120, settings: s)
        system.update(head: CGPoint(x: 80, y: 0), dt: 1 / 120, settings: s)
        #expect(!system.isEmpty)
        for _ in 0..<200 {
            system.update(head: CGPoint(x: 80, y: 0), dt: 1 / 60, settings: s)
        }
        #expect(system.isEmpty)
    }

    @Test func noParticlesAcrossTeleportsOrForOtherStyles() {
        var system = ParticleSystem(seed: 3)
        system.update(head: .zero, dt: 1 / 120, settings: settings(.sparks))
        system.update(head: CGPoint(x: 3000, y: 0), dt: 1 / 120, settings: settings(.sparks))
        #expect(system.isEmpty)

        system.update(head: CGPoint(x: 3100, y: 0), dt: 1 / 120, settings: settings(.neon))
        #expect(system.isEmpty)

        var matte = settings(.sparks)
        matte.highContrast = true
        system.update(head: CGPoint(x: 3200, y: 0), dt: 1 / 120, settings: matte)
        #expect(system.isEmpty)
    }

    @Test func countIsCapped() {
        var system = ParticleSystem(seed: 4)
        let s = settings(.comet)
        var x = 0.0
        system.update(head: .zero, dt: 1 / 120, settings: s)
        for _ in 0..<400 {
            x += 300
            system.update(head: CGPoint(x: x, y: 0), dt: 1 / 120, settings: s)
        }
        #expect(system.count <= ParticleSystem.maxCount)
    }

    @Test func layoutMatchesShader() {
        #expect(MemoryLayout<ParticleInstance>.stride == 32)
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
        s.clickSize = 1000
        s.rightClickPresetID = "nope"
        let c = s.clamped()
        #expect(c.clickSize == TrailSettings.clickSizeRange.upperBound)
        #expect(c.rightClickPresetID == TrailSettings.default.rightClickPresetID)
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
