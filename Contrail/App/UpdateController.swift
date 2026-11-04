import AppKit
import Combine
import Sparkle

/// Sparkle 2 auto-updates. Updates are checked daily from the appcast on the
/// latest GitHub release and verified with Contrail's EdDSA key (the app
/// isn't notarized, so the signature on the archive is what proves an
/// update is genuine). Installing is always the user's choice.
///
/// Menu-bar apps have no Dock icon, so a scheduled update alert can easily
/// end up behind other windows, or jump in front of everything at login.
/// Contrail uses Sparkle's gentle reminders instead: a background check only
/// shows a banner in the popover and a dot on the menu-bar icon, and Sparkle
/// opens its own window when the user checks or clicks Install.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    /// Version string of an update found by a background check, if the user
    /// hasn't looked at it yet.
    @Published private(set) var availableVersion: String?
    @Published var automaticallyChecks: Bool {
        didSet {
            // Only write real changes: writing resets Sparkle's check cycle.
            guard automaticallyChecks != oldValue else { return }
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    private var controller: SPUStandardUpdaterController?
    /// False in development builds, which never start the updater.
    @Published private(set) var isRunning = false

    override init() {
        automaticallyChecks = true
        super.init()
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }

    /// Starts scheduled checks. Called once the app has finished launching
    /// (and isn't just rendering a snapshot).
    func start() {
        controller?.startUpdater()
        isRunning = true
    }

    var currentVersion: String { Bundle.main.versionString }

    func checkForUpdates() {
        guard isRunning else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled checks never show Sparkle's window on their own (for an
    /// accessory app, "immediate focus" means right after launch, which would
    /// put the update window in front of everything at login). The banner
    /// and badge do the reminding.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            // A check the user started already shows Sparkle's window.
            if !handleShowingUpdate || !userInitiated {
                self.availableVersion = version
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { self.availableVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { self.availableVersion = nil }
    }
}
