import Foundation
import ServiceManagement

/// Manages whether Newt itself launches at login, via the modern
/// `SMAppService.mainApp` API. The privileged helper is registered separately
/// (see HelperClient); these are independent of each other.
final class LoginItemController {
    private var service: SMAppService { SMAppService.mainApp }

    private let bootstrappedKey = "LoginItemBootstrapped"

    var isEnabled: Bool { service.status == .enabled }

    /// On the very first launch, default Open at Login to on. Once we've done
    /// this we never auto-toggle again, so the user's later choice is honored.
    @discardableResult
    func bootstrapDefaultIfNeeded() -> String? {
        let d = UserDefaults.standard
        guard !d.bool(forKey: bootstrappedKey) else { return nil }
        d.set(true, forKey: bootstrappedKey)
        return setEnabled(true)
    }

    /// Toggle login-at-launch. Returns a user-facing message on failure.
    @discardableResult
    func setEnabled(_ on: Bool) -> String? {
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            return nil
        } catch {
            return "Open at login: \(error.localizedDescription)"
        }
    }
}
