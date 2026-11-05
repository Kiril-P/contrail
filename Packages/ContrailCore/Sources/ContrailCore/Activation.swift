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
    /// The app looks like a game (see `looksLikeGame`).
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

    /// Whether an app looks like a game, from its Info.plist. Many games never
    /// set a games category, so this also counts apps that opt into Game Mode
    /// or game controllers. (Not where an app is installed: Steam also sells
    /// tools like Blender.)
    public static func looksLikeGame(info: [String: Any]) -> Bool {
        if isGameCategory(info["LSApplicationCategoryType"] as? String) { return true }
        if info["LSSupportsGameMode"] as? Bool == true { return true }
        if info["GCSupportsGameMode"] as? Bool == true { return true }   // older key
        if info["GCSupportsControllerUserInteraction"] as? Bool == true { return true }
        if info["GCSupportedGameControllers"] != nil { return true }
        return false
    }
}

/// The frontmost app and any temporary override, with the rules for when
/// the override ends.
public struct ActivationState: Sendable {
    public private(set) var frontmost: FrontmostApp?
    /// Set by the switch or shortcut while a rule applies.
    public private(set) var override: Bool?

    public init(frontmost: FrontmostApp? = nil) {
        self.frontmost = frontmost
    }

    /// Call when another app becomes frontmost (never for Contrail itself).
    /// The override only ends when the app actually changes: returning to
    /// the same app from Contrail's popover or Settings keeps it.
    public mutating func activated(_ app: FrontmostApp) {
        if app.identity != frontmost?.identity {
            override = nil
        }
        frontmost = app
    }

    /// The switch or shortcut. Returns true when the user's own on/off
    /// setting should flip (no rule applies); otherwise sets an override.
    public mutating func toggle(settings: TrailSettings) -> Bool {
        guard ActivationPolicy.rule(for: frontmost, settings: settings) != nil else { return true }
        override = !decide(settings: settings).isOn
        return false
    }

    public func decide(settings: TrailSettings) -> ActivationPolicy.Decision {
        ActivationPolicy.decide(settings: settings, frontmost: frontmost, override: override)
    }
}

extension FrontmostApp {
    /// What counts as "the same app" for ending an override.
    var identity: String { bundleID ?? name }
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
        /// On because the user explicitly asked for it here (an "Always on"
        /// rule, or the switch or shortcut overriding a rule). Automatic
        /// turning off, such as for a captured mouse, doesn't apply.
        public var isForcedOn = false

        public init(isOn: Bool, reason: String?, isForcedOn: Bool = false) {
            self.isOn = isOn
            self.reason = reason
            self.isForcedOn = isForcedOn
        }
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
            return Decision(isOn: override, reason: override == rule.isOn ? rule.reason : "Overridden until you switch apps",
                            isForcedOn: override)
        }
        if let rule {
            return Decision(isOn: rule.isOn, reason: rule.reason, isForcedOn: rule.isOn)
        }
        return Decision(isOn: settings.isEnabled, reason: nil)
    }
}
