import AppKit
import SwiftUI

@main
struct ContrailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: appDelegate.store)
        } label: {
            Image(systemName: "scribble.variable")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SettingsStore()
    private var controller: TrailController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SnapshotRenderer.runIfRequested()
        let controller = TrailController(store: store)
        controller.start()
        self.controller = controller
    }
}

private struct MenuContent: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Toggle("Show Trail", isOn: $store.settings.isEnabled)
            .keyboardShortcut("t")
        Divider()
        Button("Quit Contrail") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
