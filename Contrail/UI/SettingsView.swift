import AppKit
import ContrailCore
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window: Appearance, Activation and General tabs.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        TabView {
            AppearanceSettings(store: store)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            ActivationSettings(store: store)
                .tabItem { Label("Activation", systemImage: "keyboard") }
            GeneralSettings(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Appearance

struct AppearanceSettings: View {
    @ObservedObject var store: SettingsStore
    private var settings: Binding<TrailSettings> { $store.settings }

    var body: some View {
        Form {
            Section("Trail") {
                PreviewCard(store: store, height: 96)
                    .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                LabeledContent("Color") {
                    PresetPicker(selection: settings.presetID, size: 22, spacing: 8)
                }
                Picker("Style", selection: settings.style) {
                    ForEach(TrailStyle.allCases) { style in
                        Text(style.name).tag(style)
                    }
                }
                SliderRow(title: "Sparks", value: settings.sparks, range: TrailSettings.unitRange, format: Formats.percent)
                    .disabled(!store.settings.style.hasParticles || store.settings.highContrast)
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

            HStack {
                Spacer()
                Button("Reset Appearance") { store.resetAppearance() }
            }
        }
        .formStyle(.grouped)
    }

    private func followLabel(_ value: Double) -> String {
        value >= 0.999 ? "Locked" : Formats.percent(value)
    }
}

// MARK: Activation

struct ActivationSettings: View {
    @ObservedObject var store: SettingsStore
    private var settings: Binding<TrailSettings> { $store.settings }

    /// Presentation apps offered as one-click rules while the list is empty.
    private static let suggestions: [(bundleID: String, name: String)] = [
        ("com.apple.iWork.Keynote", "Keynote"),
        ("com.microsoft.Powerpoint", "PowerPoint"),
    ]

    var body: some View {
        Form {
            Section("Shortcut") {
                KeyboardShortcuts.Recorder("Turn trail on or off", name: .toggleTrail)
                Picker("Show trail only while holding", selection: settings.holdModifier) {
                    ForEach(HoldModifier.allCases) { modifier in
                        Text(modifier.name).tag(modifier)
                    }
                }
            }

            Section {
                if store.settings.appRules.isEmpty {
                    Text("No rules yet. Rules turn the trail on or off while an app is in front.")
                        .foregroundStyle(.secondary)
                    let available = Self.suggestions.filter { AppInfo.isInstalled($0.bundleID) }
                    if !available.isEmpty {
                        HStack {
                            Text("Suggested:")
                                .foregroundStyle(.secondary)
                            ForEach(available, id: \.bundleID) { app in
                                Button("Always on in \(app.name)") {
                                    addRule(bundleID: app.bundleID, name: app.name)
                                }
                            }
                        }
                    }
                }
                ForEach(store.settings.appRules) { rule in
                    HStack(spacing: 10) {
                        Image(nsImage: AppInfo.icon(for: rule.bundleID))
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(rule.name)
                        Spacer()
                        Picker(rule.name, selection: mode(for: rule.bundleID)) {
                            ForEach(AppRuleMode.allCases) { mode in
                                Text(mode.name).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            store.settings.appRules.removeAll { $0.bundleID == rule.bundleID }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove rule for \(rule.name)")
                    }
                }
                HStack {
                    Spacer()
                    Button("Add App…", action: chooseApp)
                }
            } header: {
                Text("Per-app rules")
            } footer: {
                Text("A rule wins over your switch. Using the switch or shortcut in that app overrides it until you switch apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: settings.offInGames) {
                    Text("Turn off in games")
                    Text("Apps that declare themselves as games. Add a rule for anything else, such as a video player.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func mode(for bundleID: String) -> Binding<AppRuleMode> {
        Binding(
            get: { store.settings.appRules.first { $0.bundleID == bundleID }?.mode ?? .always },
            set: { mode in
                if let index = store.settings.appRules.firstIndex(where: { $0.bundleID == bundleID }) {
                    store.settings.appRules[index].mode = mode
                }
            }
        )
    }

    private func addRule(bundleID: String, name: String) {
        guard !store.settings.appRules.contains(where: { $0.bundleID == bundleID }) else { return }
        store.settings.appRules.append(AppRule(bundleID: bundleID, name: name, mode: .always))
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier else { continue }
            addRule(bundleID: bundleID, name: AppInfo.displayName(at: url))
        }
    }
}

/// Looks up installed apps by bundle ID.
@MainActor
enum AppInfo {
    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        url(for: bundleID) != nil
    }

    static func icon(for bundleID: String) -> NSImage {
        if let url = url(for: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }

    static func displayName(at url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

// MARK: General

struct GeneralSettings: View {
    @ObservedObject var store: SettingsStore
    @State private var launchAtLogin = LaunchAtLogin.isEnabled || LaunchAtLogin.needsApproval
    @State private var launchNeedsApproval = LaunchAtLogin.needsApproval
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
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
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.versionString)
                Text("Contrail is free software, licensed under the GNU GPL v3.")
                    .foregroundStyle(.secondary)
                Link("github.com/Kiril-P/contrail", destination: URL(string: "https://github.com/Kiril-P/contrail")!)
            }
        }
        .formStyle(.grouped)
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
            hosting.sizingOptions = [.preferredContentSize]
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
