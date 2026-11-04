import AppKit
import ContrailCore
import KeyboardShortcuts
import SwiftUI

/// The menu-bar popover: pick a Look, flip the quick toggles, done.
/// Everything granular lives in Settings.
struct MenuPopover: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var activation: ActivationController
    @ObservedObject var updates: UpdateController
    let openSettings: () -> Void

    private var settings: Binding<TrailSettings> { $store.settings }
    /// Re-read when the popover opens, so a shortcut changed in Settings shows.
    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .toggleTrail)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let version = updates.availableVersion {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Contrail \(version) is available")
                        .lineLimit(1)
                    Spacer()
                    Button("Install…", action: updates.checkForUpdates)
                        .controlSize(.small)
                }
                .font(.callout)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.12)))
            }

            LooksPicker(store: store, columns: 2, openSettings: openSettings)

            Divider()

            HStack(spacing: 4) {
                QuickToggle(
                    title: "Clicks & drags", systemImage: "dot.circle.and.hand.point.up.left.fill",
                    help: "A ring when you press that follows your drag and ripples out on release",
                    isOn: settings.pressEffects
                )
                QuickToggle(
                    title: "High contrast", systemImage: "circle.lefthalf.filled",
                    help: "A solid, outlined trail for light backgrounds", isOn: settings.highContrast
                )
            }

            Divider()

            HStack {
                Button("Settings…", action: openSettings)
                    .keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { shortcut = KeyboardShortcuts.getShortcut(for: .toggleTrail) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Contrail")
                        .font(.headline)
                    if let shortcut {
                        Text(shortcut.description)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .help("Turn the trail on or off from anywhere")
                    }
                }
                if let reason = activation.decision.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Show trail", isOn: Binding(
                get: { activation.isOn },
                set: { _ in activation.toggle() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Show trail")
        }
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
            .accessibilityElement()
            .accessibilityLabel("Trail preview")
    }
}
