import AppKit
import ContrailCore
import SwiftUI

/// The menu-bar popover: the controls people change during a demo.
/// Set-once options live in the Settings window.
struct MenuPopover: View {
    @ObservedObject var store: SettingsStore
    let openSettings: () -> Void

    private var settings: Binding<TrailSettings> { $store.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Contrail")
                    .font(.headline)
                Spacer()
                Toggle("Show trail", isOn: settings.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Show trail")
            }

            PreviewCard(store: store)

            PresetPicker(selection: settings.presetID)
                .frame(maxWidth: .infinity)

            Picker("Style", selection: settings.style) {
                ForEach(TrailStyle.allCases) { style in
                    Text(style.name).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            VStack(spacing: 8) {
                SliderRow(title: "Width", value: settings.width, range: TrailSettings.widthRange, step: 1, format: Formats.points)
                SliderRow(title: "Length", value: settings.length, range: TrailSettings.lengthRange, format: Formats.seconds)
                SliderRow(title: "Glow", value: settings.glow, range: TrailSettings.unitRange, format: Formats.percent)
                    .disabled(store.settings.highContrast)
                if store.settings.style.hasParticles {
                    SliderRow(title: "Sparks", value: settings.sparks, range: TrailSettings.unitRange, format: Formats.percent)
                        .disabled(store.settings.highContrast)
                }
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("High contrast")
                    Text("Solid trail for light backgrounds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("High contrast", isOn: settings.highContrast)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Click ripples")
                    Text("A ring wherever you click")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Click ripples", isOn: settings.clickRipples)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            if store.settings.clickRipples {
                SliderRow(title: "Size", value: settings.clickSize, range: TrailSettings.clickSizeRange, step: 1, format: Formats.points)
            }

            Divider()

            HStack {
                Button("Settings…", action: openSettings)
                    .keyboardShortcut(",")
                Spacer()
                Button("Quit Contrail") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// The live preview on a background that matches the current mode.
struct PreviewCard: View {
    @ObservedObject var store: SettingsStore
    var height: CGFloat = 72

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        TrailPreview(store: store)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(store.settings.highContrast ? Color.white : Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1C / 255))
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .opacity(store.settings.isEnabled ? 1 : 0.5)
            .accessibilityElement()
            .accessibilityLabel("Trail preview")
    }
}
