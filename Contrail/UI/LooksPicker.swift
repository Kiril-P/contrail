import AppKit
import ContrailCore
import SwiftUI

/// Still thumbnails of each Look, drawn by the real renderer and cached.
@MainActor
final class LookThumbnails {
    static let shared = LookThumbnails()
    static let size = CGSize(width: 140, height: 46)

    private var cache: [String: NSImage] = [:]

    func image(for look: Look, size: LookSize, highContrast: Bool) -> NSImage? {
        let key = "\(look.id)-\(size.rawValue)-\(highContrast)"
        if let cached = cache[key] { return cached }
        var settings = TrailSettings.default
        look.apply(to: &settings, size: size)
        settings.highContrast = highContrast
        // Transparent: the card draws the background behind it. Each Look is
        // sampled with its own trail length, which is part of its character.
        guard let cgImage = SnapshotRenderer.renderImage(
            settings: settings, background: nil, size: Self.size, keepLength: true
        ) else { return nil }
        let image = NSImage(cgImage: cgImage, size: Self.size)
        cache[key] = image
        return image
    }

    /// Renders every Look's still for one size and mode ahead of time, so
    /// opening the popover doesn't stall on the GPU.
    func prewarm(size: LookSize, highContrast: Bool) {
        for look in Look.all {
            _ = image(for: look, size: size, highContrast: highContrast)
        }
    }
}

/// The Looks grid, the S/M/L size control and, when the settings were
/// tweaked, a Custom row. Shared by the popover and Settings.
struct LooksPicker: View {
    @ObservedObject var store: SettingsStore
    var columns = 2
    /// Animate the selected Look (and a Custom trail). Off in Settings,
    /// which has its own preview.
    var livePreview = true
    var openSettings: (() -> Void)?

    private var selection: LookSelection { LookSelection(store.settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(Look.all) { look in
                    LookCard(
                        look: look,
                        store: store,
                        isSelected: selection.look?.id == look.id,
                        isLive: livePreview && selection.look?.id == look.id,
                        size: store.settings.lookSize
                    ) {
                        choose(look)
                    }
                }
            }

            if case let .custom(base) = selection {
                if livePreview {
                    // No card shows a Custom trail, so preview it here.
                    PreviewCard(store: store, height: LookThumbnails.size.height)
                }
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                    Text(base.map { "Custom · based on \($0.name)" } ?? "Custom")
                        .lineLimit(1)
                    Spacer()
                    if let openSettings {
                        Button("Edit…", action: openSettings)
                            .buttonStyle(.link)
                    }
                    if let base {
                        Button("Reset") { choose(base) }
                            .controlSize(.small)
                            .help("Go back to \(base.name)")
                    }
                }
                .font(.callout)
            }

            HStack {
                Text("Size")
                Spacer()
                Picker("Size", selection: Binding(
                    get: { store.settings.lookSize },
                    set: { size in
                        if let look = selection.look { look.apply(to: &store.settings, size: size) }
                    }
                )) {
                    ForEach(LookSize.allCases) { size in
                        Text(size.label).tag(size)
                            .help(size.name)
                            .accessibilityLabel(size.name)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Trail size")
                .fixedSize()
                .disabled(selection.look == nil)
                .help(selection.look == nil ? "Adjust the width in Settings" : "Trail size")
            }
        }
    }

    /// Applies `look`, keeping the current size (for Custom, the size
    /// closest to its width).
    private func choose(_ look: Look) {
        look.apply(to: &store.settings, size: store.settings.lookSize)
    }
}

/// One Look: a thumbnail (live for the selected Look) and its name.
private struct LookCard: View {
    let look: Look
    @ObservedObject var store: SettingsStore
    let isSelected: Bool
    let isLive: Bool
    let size: LookSize
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                // A fixed-height slot that never widens its grid column.
                Color.clear
                    .frame(height: LookThumbnails.size.height)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .overlay { thumbnail }
                    .clipped()
                    .background(store.settings.highContrast ? Color.white : Color(red: 0x14 / 255, green: 0x16 / 255, blue: 0x1C / 255))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                HStack {
                    Text(look.name)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 2)
            }
            .padding(5)
            .background(shape.fill(Color.primary.opacity(isSelected ? 0.08 : 0.04)))
            .overlay(shape.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(look.blurb)
        .accessibilityLabel(look.name)
        .accessibilityHint(look.blurb)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var thumbnail: some View {
        if isLive {
            // One live preview, using the real engine and renderer.
            TrailPreview(store: store)
        } else if let image = LookThumbnails.shared.image(for: look, size: size, highContrast: store.settings.highContrast) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }
}

/// A compact on/off button with an icon and a label, for the popover's
/// quick toggles.
struct QuickToggle: View {
    let title: String
    let systemImage: String
    let help: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isOn ? Color.accentColor : Color.primary.opacity(0.08))
                    )
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}
