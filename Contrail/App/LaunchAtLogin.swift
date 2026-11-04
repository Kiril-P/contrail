import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp`.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the user turned Contrail off in System Settings → Login Items,
    /// which the app can't override.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Returns an error message when the change could not be applied.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
