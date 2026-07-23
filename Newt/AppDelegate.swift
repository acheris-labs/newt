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
        statusController = StatusItemController(updater: updaterController)
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
