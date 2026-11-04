import AppKit
import Combine
import Sparkle

/// Sparkle 2 auto-updates. Updates are checked daily from the appcast on the
/// latest GitHub release and verified with Contrail's EdDSA key (the app
/// isn't notarized, so the signature on the archive is what proves an
/// update is genuine). Installing is always the user's choice.
///
/// Menu-bar apps have no Dock icon, so a scheduled update alert can easily
/// end up behind other windows. Contrail uses Sparkle's gentle reminders
/// instead: a background check shows a banner in the popover, and Sparkle
/// only puts its own window in front when the user asked or acts on it.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    /// Version string of an update found by a background check, if the user
    /// hasn't looked at it yet.
    @Published private(set) var availableVersion: String?
    @Published var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    private var controller: SPUStandardUpdaterController?

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
        if let controller {
            automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        }
    }

    var currentVersion: String { Bundle.main.versionString }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}

extension UpdateController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Let Sparkle show its window only when the app is already in front
    /// (for example, the user opened Settings); otherwise show the banner.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
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
