import Foundation

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

    public static let widthRange: ClosedRange<Double> = 2...20
    public static let lengthRange: ClosedRange<Double> = 0.15...1.5
    public static let unitRange: ClosedRange<Double> = 0...1
    public static let lingerRange: ClosedRange<Double> = 0...3
    public static let opacityRange: ClosedRange<Double> = 0.2...1

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
        highContrast: Bool = false
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
        return copy
    }

    /// The preset this configuration refers to.
    public var preset: ColorPreset {
        ColorPreset.preset(id: presetID) ?? ColorPreset.default
    }

    private enum CodingKeys: String, CodingKey {
        case version, isEnabled, presetID, width, length, glow
        case taper, followSpeed, linger, opacity, highContrast
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
