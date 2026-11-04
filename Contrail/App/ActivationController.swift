import AppKit
import Combine
import ContrailCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Turns the trail on or off. Needs no permission (Carbon hot keys).
    static let toggleTrail = Self("toggleTrail", initial: .init(.t, modifiers: [.control, .option]))
}

/// Decides whether the trail is on right now, from the user's switch, the
/// toggle shortcut, per-app rules and the frontmost app. See
/// `ActivationPolicy` for the precedence.
@MainActor
final class ActivationController: ObservableObject {
    @Published private(set) var decision: ActivationPolicy.Decision

    private let store: SettingsStore
    private var state = ActivationState()
    private var cancellables: Set<AnyCancellable> = []
    private var observer: NSObjectProtocol?

    var isOn: Bool { decision.isOn }

    init(store: SettingsStore) {
        self.store = store
        self.decision = ActivationPolicy.decide(settings: store.settings, frontmost: nil, override: nil)

        if let app = NSWorkspace.shared.frontmostApplication, !Self.isSelf(app) {
            state.activated(Self.describe(app))
        }
        recompute(settings: store.settings)

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(app) }
        }
        // @Published emits before the new value is stored, so use the value
        // passed in rather than reading the store.
        store.$settings
            .sink { [weak self] settings in self?.recompute(settings: settings) }
            .store(in: &cancellables)
        KeyboardShortcuts.onKeyUp(for: .toggleTrail) { [weak self] in
            self?.toggle()
        }
    }

    /// The switch and the shortcut. When a rule decides the current app, this
    /// overrides it until the frontmost app changes; otherwise it flips the
    /// user's own setting.
    func toggle() {
        let settings = store.settings
        if state.toggle(settings: settings) {
            store.settings.isEnabled.toggle()
        } else {
            recompute(settings: settings)
        }
    }

    private func activated(_ app: NSRunningApplication?) {
        // Opening Contrail's own popover or Settings shouldn't change anything.
        guard let app, !Self.isSelf(app) else { return }
        state.activated(Self.describe(app))
        recompute(settings: store.settings)
    }

    private func recompute(settings: TrailSettings) {
        let next = state.decide(settings: settings)
        if next != decision {
            decision = next
        }
    }

    private static func isSelf(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    private static func describe(_ app: NSRunningApplication) -> FrontmostApp {
        let category = app.bundleURL
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
        return FrontmostApp(
            bundleID: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "this app",
            isGame: FrontmostApp.isGameCategory(category)
        )
    }
}

extension HoldModifier {
    /// The AppKit flag for this key, or nil for `.none`.
    var flag: NSEvent.ModifierFlags? {
        switch self {
        case .none: nil
        case .option: .option
        case .control: .control
        case .command: .command
        case .shift: .shift
        }
    }

    /// Whether `flags` satisfy this requirement.
    func isSatisfied(by flags: NSEvent.ModifierFlags) -> Bool {
        guard let flag else { return true }
        return flags.contains(flag)
    }
}
