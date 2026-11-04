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
        #expect(MemoryLayout<TrailSegment>.stride == 40)
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

    @Test func pressHoldRelease() {
        var system = RippleSystem()
        let amber = TrailColor(hex: 0xFFB52E)
        system.press(at: .zero, time: 0, color: cyan)
        #expect(system.isHolding && !system.isEmpty)
        // Held: follows the cursor and stays alive indefinitely.
        system.move(to: CGPoint(x: 50, y: 0), time: 5, dragColor: nil)
        system.prune(now: 5)
        let held = system.instances(now: 5, size: 56)
        #expect(held.count == 1 && held[0].center.x == 50)
        // Becoming a drag shifts the ring to the drag color.
        system.move(to: CGPoint(x: 60, y: 0), time: 5, dragColor: amber)
        #expect(system.instances(now: 5.5, size: 56)[0].color == amber.simd)
        // Release ripples out from the ring's size, then expires.
        system.release(at: CGPoint(x: 70, y: 0), time: 6)
        #expect(!system.isHolding)
        let out = system.instances(now: 6.01, size: 56)[0]
        #expect(out.center.x == 70 && out.color == amber.simd)
        #expect(out.radius >= held[0].radius * 0.9)
        system.prune(now: 6 + RippleSystem.duration)
        #expect(system.isEmpty)
    }

    @Test func releaseContinuesFromTheHeldRing() {
        // A long hold and a 20 ms click (ring still fading in).
        for (reduceMotion, at) in [(false, 0.3), (true, 0.3), (false, 0.02)] {
            var system = RippleSystem()
            system.press(at: .zero, time: 0, color: cyan)
            let held = system.instances(now: at, size: 56, reduceMotion: reduceMotion)[0]
            system.release(at: nil, time: at, reduceMotion: reduceMotion)
            let out = system.instances(now: at, size: 56, reduceMotion: reduceMotion)[0]
            #expect(abs(out.radius - held.radius) < 0.01, "reduceMotion \(reduceMotion) at \(at)")
            #expect(abs(out.fill - held.fill) < 0.01)
            #expect(abs(out.alpha - held.alpha) < 0.01)
        }
    }

    @Test func aStillHeldRingSettles() {
        var system = RippleSystem()
        system.press(at: .zero, time: 0, color: cyan)
        #expect(!system.isSettled(now: 0.5))
        #expect(system.isSettled(now: 1.5))
        let a = system.instances(now: 2.0, size: 56)[0].radius
        let b = system.instances(now: 2.3, size: 56)[0].radius
        #expect(a == b)                                  // no breathing once settled
        system.move(to: CGPoint(x: 10, y: 0), time: 2.5, dragColor: nil)
        #expect(!system.isSettled(now: 2.6))
    }

    @Test func aSlowDragKeepsTheRingAwake() {
        var system = RippleSystem()
        system.press(at: .zero, time: 0, color: cyan)
        // 0.3 pt per frame at 120 Hz for 2 s.
        for frame in 1...240 {
            system.move(to: CGPoint(x: Double(frame) * 0.3, y: 0), time: Double(frame) / 120, dragColor: nil)
        }
        #expect(!system.isSettled(now: 2.0))
    }

    @Test func quickClickLooksLikeARipple() {
        var system = RippleSystem()
        system.press(at: .zero, time: 0, color: cyan)
        system.release(at: nil, time: 0.08)
        let a = system.instances(now: 0.1, size: 56)[0]
        let b = system.instances(now: 0.4, size: 56)[0]
        #expect(a.radius < b.radius && a.alpha > b.alpha && b.radius <= 28)
    }

    @Test func legacyClickAndDragSettingsMigrate() throws {
        func decode(_ json: String) throws -> TrailSettings {
            try JSONDecoder().decode(TrailSettings.self, from: json.data(using: .utf8)!)
        }
        #expect(try decode(#"{"clickRipples": true, "dragHighlight": false}"#).pressEffects)
        #expect(try decode(#"{"clickRipples": false}"#).pressEffects)   // drag was on by default
        #expect(try !decode(#"{"clickRipples": false, "dragHighlight": false}"#).pressEffects)
        #expect(try !decode(#"{"pressEffects": false, "clickRipples": true}"#).pressEffects)
    }

    @Test func rippleLayoutMatchesShader() {
        #expect(MemoryLayout<RippleInstance>.stride == 48)
        #expect(MemoryLayout<RippleInstance>.offset(of: \RippleInstance.color) == 32)
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

    @Test func dotsDontMoveWhenTheTrailTurns() {
        var settings = TrailSettings(width: 8)
        settings.style = .dotted
        let straight = [
            TrailPoint(point: CGPoint(x: 0, y: 0), age: 0.5, startsStroke: true, distance: 0),
            TrailPoint(point: CGPoint(x: 100, y: 0), age: 0, startsStroke: false, distance: 100),
        ]
        let turned = [
            TrailPoint(point: CGPoint(x: 0, y: 0), age: 0.6, startsStroke: true, distance: 0),
            TrailPoint(point: CGPoint(x: 100, y: 0), age: 0.3, startsStroke: false, distance: 100),
            TrailPoint(point: CGPoint(x: 100, y: 100), age: 0, startsStroke: false, distance: 200),
        ]
        let before = TrailGeometry.segments(for: straight, settings: settings).dropLast().map(\.p0)
        let after = TrailGeometry.segments(for: turned, settings: settings).map(\.p0)
        // Every dot laid along the first leg is still exactly where it was.
        for dot in before {
            #expect(after.contains(dot))
        }
    }

    @Test func dottedHeadShowsWhenTheLastDotHasFadedAway() {
        var settings = TrailSettings(width: 8)
        settings.style = .dotted
        // Period is 20; the visible stretch 41...45 contains no multiple of it.
        let points = [
            TrailPoint(point: CGPoint(x: 41, y: 0), age: 1, startsStroke: true, distance: 41),
            TrailPoint(point: CGPoint(x: 45, y: 0), age: 0, startsStroke: false, distance: 45),
        ]
        let segments = TrailGeometry.segments(for: points, settings: settings)
        #expect(segments.count == 1)
        #expect(segments[0].p0 == SIMD2<Float>(45, 0))

        // With the dot at 40 still visible, the head 5 pt later is skipped.
        let withDot = [
            TrailPoint(point: CGPoint(x: 39, y: 0), age: 1, startsStroke: true, distance: 39),
            TrailPoint(point: CGPoint(x: 45, y: 0), age: 0, startsStroke: false, distance: 45),
        ]
        let dots = TrailGeometry.segments(for: withDot, settings: settings)
        #expect(dots.map(\.p0) == [SIMD2<Float>(40, 0)])
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

    /// The head only moves on some frames when the display outpaces the
    /// mouse; emission must still follow distance travelled.
    @Test func emissionFollowsDistanceWhenTheHeadStutters() {
        var system = ParticleSystem(seed: 5)
        let s = settings(.sparks, sparks: 0.45)
        var x = 0.0
        system.update(head: .zero, dt: 1 / 120, settings: s)
        for frame in 0..<36 {
            if frame % 2 == 0 { x += 1 }   // 1 pt every other frame: 60 pt/s
            system.update(head: CGPoint(x: x, y: 0), dt: 1 / 120, settings: s)
        }
        let expected = x * 0.45 * 1.2
        #expect(Double(system.count) >= expected.rounded(.down) - 1)
    }

    @Test func highContrastHidesParticlesAlreadyInFlight() {
        var system = ParticleSystem(seed: 6)
        var s = settings(.sparks)
        system.update(head: .zero, dt: 1 / 120, settings: s)
        system.update(head: CGPoint(x: 80, y: 0), dt: 1 / 120, settings: s)
        #expect(!system.instances(settings: s).isEmpty)
        s.highContrast = true
        #expect(system.instances(settings: s).isEmpty)
    }
}

@Suite struct ActivationTests {
    let keynote = FrontmostApp(bundleID: "com.apple.iWork.Keynote", name: "Keynote", isGame: false)
    let game = FrontmostApp(bundleID: "com.example.game", name: "Space Game", isGame: true)
    let editor = FrontmostApp(bundleID: "com.example.editor", name: "Editor", isGame: false)

    func settings(enabled: Bool, rules: [AppRule] = [], offInGames: Bool = true) -> TrailSettings {
        var s = TrailSettings(isEnabled: enabled)
        s.appRules = rules
        s.offInGames = offInGames
        return s
    }

    @Test func manualSettingAppliesWithoutRules() {
        #expect(ActivationPolicy.decide(settings: settings(enabled: true), frontmost: editor, override: nil).isOn)
        #expect(!ActivationPolicy.decide(settings: settings(enabled: false), frontmost: editor, override: nil).isOn)
        #expect(ActivationPolicy.decide(settings: settings(enabled: true), frontmost: nil, override: nil).reason == nil)
    }

    @Test func appRulesBeatTheManualSetting() {
        let rules = [AppRule(bundleID: keynote.bundleID!, name: "Keynote", mode: .always)]
        let off = ActivationPolicy.decide(settings: settings(enabled: false, rules: rules), frontmost: keynote, override: nil)
        #expect(off.isOn && off.reason == "On in Keynote")
        let never = [AppRule(bundleID: editor.bundleID!, name: "Editor", mode: .never)]
        #expect(!ActivationPolicy.decide(settings: settings(enabled: true, rules: never), frontmost: editor, override: nil).isOn)
    }

    @Test func gamesTurnOffUnlessDisabledOrRuled() {
        #expect(!ActivationPolicy.decide(settings: settings(enabled: true), frontmost: game, override: nil).isOn)
        #expect(ActivationPolicy.decide(settings: settings(enabled: true, offInGames: false), frontmost: game, override: nil).isOn)
        let always = [AppRule(bundleID: game.bundleID!, name: "Space Game", mode: .always)]
        #expect(ActivationPolicy.decide(settings: settings(enabled: true, rules: always), frontmost: game, override: nil).isOn)
    }

    @Test func overrideOnlyMattersWhileARuleApplies() {
        let rules = [AppRule(bundleID: keynote.bundleID!, name: "Keynote", mode: .always)]
        let s = settings(enabled: true, rules: rules)
        let overridden = ActivationPolicy.decide(settings: s, frontmost: keynote, override: false)
        #expect(!overridden.isOn && overridden.reason == "Overridden until you switch apps")
        // No rule for the editor, so a stale override is ignored.
        #expect(ActivationPolicy.decide(settings: s, frontmost: editor, override: false).isOn)
    }

    @Test func overrideSurvivesAVisitToContrail() {
        let rules = [AppRule(bundleID: keynote.bundleID!, name: "Keynote", mode: .always)]
        let s = settings(enabled: true, rules: rules)
        var state = ActivationState()
        state.activated(keynote)
        #expect(state.toggle(settings: s) == false)
        #expect(!state.decide(settings: s).isOn)
        // Contrail itself is never reported; coming back to Keynote keeps it.
        state.activated(keynote)
        #expect(!state.decide(settings: s).isOn)
        // A different app ends the override.
        state.activated(editor)
        state.activated(keynote)
        #expect(state.decide(settings: s).isOn)
    }

    @Test func toggleWithoutARuleFlipsTheManualSetting() {
        var state = ActivationState()
        state.activated(editor)
        #expect(state.toggle(settings: settings(enabled: true)) == true)
        #expect(state.override == nil)
    }

    @Test func unreadableRulesAreSkippedNotAllDropped() throws {
        let json = #"{"appRules": [{"bundleID": "a", "name": "A", "mode": "sometimes"}, {"bundleID": "b", "name": "B", "mode": "never"}]}"#
        let s = try JSONDecoder().decode(TrailSettings.self, from: json.data(using: .utf8)!)
        #expect(s.appRules == [AppRule(bundleID: "b", name: "B", mode: .never)])
    }

    @Test func gameCategories() {
        #expect(FrontmostApp.isGameCategory("public.app-category.games"))
        #expect(FrontmostApp.isGameCategory("public.app-category.action-games"))
        #expect(!FrontmostApp.isGameCategory("public.app-category.developer-tools"))
        #expect(!FrontmostApp.isGameCategory(nil))
    }

    @Test func drainEmptiesTheTrailAndStartsANewStroke() {
        var engine = TrailEngine()
        let s = TrailSettings(length: 0.3, followSpeed: 1)
        for i in 0..<20 {
            engine.update(cursor: CGPoint(x: Double(i) * 5, y: 0), now: Double(i) / 120, settings: s)
        }
        var now = 20.0 / 120
        for _ in 0..<60 {
            engine.drain(now: now, settings: s)
            now += 1 / 120
        }
        #expect(engine.isEmpty)
        #expect(engine.isAwaitingStroke)
        engine.update(cursor: CGPoint(x: 500, y: 0), now: now, settings: s)
        #expect(engine.samples.first?.startsStroke == true)
        #expect(!engine.isAwaitingStroke)
    }

    @Test func rulesRoundTrip() throws {
        var s = TrailSettings()
        s.holdModifier = .option
        s.appRules = [AppRule(bundleID: "com.apple.iWork.Keynote", name: "Keynote", mode: .always)]
        s.offInGames = false
        let decoded = try JSONDecoder().decode(TrailSettings.self, from: JSONEncoder().encode(s))
        #expect(decoded == s)
    }
}

@Suite struct DragTests {
    func dragged(_ settings: TrailSettings, draggingFrom start: Int) -> [TrailSegment] {
        var engine = TrailEngine()
        for frame in 0..<40 {
            engine.update(cursor: CGPoint(x: Double(frame) * 5, y: 0), now: Double(frame) / 120,
                          settings: settings, dragging: frame >= start)
        }
        return TrailGeometry.segments(for: engine.visiblePoints(length: settings.length), settings: settings)
    }

    @Test func draggedStretchIsWiderAndFlagged() {
        let s = TrailSettings(width: 8, taper: 0, followSpeed: 1)
        let segments = dragged(s, draggingFrom: 20)
        let normal = segments.filter { $0.d0 == 0 && $0.d1 == 0 }
        let drag = segments.filter { $0.d0 == 1 && $0.d1 == 1 }
        #expect(!normal.isEmpty && !drag.isEmpty)
        #expect(normal.allSatisfy { $0.r0 == 4 })
        #expect(drag.allSatisfy { abs($0.r0 - 6.4) < 0.001 })
        // The head is dragged too.
        #expect(segments.last!.d0 == 1)
    }

    @Test func turningItOffDrawsNoHighlight() {
        var s = TrailSettings(width: 8, taper: 0, followSpeed: 1)
        s.pressEffects = false
        #expect(dragged(s, draggingFrom: 0).allSatisfy { $0.d0 == 0 && $0.r0 == 4 })
    }

    @Test func dragWidthIsCapped() {
        let s = TrailSettings(width: 20, taper: 0, followSpeed: 1)
        #expect(dragged(s, draggingFrom: 0).allSatisfy { $0.r0 <= Float(TrailSettings.dragMaxWidth / 2) + 0.001 })
        // A ribbon this wide is already past the cap, so dragging doesn't
        // widen it at all (it still changes color).
        var ribbon = s
        ribbon.style = .ribbon
        let plain = dragged(ribbon, draggingFrom: 1000).map(\.r0)
        let drag = dragged(ribbon, draggingFrom: 0).map(\.r0)
        #expect(plain == drag)
    }

    @Test func cometHeadWidensWhenDragging() {
        var s = TrailSettings(width: 8, followSpeed: 1)
        s.style = .comet
        let still = dragged(s, draggingFrom: 1000).last!.r0
        let drag = dragged(s, draggingFrom: 0).last!.r0
        #expect(drag > still)
        #expect(drag <= Float(TrailSettings.dragMaxWidth / 2) + 0.001)
    }

    /// At drag start the head only has earlier points to average with, so
    /// it reaches the drag color over a few frames. Bound how long that takes.
    @Test func headTurnsToTheDragColorQuickly() {
        let s = TrailSettings(width: 8, taper: 0, followSpeed: 1)
        var engine = TrailEngine()
        var weights: [Float] = []
        for frame in 0..<30 {
            engine.update(cursor: CGPoint(x: Double(frame) * 5, y: 0), now: Double(frame) / 120,
                          settings: s, dragging: frame >= 20)
            if frame >= 20 {
                let segments = TrailGeometry.segments(for: engine.visiblePoints(length: s.length), settings: s)
                weights.append(segments.last!.d0)
            }
        }
        #expect(weights[0] > 0.2)          // visible on the first dragged frame
        #expect(weights[3] > 0.9)          // essentially full within ~20 pt
        #expect(zip(weights, weights.dropFirst()).allSatisfy { $0 <= $1 + 0.001 })
    }

    @Test func dragColorFadesInAlongTheTrail() {
        let s = TrailSettings(width: 8, taper: 0, followSpeed: 1)
        let weights = dragged(s, draggingFrom: 20).map(\.d0)
        // Somewhere between plain and dragged there are in-between weights.
        #expect(weights.contains { $0 > 0.05 && $0 < 0.95 })
        #expect(weights.first == 0 && weights.last == 1)
    }

    @Test func automaticDragColorContrastsWithTheTrail() {
        let amber = ColorPreset.preset(id: "amber")!.stops[0]
        let cyan = ColorPreset.preset(id: "cyan")!.stops[0]
        #expect(TrailSettings(presetID: "cyan").dragColor == amber)
        #expect(TrailSettings(presetID: "sunset").dragColor == cyan)
        var chosen = TrailSettings(presetID: "cyan")
        chosen.dragPresetID = "lime"
        #expect(chosen.dragColor == ColorPreset.preset(id: "lime")!.stops[0])
    }

    @Test func dragSettingsDecodeWithDefaults() throws {
        let s = try JSONDecoder().decode(TrailSettings.self, from: #"{"dragPresetID": "nope"}"#.data(using: .utf8)!)
        #expect(s.pressEffects)
        #expect(s.clamped().dragPresetID == nil)
    }
}

@Suite struct LookTests {
    @Test func defaultsAreNeonAtMedium() {
        #expect(LookSelection(.default) == .look(Look.look(id: "neon")!, .medium))
    }

    @Test func everyLookRoundTripsAtEverySize() {
        for look in Look.all {
            for size in LookSize.allCases {
                var s = TrailSettings()
                s.highContrast = true
                s.pressEffects = true
                look.apply(to: &s, size: size)
                #expect(LookSelection(s) == .look(look, size), "\(look.id) \(size)")
                // Looks leave toggles alone.
                #expect(s.highContrast && s.pressEffects)
            }
        }
    }

    @Test func lookIDsAreUniqueAndValid() {
        #expect(Set(Look.all.map(\.id)).count == Look.all.count)
        for look in Look.all {
            #expect(ColorPreset.preset(id: look.presetID) != nil)
            var s = TrailSettings()
            look.apply(to: &s, size: .large)
            #expect(s.clamped() == s, "\(look.id) stays in range")
        }
    }

    @Test func tweakingMakesItCustomBasedOnTheLook() {
        var s = TrailSettings()
        Look.look(id: "aurora")!.apply(to: &s, size: .medium)
        s.glow = 0.9
        #expect(LookSelection(s) == .custom(base: Look.look(id: "aurora")))
        // Putting the value back finds the Look again.
        s.glow = 0.6
        #expect(LookSelection(s).look?.id == "aurora")
    }

    @Test func sparksOnlyMatterForParticleStyles() {
        var s = TrailSettings()
        Look.look(id: "neon")!.apply(to: &s, size: .medium)
        s.sparks = 0.1
        #expect(LookSelection(s).look?.id == "neon")
        Look.look(id: "sparkler")!.apply(to: &s, size: .medium)
        s.sparks = 0.1
        #expect(LookSelection(s).look == nil)
    }

    @Test func baseLookFollowsWhateverLookIsMatched() {
        var s = TrailSettings()
        Look.look(id: "neon")!.apply(to: &s, size: .medium)
        // Tweak by hand until the values are exactly Whisper's.
        let whisper = Look.look(id: "whisper")!
        s.presetID = whisper.presetID; s.width = whisper.width; s.length = whisper.length
        s.glow = whisper.glow; s.taper = whisper.taper; s.followSpeed = whisper.followSpeed
        s.opacity = whisper.opacity
        s = s.reconcilingBaseLook()
        #expect(s.baseLookID == "whisper")
        s.glow = 0.9
        #expect(LookSelection(s.reconcilingBaseLook()) == .custom(base: whisper))
    }

    @Test func customKeepsItsSizeForReset() {
        var s = TrailSettings()
        let neon = Look.look(id: "neon")!
        neon.apply(to: &s, size: .large)
        s.glow = 0.2
        #expect(s.lookSize == .large)
        neon.apply(to: &s, size: s.lookSize)
        #expect(LookSelection(s) == .look(neon, .large))
    }

    @Test func migratedDefaultsGainTheirBaseLook() throws {
        let s = try JSONDecoder().decode(TrailSettings.self, from: "{}".data(using: .utf8)!)
        #expect(s.reconcilingBaseLook().baseLookID == "neon")
    }

    @Test func oldSettingsDecodeWithoutABaseLook() throws {
        let json = #"{"width": 12, "presetID": "lime"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(TrailSettings.self, from: json)
        #expect(s.baseLookID == nil)
        #expect(LookSelection(s) == .custom(base: nil))
        // Untouched 0.3 defaults still read as Neon.
        let defaults = try JSONDecoder().decode(TrailSettings.self, from: "{}".data(using: .utf8)!)
        #expect(LookSelection(defaults).look?.id == "neon")
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
