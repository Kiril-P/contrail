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
            MenuBarLabel(activation: appDelegate.activation)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var activation: ActivationController

    var body: some View {
        Image(nsImage: MenuBarIcon.image(enabled: activation.isOn))
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
        updates.start()
    }

    func showSettings() {
        settingsWindow.show()
    }
}
