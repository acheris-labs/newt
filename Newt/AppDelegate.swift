import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Always restore normal sleep behavior on quit.
        statusController?.shutdown()
    }
}
