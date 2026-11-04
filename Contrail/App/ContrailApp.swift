import AppKit
import SwiftUI

@main
struct ContrailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuPopover(store: appDelegate.store, openSettings: appDelegate.showSettings)
        } label: {
            MenuBarLabel(store: appDelegate.store)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Image(nsImage: MenuBarIcon.image(enabled: store.settings.isEnabled))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SettingsStore()
    private var controller: TrailController?
    private lazy var settingsWindow = SettingsWindowController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        SnapshotRenderer.runIfRequested(store: store)
        let controller = TrailController(store: store)
        controller.start()
        self.controller = controller
    }

    func showSettings() {
        settingsWindow.show()
    }
}
