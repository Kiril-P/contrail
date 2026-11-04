import Foundation

/// The S / M / L size control: a multiplier on a Look's width.
public enum LookSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, medium, large

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }

    public var name: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    public var scale: Double {
        switch self {
        case .small: 0.7
        case .medium: 1
        case .large: 1.5
        }
    }
}

/// A hand-tuned combination of trail settings, picked from the menu-bar
/// popover. A Look owns how the trail looks and moves; it leaves High
/// contrast, clicks, drags and activation alone.
public struct Look: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    /// One line for tooltips and accessibility.
    public let blurb: String
    public let style: TrailStyle
    public let presetID: String
    public let width: Double
    public let length: Double
    public let glow: Double
    public let taper: Double
    public let followSpeed: Double
    public let linger: Double
    public let opacity: Double
    public let sparks: Double

    /// The built-in Looks, in popover order. Neon matches the defaults.
    public static let all: [Look] = [
        Look(id: "neon", name: "Neon", blurb: "A classic cyan neon tube",
             style: .neon, presetID: "cyan", width: 7, length: 0.5, glow: 0.7, taper: 0.5,
             followSpeed: 0.8, linger: 0, opacity: 1, sparks: 0.45),
        Look(id: "aurora", name: "Aurora", blurb: "A teal-to-violet ribbon",
             style: .ribbon, presetID: "aurora", width: 6, length: 0.7, glow: 0.6, taper: 0.3,
             followSpeed: 0.85, linger: 0, opacity: 1, sparks: 0.45),
        Look(id: "comet", name: "Comet", blurb: "An amber head shedding dust",
             style: .comet, presetID: "amber", width: 7, length: 0.45, glow: 0.85, taper: 0.85,
             followSpeed: 0.9, linger: 0, opacity: 1, sparks: 0.55),
        Look(id: "sparkler", name: "Sparkler", blurb: "A sunset tube throwing sparks",
             style: .sparks, presetID: "sunset", width: 6, length: 0.45, glow: 0.8, taper: 0.6,
             followSpeed: 0.85, linger: 0, opacity: 1, sparks: 0.65),
        Look(id: "dots", name: "Dots", blurb: "Violet breadcrumbs that linger",
             style: .dotted, presetID: "violet", width: 6, length: 0.9, glow: 0.5, taper: 0.2,
             followSpeed: 0.9, linger: 0.3, opacity: 1, sparks: 0.45),
        Look(id: "whisper", name: "Whisper", blurb: "A thin, quiet line for recordings",
             style: .neon, presetID: "ice", width: 3, length: 0.3, glow: 0.4, taper: 0.8,
             followSpeed: 0.95, linger: 0, opacity: 0.8, sparks: 0.45),
    ]

    public static let defaultID = "neon"

    public static func look(id: String?) -> Look? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The width this Look uses at `size`, on a half-point grid and in range.
    public func width(at size: LookSize) -> Double {
        ((width * size.scale * 2).rounded() / 2).clamped(to: TrailSettings.widthRange)
    }

    /// Applies this Look at `size`, keeping everything a Look doesn't own.
    public func apply(to settings: inout TrailSettings, size: LookSize) {
        settings.style = style
        settings.presetID = presetID
        settings.width = width(at: size)
        settings.length = length
        settings.glow = glow
        settings.taper = taper
        settings.followSpeed = followSpeed
        settings.linger = linger
        settings.opacity = opacity
        settings.sparks = sparks
        settings.baseLookID = id
    }

    /// The size at which `settings` is exactly this Look, if any.
    public func matchingSize(_ settings: TrailSettings) -> LookSize? {
        func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }
        guard settings.style == style, settings.presetID == presetID,
              same(settings.length, length), same(settings.glow, glow), same(settings.taper, taper),
              same(settings.followSpeed, followSpeed), same(settings.linger, linger),
              same(settings.opacity, opacity),
              // Sparks only matters for styles that emit particles.
              !style.hasParticles || same(settings.sparks, sparks)
        else { return nil }
        return LookSize.allCases.first { same(settings.width, width(at: $0)) }
    }
}

/// Which Look the current settings are, or Custom.
public enum LookSelection: Equatable, Sendable {
    case look(Look, LookSize)
    /// Tweaked in Settings; `base` is the Look it started from, if known.
    case custom(base: Look?)

    public init(_ settings: TrailSettings) {
        for look in Look.all {
            if let size = look.matchingSize(settings) {
                self = .look(look, size)
                return
            }
        }
        self = .custom(base: Look.look(id: settings.baseLookID))
    }

    public var look: Look? {
        if case let .look(look, _) = self { return look }
        return nil
    }

    public var size: LookSize? {
        if case let .look(_, size) = self { return size }
        return nil
    }
}
