import AppKit
import SwiftUI

/// Makes the app a menu-bar-only app (no Dock icon, no app menu) even when it is started as a bare program from Terminal instead of from the app bundle, where Info.plist already says so.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Sets the activation policy before the app finishes launching, so a Dock icon never flashes up.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

/// The SiteBlock menu bar app: one shield icon that opens a panel for adding, viewing and unblocking sites. Quitting it never stops the blocking, because the blocking is done by the separate background service.
@main
struct SiteBlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The one model shared by the icon and the panel; it polls the daemon for as long as the app runs.
    @StateObject private var model = StatusModel()

    var body: some Scene {
        // The window style gives a real panel that can hold text fields, instead of a plain menu.
        MenuBarExtra {
            MainPanel(model: model)
        } label: {
            // A half-filled shield normally, and a slashed shield when the service cannot be reached.
            Image(systemName: model.menuIconName)
                .accessibilityLabel("SiteBlock")
        }
        .menuBarExtraStyle(.window)
    }
}
