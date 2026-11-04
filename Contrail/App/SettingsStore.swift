import Combine
import ContrailCore
import Foundation

/// The single source of truth for user settings, persisted to UserDefaults as
/// versioned JSON.
@MainActor
final class SettingsStore: ObservableObject {
    private static let key = "TrailSettings.v1"

    @Published var settings: TrailSettings {
        didSet {
            let clamped = settings.clamped()
            if clamped != settings {
                // Assigning inside didSet doesn't re-run didSet, so save here.
                settings = clamped
            }
            if oldValue != settings { save() }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(TrailSettings.self, from: data) {
            settings = decoded.clamped()
        } else {
            settings = .default
        }
    }

    var preset: ColorPreset { settings.preset }

    /// Resets how the trail looks and moves. On/off and activation rules
    /// (shortcut, hold key, per-app rules) are kept.
    func resetAppearance() {
        var fresh = TrailSettings.default
        Look.look(id: Look.defaultID)?.apply(to: &fresh, size: .medium)
        fresh.isEnabled = settings.isEnabled
        fresh.holdModifier = settings.holdModifier
        fresh.appRules = settings.appRules
        fresh.offInGames = settings.offInGames
        settings = fresh
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
