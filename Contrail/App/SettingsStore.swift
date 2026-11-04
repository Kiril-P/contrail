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

    func resetToDefaults() {
        let enabled = settings.isEnabled
        var fresh = TrailSettings.default
        fresh.isEnabled = enabled
        settings = fresh
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
