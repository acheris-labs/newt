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

    func applicationWillTerminate(_ notification: Notification) {
        // Always restore normal sleep behavior on quit.
        statusController?.shutdown()
    }
}
