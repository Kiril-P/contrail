import Foundation

/// A modifier key that must be held for the trail to draw.
public enum HoldModifier: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, option, control, command, shift

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .none: "Always show"
        case .option: "⌥ Option"
        case .control: "⌃ Control"
        case .command: "⌘ Command"
        case .shift: "⇧ Shift"
        }
    }
}

/// What a per-app rule does while that app is frontmost.
public enum AppRuleMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case always, never

    public var id: String { rawValue }
    public var name: String { self == .always ? "Always on" : "Always off" }
}

/// Turns the trail on or off while a specific app is frontmost.
public struct AppRule: Codable, Equatable, Identifiable, Sendable {
    public var bundleID: String
    /// Display name, kept so the rule still reads well if the app is removed.
    public var name: String
    public var mode: AppRuleMode

    public var id: String { bundleID }

    public init(bundleID: String, name: String, mode: AppRuleMode) {
        self.bundleID = bundleID
        self.name = name
        self.mode = mode
    }
}

/// The frontmost app, as far as activation rules care.
public struct FrontmostApp: Equatable, Sendable {
    public var bundleID: String?
    public var name: String
    /// The app declares itself a game (`LSApplicationCategoryType`).
    public var isGame: Bool

    public init(bundleID: String?, name: String, isGame: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.isGame = isGame
    }

    /// True for any `public.app-category.*games` category.
    public static func isGameCategory(_ category: String?) -> Bool {
        guard let category else { return false }
        return category.hasPrefix("public.app-category.") && category.hasSuffix("games")
    }
}

/// Decides whether the trail is on.
///
/// Precedence, highest first:
/// 1. A temporary override from the switch or shortcut, which only exists
///    while a rule applies and clears when the frontmost app changes.
/// 2. A rule for the frontmost app: a per-app rule, else "off in games".
/// 3. The user's own on/off setting.
///
/// In one sentence: "Your toggle wins until you switch apps."
public enum ActivationPolicy {
    public struct Decision: Equatable, Sendable {
        public var isOn: Bool
        /// Short explanation when a rule or override decided, e.g. "On in Keynote".
        public var reason: String?
    }

    /// The rule that applies to `app`, if any.
    public static func rule(for app: FrontmostApp?, settings: TrailSettings) -> (isOn: Bool, reason: String)? {
        guard let app else { return nil }
        if let id = app.bundleID, let rule = settings.appRules.first(where: { $0.bundleID == id }) {
            return rule.mode == .always ? (true, "On in \(app.name)") : (false, "Off in \(app.name)")
        }
        if settings.offInGames && app.isGame {
            return (false, "Off in games")
        }
        return nil
    }

    public static func decide(settings: TrailSettings, frontmost: FrontmostApp?, override: Bool?) -> Decision {
        let rule = rule(for: frontmost, settings: settings)
        if let override, let rule {
            return Decision(isOn: override, reason: override == rule.isOn ? rule.reason : "Overridden until you switch apps")
        }
        if let rule {
            return Decision(isOn: rule.isOn, reason: rule.reason)
        }
        return Decision(isOn: settings.isEnabled, reason: nil)
    }
}
