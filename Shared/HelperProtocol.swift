// Shared between the Newt app and the privileged NewtHelper daemon.
// Compiled into both targets.

import Foundation

/// XPC interface the privileged helper exposes to the app.
@objc protocol HelperProtocol {
    /// Run `pmset -a disablesleep 0|1` as root. `reply` reports success and,
    /// on failure, a human-readable message.
    func setDisableSleep(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void)

    /// Helper build version — lets the app detect a stale installed helper.
    func getVersion(reply: @escaping (String) -> Void)
}

enum HelperConstants {
    /// Mach service name — must match the launchd plist's MachServices key.
    static let machServiceName = "net.acheris.newt.helper"

    /// Bundle identifiers, used for the XPC code-signing requirements.
    static let appIdentifier = "net.acheris.newt"
    static let helperIdentifier = "net.acheris.newt.helper"

    /// Bump when the helper's behavior changes.
    static let version = "1.0"
}
