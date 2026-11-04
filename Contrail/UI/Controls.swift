import ContrailCore
import SwiftUI

extension TrailColor {
    var color: Color { Color(.sRGB, red: Double(red), green: Double(green), blue: Double(blue)) }
}

extension ColorPreset {
    /// Swatch fill: solid, or the gradient running head (left) → tail (right).
    var swatchStyle: AnyShapeStyle {
        if isGradient {
            return AnyShapeStyle(LinearGradient(colors: stops.map(\.color), startPoint: .leading, endPoint: .trailing))
        }
        return AnyShapeStyle(stops[0].color)
    }
}

/// Nine round color chips.
struct PresetPicker: View {
    @Binding var selection: String
    var size: CGFloat = 24
    var spacing: CGFloat = 9

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(ColorPreset.all) { preset in
                let selected = preset.id == selection
                Button {
                    selection = preset.id
                } label: {
                    Circle()
                        .fill(preset.swatchStyle)
                        .frame(width: size, height: size)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(-3)
                .help(preset.name)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// A labeled slider with a right-aligned value.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String

    /// Rounds to `step` without drawing tick marks under the slider.
    private var steppedValue: Binding<Double> {
        guard let step else { return $value }
        return Binding(
            get: { value },
            set: { value = ($0 / step).rounded() * step }
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 62, alignment: .leading)
            Slider(value: steppedValue, in: range)
            .controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityValue(format(value))
            Text(format(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

enum Formats {
    static func points(_ value: Double) -> String { "\(Int(value.rounded())) pt" }
    static func seconds(_ value: Double) -> String { String(format: "%.2f s", value).replacingOccurrences(of: "0 s", with: " s") }
    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
