import AppKit
import ContrailCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval
    @State private var launchNeedsApproval = LaunchAtLogin.needsApproval
    @State private var launchError: String?

    private var settings: Binding<TrailSettings> { $store.settings }

    var body: some View {
        Form {
            Section("Trail") {
                PreviewCard(store: store, height: 96)
                    .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                LabeledContent("Color") {
                    PresetPicker(selection: settings.presetID, size: 22, spacing: 8)
                }
                SliderRow(title: "Width", value: settings.width, range: TrailSettings.widthRange, step: 1, format: Formats.points)
                SliderRow(title: "Length", value: settings.length, range: TrailSettings.lengthRange, format: Formats.seconds)
                SliderRow(title: "Glow", value: settings.glow, range: TrailSettings.unitRange, format: Formats.percent)
                    .disabled(store.settings.highContrast)
                SliderRow(title: "Taper", value: settings.taper, range: TrailSettings.unitRange, format: Formats.percent)
                SliderRow(title: "Opacity", value: settings.opacity, range: TrailSettings.opacityRange, format: Formats.percent)
                Toggle(isOn: settings.highContrast) {
                    Text("High contrast")
                    Text("A solid, outlined trail that stays visible on white and light backgrounds.")
                }
            }

            Section("Clicks") {
                Toggle(isOn: settings.clickRipples) {
                    Text("Click ripples")
                    Text("Show an expanding ring wherever you click. Left clicks use the trail color.")
                }
                SliderRow(title: "Size", value: settings.clickSize, range: TrailSettings.clickSizeRange, step: 1, format: Formats.points)
                    .disabled(!store.settings.clickRipples)
                LabeledContent("Right click") {
                    PresetPicker(selection: settings.rightClickPresetID, size: 22, spacing: 8)
                }
                .disabled(!store.settings.clickRipples)
            }

            Section("Motion") {
                SliderRow(title: "Follow", value: settings.followSpeed, range: TrailSettings.unitRange, format: followLabel)
                SliderRow(title: "Hold", value: settings.linger, range: TrailSettings.lingerRange, format: Formats.seconds)
                Text("Follow sets how tightly the trail tracks the pointer. Hold keeps the trail in place for a moment after the pointer stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Show trail", isOn: settings.isEnabled)
                Toggle("Open at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        launchError = LaunchAtLogin.set(newValue)
                        refreshLoginItem()
                    }
                ))
                if launchNeedsApproval {
                    HStack {
                        Text("Contrail is turned off in Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { LaunchAtLogin.openLoginItemsSettings() }
                    }
                } else if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { store.resetToDefaults() }
                }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.versionString)
                Text("Contrail is free software, licensed under the GNU GPL v3.")
                    .foregroundStyle(.secondary)
                Link("github.com/Kiril-P/contrail", destination: URL(string: "https://github.com/Kiril-P/contrail")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: refreshLoginItem)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginItem()
        }
    }

    /// The login item can change in System Settings while this window is
    /// hidden, so re-read it whenever the window or app comes back.
    private func refreshLoginItem() {
        launchNeedsApproval = LaunchAtLogin.needsApproval
        // Registered but awaiting approval still counts as on, so switching it
        // off unregisters Contrail and dismisses the note.
        launchAtLogin = LaunchAtLogin.isEnabled || launchNeedsApproval
    }

    private func followLabel(_ value: Double) -> String {
        value >= 0.999 ? "Locked" : Formats.percent(value)
    }
}

extension Bundle {
    var versionString: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Hosts SettingsView in a regular window. Managed by hand because SwiftUI's
/// Settings scene is unreliable in menu-bar-only (LSUIElement) apps.
@MainActor
final class SettingsWindowController {
    private let store: SettingsStore
    private var window: NSWindow?

    init(store: SettingsStore) {
        self.store = store
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(store: store))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Contrail Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("ContrailSettings")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
