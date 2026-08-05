import Foundation
import UserNotifications

/// Thin wrapper over `UserNotifications`, isolating the framework the way
/// `BatteryMonitor` isolates IOKit. Posts a local notification when a timed
/// keep-awake session's clock runs out.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        // A menu-bar (LSUIElement) app is never frontmost; set the delegate so
        // `willPresent` can still surface a banner.
        center.delegate = self
    }

    /// Ask for alert+sound permission — called when the user turns on an option
    /// that posts notifications. `completion(granted, message)` runs on the main
    /// queue; `message` is non-nil only on error.
    func requestAuthorization(_ completion: @escaping (Bool, String?) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                completion(granted, error?.localizedDescription)
            }
        }
    }

    /// Post a "keep-awake ended" notification if authorized; a no-op otherwise
    /// (so a revoked permission fails silently rather than erroring).
    func postTimerEnded() {
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Newt"
            content.body = "Keep-awake ended — the timer ran out."
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            self?.center.add(request)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present the banner even though a menu-bar agent is never "frontmost".
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
