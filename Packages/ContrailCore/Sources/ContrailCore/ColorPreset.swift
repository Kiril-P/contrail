import Foundation

/// A linear (non-premultiplied) sRGB color.
public struct TrailColor: Equatable, Sendable {
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
    public let stops: [TrailColor]

    public init(id: String, name: String, stops: [TrailColor]) {
        precondition(!stops.isEmpty && stops.count <= Self.maxStops)
        self.id = id
        self.name = name
        self.stops = stops
    }

    public var isGradient: Bool { stops.count > 1 }

    /// Color at a position along the trail, 0 = head, 1 = tail.
    public func color(at t: Double) -> TrailColor {
        guard stops.count > 1 else { return stops[0] }
        let position = Float(min(max(t, 0), 1)) * Float(stops.count - 1)
        let index = min(Int(position), stops.count - 2)
        let f = position - Float(index)
        let a = stops[index], b = stops[index + 1]
        return TrailColor(
            red: a.red + (b.red - a.red) * f,
            green: a.green + (b.green - a.green) * f,
            blue: a.blue + (b.blue - a.blue) * f
        )
    }

    public static let defaultID = "cyan"

    /// The built-in palette, in swatch order. Gradient stops run head → tail.
    public static let all: [ColorPreset] = [
        ColorPreset(id: "cyan", name: "Cyan", stops: [TrailColor(hex: 0x28DCFF)]),
        ColorPreset(id: "violet", name: "Violet", stops: [TrailColor(hex: 0x9B6BFF)]),
        ColorPreset(id: "magenta", name: "Magenta", stops: [TrailColor(hex: 0xFF3FCB)]),
        ColorPreset(id: "coral", name: "Coral", stops: [TrailColor(hex: 0xFF6B73)]),
        ColorPreset(id: "amber", name: "Amber", stops: [TrailColor(hex: 0xFFB52E)]),
        ColorPreset(id: "lime", name: "Lime", stops: [TrailColor(hex: 0xB7FF38)]),
        ColorPreset(id: "ice", name: "Ice", stops: [TrailColor(hex: 0xBCDFFF)]),
        ColorPreset(id: "sunset", name: "Sunset", stops: [TrailColor(hex: 0xFF4FAD), TrailColor(hex: 0xFF6B73), TrailColor(hex: 0xFFB52E)]),
        ColorPreset(id: "aurora", name: "Aurora", stops: [TrailColor(hex: 0x2EF2C2), TrailColor(hex: 0x3D8BFF), TrailColor(hex: 0x9B6BFF)]),
    ]

    public static var `default`: ColorPreset { preset(id: defaultID)! }

    public static func preset(id: String) -> ColorPreset? {
        all.first { $0.id == id }
    }
}
