import AppKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    // Sparkle reads SUFeedURL / SUPublicEDKey / SUScheduledCheckInterval
    // from Info.plist; this controller starts scheduled checks per
    // SUEnableAutomaticChecks (user-toggleable from the status menu).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // An upgraded Newt may ship a newer plugin than the one already sitting
        // in an agent's config directory; that file is otherwise only written
        // when the user toggles the checkbox.
        IntegrationInstaller.refreshInstalledPlugins()
        statusController = StatusItemController(updater: updaterController)
        // URLs that arrived before the controller existed (cold-start launch
        // via a newt:// link) are replayed now.
        pendingURLs.forEach { statusController?.handleURL($0) }
        pendingURLs.removeAll()
    }

    /// newt:// URLs can be delivered before `applicationDidFinishLaunching`
    /// when the app is cold-started by a link — buffer until the controller
    /// exists.
    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        // Schemes are case-insensitive but `URL` preserves the case as typed,
        // so `NEWT://off` would otherwise be dropped here without a trace.
        let newtURLs = urls.filter { $0.scheme?.lowercased() == "newt" }
        guard let controller = statusController else {
            pendingURLs += newtURLs
            return
        }
        newtURLs.forEach(controller.handleURL)
    }

    /// A menu bar app owns no windows, so macOS does nothing by default when the
    /// user re-opens an already-running copy (Spotlight, Dock, double-clicking in
    /// /Applications). That is exactly what people try when the icon has gone
    /// missing, so make it the recovery path rather than a no-op.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        statusController?.revealStatusItem()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Always restore normal sleep behavior on quit.
        statusController?.shutdown()
    }
}
