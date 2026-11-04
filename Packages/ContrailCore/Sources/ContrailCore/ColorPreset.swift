import Foundation

/// A linear (non-premultiplied) sRGB color.
public struct RGBColor: Equatable, Sendable {
    public var red: Float
    public var green: Float
    public var blue: Float

    public init(red: Float, green: Float, blue: Float) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Creates a color from a 24-bit hex value such as `0x22D3EE`.
    public init(hex: UInt32) {
        self.red = Float((hex >> 16) & 0xFF) / 255
        self.green = Float((hex >> 8) & 0xFF) / 255
        self.blue = Float(hex & 0xFF) / 255
    }

    public var simd: SIMD4<Float> { SIMD4(red, green, blue, 1) }
}

/// A named trail color. Gradient presets blend from the head (first stop) to
/// the tail (last stop).
public struct ColorPreset: Identifiable, Equatable, Sendable {
    public static let maxStops = 4

    public let id: String
    public let name: String
    public let stops: [RGBColor]

    public init(id: String, name: String, stops: [RGBColor]) {
        precondition(!stops.isEmpty && stops.count <= Self.maxStops)
        self.id = id
        self.name = name
        self.stops = stops
    }

    public var isGradient: Bool { stops.count > 1 }

    /// Color at a position along the trail, 0 = head, 1 = tail.
    public func color(at t: Double) -> RGBColor {
        guard stops.count > 1 else { return stops[0] }
        let position = Float(min(max(t, 0), 1)) * Float(stops.count - 1)
        let index = min(Int(position), stops.count - 2)
        let f = position - Float(index)
        let a = stops[index], b = stops[index + 1]
        return RGBColor(
            red: a.red + (b.red - a.red) * f,
            green: a.green + (b.green - a.green) * f,
            blue: a.blue + (b.blue - a.blue) * f
        )
    }

    public static let defaultID = "violet"

    public static let all: [ColorPreset] = [
        ColorPreset(id: "violet", name: "Violet", stops: [RGBColor(hex: 0x9B6BFF)]),
        ColorPreset(id: "cyan", name: "Cyan", stops: [RGBColor(hex: 0x22D3EE)]),
        ColorPreset(id: "magenta", name: "Magenta", stops: [RGBColor(hex: 0xF43FBF)]),
        ColorPreset(id: "lime", name: "Lime", stops: [RGBColor(hex: 0xA3E635)]),
        ColorPreset(id: "amber", name: "Amber", stops: [RGBColor(hex: 0xFBBF24)]),
        ColorPreset(id: "coral", name: "Coral", stops: [RGBColor(hex: 0xFF6B6B)]),
        ColorPreset(id: "ice", name: "Ice", stops: [RGBColor(hex: 0xE6F4FF)]),
        ColorPreset(id: "ember", name: "Ember", stops: [RGBColor(hex: 0xFFB020), RGBColor(hex: 0xFF3D7F)]),
        ColorPreset(id: "aurora", name: "Aurora", stops: [RGBColor(hex: 0x2DD4BF), RGBColor(hex: 0x3B82F6), RGBColor(hex: 0xA855F7)]),
    ]

    public static var `default`: ColorPreset { preset(id: defaultID)! }

    public static func preset(id: String) -> ColorPreset? {
        all.first { $0.id == id }
    }
}
