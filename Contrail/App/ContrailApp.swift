import AppKit
import SwiftUI

@main
struct ContrailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuPopover(
                store: appDelegate.store,
                activation: appDelegate.activation,
                updates: appDelegate.updates,
                openSettings: appDelegate.showSettings
            )
        } label: {
            MenuBarLabel(activation: appDelegate.activation, updates: appDelegate.updates)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var activation: ActivationController
    @ObservedObject var updates: UpdateController

    var body: some View {
        Image(nsImage: MenuBarIcon.image(enabled: activation.isOn, badge: updates.availableVersion != nil))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SettingsStore()
    private(set) lazy var activation = ActivationController(store: store)
    let updates = UpdateController()
    private var controller: TrailController?
    private lazy var settingsWindow = SettingsWindowController(store: store, updates: updates)

    func applicationDidFinishLaunching(_ notification: Notification) {
        SnapshotRenderer.runIfRequested(store: store)
        let controller = TrailController(store: store, activation: activation)
        controller.start()
        self.controller = controller
        // Render the Look thumbnails once the app is idle, not when the
        // popover first opens.
        let settings = store.settings
        DispatchQueue.main.async {
            LookThumbnails.shared.prewarm(size: settings.lookSize, highContrast: settings.highContrast)
        }
        #if !DEBUG
        // Development builds share the bundle ID and feed; don't let them
        // offer (or install) release builds over themselves.
        updates.start()
        #endif
    }

    func showSettings() {
        settingsWindow.show()
    }
}
