import CoreGraphics
import Foundation

/// One particle to draw, laid out to match `Particle` in the Metal shader
/// (32 bytes).
public struct ParticleInstance: Equatable, Sendable {
    public var center: SIMD2<Float>
    /// Gaussian radius (sigma), in points.
    public var sigma: Float
    public var alpha: Float
    public var color: SIMD4<Float>

    public var bounds: CGRect {
        let r = CGFloat(sigma * 7.5)
        return CGRect(x: CGFloat(center.x) - r, y: CGFloat(center.y) - r, width: 2 * r, height: 2 * r)
    }
}

/// A small, fast, seedable random number generator (SplitMix64), so particle
/// behavior is reproducible in tests.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Sparks and comet dust shed by the trail head.
///
/// Particles are emitted in proportion to the distance the head travels, so a
/// still cursor emits nothing, and never across a teleport. They drift with
/// drag and fade out; the system is empty again within a second of the cursor
/// stopping, which lets the display links pause.
public struct ParticleSystem: Sendable {
    public static let maxCount = 300
    /// Most particles born in one update, so a fast flick can't burst.
    public static let maxBirthsPerUpdate = 48
    /// Head movements longer than this in one update are treated as teleports.
    static let teleportDistance: Double = 400

    private struct Particle: Sendable {
        var position: SIMD2<Double>
        var velocity: SIMD2<Double>
        var age: Double
        var life: Double
        var sigma: Double
        var seed: Double
        var colorPosition: Double
    }

    private var particles: [Particle] = []
    private var rng: SplitMix64
    private var lastHead: CGPoint?
    private var debt: Double = 0

    public init(seed: UInt64 = 0xC0_7124_11) {
        rng = SplitMix64(seed: seed)
    }

    public var isEmpty: Bool { particles.isEmpty }
    public var count: Int { particles.count }

    public mutating func removeAll() {
        particles.removeAll()
        lastHead = nil
        debt = 0
    }

    /// Advances the simulation by `dt` seconds and emits particles along the
    /// head's movement since the previous update. Pass `head: nil` when there
    /// is no trail (existing particles still drift and fade).
    public mutating func update(head: CGPoint?, dt rawDT: Double, settings: TrailSettings) {
        let dt = min(max(rawDT, 0), 0.05)
        let drag = exp(-5 * dt)
        for index in particles.indices {
            particles[index].age += dt
            particles[index].velocity *= drag
            particles[index].position += particles[index].velocity * dt
        }
        particles.removeAll { $0.age >= $0.life }

        guard let head else {
            lastHead = nil
            debt = 0
            return
        }
        defer { lastHead = head }
        guard settings.style.hasParticles, !settings.highContrast, settings.sparks > 0,
              let previous = lastHead else { return }

        let move = SIMD2(Double(head.x - previous.x), Double(head.y - previous.y))
        let distance = (move * move).sum().squareRoot()
        guard distance > 0.01, distance < Self.teleportDistance else {
            debt = 0
            return
        }

        let comet = settings.style == .comet
        debt += distance * settings.sparks * (comet ? 1.0 : 1.2)
        let births = min(Int(debt), Self.maxBirthsPerUpdate)
        debt -= Double(births)
        if births == Self.maxBirthsPerUpdate { debt = 0 }

        let direction = move / distance
        let normal = SIMD2(-direction.y, direction.x)
        let headVelocity = move / max(dt, 1.0 / 240)
        let start = SIMD2(Double(previous.x), Double(previous.y))

        for _ in 0..<births {
            var position = start + move * Double.random(in: 0...1, using: &rng)
            let velocity: SIMD2<Double>
            let life: Double
            let sigma: Double
            if comet {
                // Dust left behind the head, scattered a little sideways.
                position += normal * Double.random(in: -0.6...0.6, using: &rng) * settings.width
                velocity = -direction * Double.random(in: 5...30, using: &rng)
                    + normal * Double.random(in: -8...8, using: &rng)
                life = settings.length * Double.random(in: 0.5...1.0, using: &rng)
                sigma = Double.random(in: 1.4...2.8, using: &rng)
            } else {
                // Sparks thrown in every direction, carried a little by the head.
                let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
                velocity = SIMD2(cos(angle), sin(angle)) * Double.random(in: 20...90, using: &rng)
                    + headVelocity * 0.05
                life = Double.random(in: 0.35...0.6, using: &rng)
                sigma = Double.random(in: 1.4...2.8, using: &rng)
            }
            particles.append(Particle(
                position: position,
                velocity: velocity,
                age: 0,
                life: life,
                sigma: sigma,
                seed: Double.random(in: 0..<(2 * .pi), using: &rng),
                colorPosition: Double.random(in: 0...0.5, using: &rng)
            ))
        }
        if particles.count > Self.maxCount {
            particles.removeFirst(particles.count - Self.maxCount)
        }
    }

    public func instances(settings: TrailSettings) -> [ParticleInstance] {
        let preset = settings.preset
        return particles.map { particle in
            let t = particle.age / particle.life
            let twinkle = 0.75 + 0.25 * sin(particle.seed + 30 * particle.age)
            // Bright enough to read on top of the trail's own glow (shapes
            // combine with MAX, so a dim spark would simply disappear).
            let alpha = min(1, 1.5 * pow(1 - t, 1.1) * twinkle) * settings.opacity
            return ParticleInstance(
                center: SIMD2(Float(particle.position.x), Float(particle.position.y)),
                sigma: Float(particle.sigma),
                alpha: Float(alpha),
                color: preset.color(at: particle.colorPosition).simd
            )
        }
    }
}
