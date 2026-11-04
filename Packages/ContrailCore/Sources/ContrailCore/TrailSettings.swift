import Foundation

/// How the trail is drawn.
public enum TrailStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A glowing tube with a white-hot core.
    case neon
    /// A bright head with a short, thin tail and particles shed behind it.
    case comet
    /// A flat glowing band that twists along the path.
    case ribbon
    /// Evenly spaced glowing dots.
    case dotted
    /// The neon tube, throwing off sparks.
    case sparks

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .neon: "Neon"
        case .comet: "Comet"
        case .ribbon: "Ribbon"
        case .dotted: "Dotted"
        case .sparks: "Sparks"
        }
    }

    /// Whether this style emits particles (and so uses the Sparks amount).
    public var hasParticles: Bool { self == .comet || self == .sparks }
}

/// Everything the user can tune about the trail. Persisted as versioned JSON;
/// unknown or missing keys fall back to defaults so old and new builds can read
/// each other's settings.
public struct TrailSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var isEnabled: Bool
    public var presetID: String
    /// Core width at the head, in points.
    public var width: Double
    /// How many seconds of motion the trail shows.
    public var length: Double
    /// Glow strength, 0…1. The halo's size follows the width.
    public var glow: Double
    /// 0 = uniform width, 1 = tail narrows sharply to a hairline.
    public var taper: Double
    /// 0 = floaty and smooth, 1 = locked to the cursor.
    public var followSpeed: Double
    /// Seconds the trail holds still after the cursor stops before retracting.
    public var linger: Double
    /// Overall opacity, 0…1.
    public var opacity: Double
    /// Opaque matte stroke with a dark outline, readable on white backgrounds.
    public var highContrast: Bool
    /// Clicks & drags: a ring at every press that follows the cursor while
    /// the button is held and ripples out on release; while dragging, the
    /// trail also takes the drag color and widens.
    public var pressEffects: Bool
    /// Final ring diameter, in points.
    public var clickSize: Double
    /// Preset whose head color is used for right and middle clicks. Left
    /// clicks use the trail's own color.
    public var rightClickPresetID: String
    public var style: TrailStyle
    /// Particle amount for the Comet and Sparks styles, 0…1.
    public var sparks: Double
    /// When set, the trail only draws while this key is held.
    public var holdModifier: HoldModifier
    /// Per-app overrides, applied while that app is frontmost.
    public var appRules: [AppRule]
    /// Turn the trail off while a game is frontmost.
    public var offInGames: Bool
    /// The Look these settings were last based on, for "Custom · based on…"
    /// and Reset. Nil for settings that never came from a Look.
    public var baseLookID: String?
    /// Preset for the drag color; nil picks a contrasting one automatically.
    public var dragPresetID: String?

    public static let widthRange: ClosedRange<Double> = 2...20
    public static let lengthRange: ClosedRange<Double> = 0.15...1.5
    public static let unitRange: ClosedRange<Double> = 0...1
    public static let lingerRange: ClosedRange<Double> = 0...3
    public static let opacityRange: ClosedRange<Double> = 0.2...1
    public static let clickSizeRange: ClosedRange<Double> = 24...128

    public static let `default` = TrailSettings()

    public init(
        isEnabled: Bool = true,
        presetID: String = ColorPreset.defaultID,
        width: Double = 7,
        length: Double = 0.5,
        glow: Double = 0.7,
        taper: Double = 0.5,
        followSpeed: Double = 0.8,
        linger: Double = 0,
        opacity: Double = 1,
        highContrast: Bool = false,
        pressEffects: Bool = true,
        clickSize: Double = 56,
        rightClickPresetID: String = "magenta",
        style: TrailStyle = .neon,
        sparks: Double = 0.45,
        holdModifier: HoldModifier = .none,
        appRules: [AppRule] = [],
        offInGames: Bool = true,
        baseLookID: String? = Look.defaultID,
        dragPresetID: String? = nil
    ) {
        self.version = Self.currentVersion
        self.isEnabled = isEnabled
        self.presetID = presetID
        self.width = width
        self.length = length
        self.glow = glow
        self.taper = taper
        self.followSpeed = followSpeed
        self.linger = linger
        self.opacity = opacity
        self.highContrast = highContrast
        self.pressEffects = pressEffects
        self.clickSize = clickSize
        self.rightClickPresetID = rightClickPresetID
        self.style = style
        self.sparks = sparks
        self.holdModifier = holdModifier
        self.appRules = appRules
        self.offInGames = offInGames
        self.baseLookID = baseLookID
        self.dragPresetID = dragPresetID
    }

    /// The same settings with every value forced into its valid range.
    public func clamped() -> TrailSettings {
        var copy = self
        copy.version = Self.currentVersion
        copy.width = width.clamped(to: Self.widthRange)
        copy.length = length.clamped(to: Self.lengthRange)
        copy.glow = glow.clamped(to: Self.unitRange)
        copy.taper = taper.clamped(to: Self.unitRange)
        copy.followSpeed = followSpeed.clamped(to: Self.unitRange)
        copy.linger = linger.clamped(to: Self.lingerRange)
        copy.opacity = opacity.clamped(to: Self.opacityRange)
        if ColorPreset.preset(id: presetID) == nil {
            copy.presetID = ColorPreset.defaultID
        }
        copy.clickSize = clickSize.clamped(to: Self.clickSizeRange)
        copy.sparks = sparks.clamped(to: Self.unitRange)
        if let id = dragPresetID, ColorPreset.preset(id: id) == nil {
            copy.dragPresetID = nil
        }
        if ColorPreset.preset(id: rightClickPresetID) == nil {
            copy.rightClickPresetID = TrailSettings.default.rightClickPresetID
        }
        return copy
    }

    /// The preset this configuration refers to.
    public var preset: ColorPreset {
        ColorPreset.preset(id: presetID) ?? ColorPreset.default
    }

    /// Width multiplier for the stretch of trail drawn while dragging.
    public static let dragWidthScale = 1.6
    /// Widest a dragged stretch gets, in points.
    public static let dragMaxWidth = 24.0

    /// Presets considered warm: the automatic drag color switches to cyan
    /// for these so the drag still contrasts.
    static let warmPresetIDs: Set<String> = ["amber", "coral", "sunset", "magenta"]

    /// The color of the trail while dragging: the chosen preset, or amber
    /// (cyan when the trail itself is warm).
    public var dragColor: TrailColor {
        if let id = dragPresetID, let preset = ColorPreset.preset(id: id) {
            return preset.stops[0]
        }
        let autoID = Self.warmPresetIDs.contains(presetID) ? "cyan" : "amber"
        return ColorPreset.preset(id: autoID)!.stops[0]
    }

    /// Ring color for a left click (the trail's head color) or any other click.
    public func rippleColor(primary: Bool) -> TrailColor {
        if primary { return preset.stops[0] }
        return (ColorPreset.preset(id: rightClickPresetID) ?? ColorPreset.default).stops[0]
    }

    private enum CodingKeys: String, CodingKey {
        case version, isEnabled, presetID, width, length, glow
        case taper, followSpeed, linger, opacity, highContrast
        case pressEffects, clickSize, rightClickPresetID, style, sparks
        case holdModifier, appRules, offInGames, baseLookID, dragPresetID
    }

    /// Keys from 0.3–0.4, read once to migrate into `pressEffects`.
    private enum LegacyKeys: String, CodingKey {
        case clickRipples, dragHighlight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TrailSettings()
        self.version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        self.isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? d.isEnabled
        self.presetID = (try? c.decodeIfPresent(String.self, forKey: .presetID)) ?? d.presetID
        self.width = (try? c.decodeIfPresent(Double.self, forKey: .width)) ?? d.width
        self.length = (try? c.decodeIfPresent(Double.self, forKey: .length)) ?? d.length
        self.glow = (try? c.decodeIfPresent(Double.self, forKey: .glow)) ?? d.glow
        self.taper = (try? c.decodeIfPresent(Double.self, forKey: .taper)) ?? d.taper
        self.followSpeed = (try? c.decodeIfPresent(Double.self, forKey: .followSpeed)) ?? d.followSpeed
        self.linger = (try? c.decodeIfPresent(Double.self, forKey: .linger)) ?? d.linger
        self.opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? d.opacity
        self.highContrast = (try? c.decodeIfPresent(Bool.self, forKey: .highContrast)) ?? d.highContrast
        if let value = try? c.decodeIfPresent(Bool.self, forKey: .pressEffects) {
            self.pressEffects = value
        } else {
            // Before 0.5, click ripples (default off) and drag highlight
            // (default on) were separate; either one on means on.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let ripples = (try? legacy.decodeIfPresent(Bool.self, forKey: .clickRipples)) ?? false
            let drag = (try? legacy.decodeIfPresent(Bool.self, forKey: .dragHighlight)) ?? true
            self.pressEffects = ripples || drag
        }
        self.clickSize = (try? c.decodeIfPresent(Double.self, forKey: .clickSize)) ?? d.clickSize
        self.rightClickPresetID = (try? c.decodeIfPresent(String.self, forKey: .rightClickPresetID)) ?? d.rightClickPresetID
        // An unknown style (from a newer version) falls back to Neon.
        self.style = (try? c.decodeIfPresent(TrailStyle.self, forKey: .style)) ?? d.style
        self.sparks = (try? c.decodeIfPresent(Double.self, forKey: .sparks)) ?? d.sparks
        self.holdModifier = (try? c.decodeIfPresent(HoldModifier.self, forKey: .holdModifier)) ?? d.holdModifier
        // Rules decode one by one: a rule this version can't read (say, a
        // mode added later) is skipped instead of dropping all of them.
        self.appRules = (try? c.decodeIfPresent([Lossy<AppRule>].self, forKey: .appRules))?
            .compactMap(\.value) ?? d.appRules
        self.offInGames = (try? c.decodeIfPresent(Bool.self, forKey: .offInGames)) ?? d.offInGames
        self.dragPresetID = (try? c.decodeIfPresent(String.self, forKey: .dragPresetID)) ?? nil
        // Settings saved before Looks existed have no base Look.
        self.baseLookID = c.contains(.baseLookID)
            ? (try? c.decodeIfPresent(String.self, forKey: .baseLookID)) ?? nil
            : nil
    }
}

/// Decodes a value, or nil if it can't be read, without failing the
/// surrounding container.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
