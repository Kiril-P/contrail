import AppKit
import ContrailCore
import KeyboardShortcuts
import SwiftUI

/// The menu-bar popover: pick a Look, flip the quick toggles, done.
/// Everything granular lives in Settings.
struct MenuPopover: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var activation: ActivationController
    let openSettings: () -> Void

    private var settings: Binding<TrailSettings> { $store.settings }
    /// Re-read when the popover opens, so a shortcut changed in Settings shows.
    @State private var shortcut = KeyboardShortcuts.getShortcut(for: .toggleTrail)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            LooksPicker(store: store, columns: 2, openSettings: openSettings)

            Divider()

            HStack(spacing: 4) {
                QuickToggle(
                    title: "Click ripples", systemImage: "dot.circle.and.hand.point.up.left.fill",
                    help: "Show a ring wherever you click", isOn: settings.clickRipples
                )
                QuickToggle(
                    title: "Drag highlight", systemImage: "hand.draw.fill",
                    help: "Highlight the trail while you hold a mouse button and drag", isOn: settings.dragHighlight
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
