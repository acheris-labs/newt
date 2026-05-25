import Foundation
import ServiceManagement

/// Registers the privileged helper via `SMAppService` and talks to it over XPC.
final class HelperClient {
    private let plistName = "net.acheris.newt.helper.plist"
    private var connection: NSXPCConnection?

    private var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    /// Register the helper at launch (no menu click needed), then verify the
    /// running helper is the version we shipped with. Sparkle (or a manual
    /// reinstall) can replace the app bundle out from under a still-running
    /// helper daemon — `launchd` keeps the old process alive, but its backing
    /// file has been swapped, so XPC code-signature validation against it
    /// later fails with `NSXPCConnectionInvalid`. The version handshake
    /// detects this and bounces the helper before the user sees an error.
    func prepare(completion: @escaping (String?) -> Void) {
        if let message = ensureRegistered() {
            completion(message)
            return
        }
        verifyHelperVersion(completion: completion)
    }

    /// XPC-ping the helper for its version. On mismatch or any XPC error,
    /// bounce the daemon via `SMAppService` unregister+register so `launchd`
    /// respawns it from the current on-disk binary.
    private func verifyHelperVersion(completion: @escaping (String?) -> Void) {
        let conn = currentConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
            NSLog("Newt: getVersion XPC failed (\((error as NSError).domain) \((error as NSError).code)) — bouncing helper")
            self?.bounceHelper(reason: "xpc-error", completion: completion)
        } as? HelperProtocol

        guard let proxy else {
            NSLog("Newt: getVersion proxy was nil — bouncing helper")
            bounceHelper(reason: "nil-proxy", completion: completion)
            return
        }
        proxy.getVersion { [weak self] runningVersion in
            if runningVersion == HelperConstants.version {
                NSLog("Newt: helper version ok (\(runningVersion))")
                DispatchQueue.main.async { completion(nil) }
            } else {
                NSLog("Newt: helper version mismatch — running=\(runningVersion) bundled=\(HelperConstants.version) — bouncing")
                self?.bounceHelper(reason: "version-mismatch", completion: completion)
            }
        }
    }

    /// Drop the cached XPC connection and force `SMAppService` to re-submit
    /// the helper. `unregister()` is synchronous and only returns once
    /// `launchd` has torn down the running daemon; `register()` then
    /// re-submits the disposition pointing at the (now-current) bundle path.
    /// The next caller of `setDisableSleep` will lazily reconnect.
    private func bounceHelper(reason: String, completion: @escaping (String?) -> Void) {
        connection?.invalidate()
        connection = nil
        do {
            try service.unregister()
            try service.register()
            NSLog("Newt: bounced helper (\(reason)) — status now \(service.status.rawValue)")
            DispatchQueue.main.async { completion(nil) }
        } catch {
            NSLog("Newt: bounce failed (\(reason)): \(error)")
            DispatchQueue.main.async {
                completion("Could not refresh the helper: \(error.localizedDescription)")
            }
        }
    }

    /// Ensure the helper daemon is registered and enabled. Returns nil when
    /// ready, or a user-facing message describing what the user must do.
    @discardableResult
    private func ensureRegistered() -> String? {
        NSLog("Newt: helper status=\(service.status.rawValue) bundle=\(Bundle.main.bundlePath)")
        switch service.status {
        case .enabled:
            return nil
        case .notRegistered, .notFound:
            // .notFound also covers the fresh-install case where BTM has no
            // record yet — smd returns ESRCH for the disposition lookup and
            // surfaces it as .notFound. register() is what populates BTM, so
            // both states must take the registration path.
            do {
                try service.register()
                NSLog("Newt: register() ok, status now \(service.status.rawValue)")
                if service.status == .enabled { return nil }
                SMAppService.openSystemSettingsLoginItems()
                return "Enable Newt in Login Items, then quit and reopen Newt."
            } catch {
                NSLog("Newt: register() failed: \(error)")
                return "Could not register the helper: \(error.localizedDescription)"
            }
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            return "Approve Newt in Login Items, then quit and reopen Newt."
        @unknown default:
            return "Unexpected helper status."
        }
    }

    /// Toggle `pmset disablesleep` via the helper. `reply` runs on the main
    /// queue. If the helper is not yet approved, idle-sleep assertions still
    /// apply but `reply` reports the message so the menu can show it.
    func setDisableSleep(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        if let message = ensureRegistered() {
            reply(false, message)
            return
        }
        let conn = currentConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
            let message = self?.xpcErrorMessage(error) ?? "Helper connection error."
            DispatchQueue.main.async {
                reply(false, message)
            }
        } as? HelperProtocol

        guard let proxy else {
            NSLog("Newt: XPC proxy was nil (interface mismatch?) status=\(service.status.rawValue)")
            reply(false, "Could not reach the helper.")
            return
        }
        proxy.setDisableSleep(enabled) { ok, err in
            DispatchQueue.main.async { reply(ok, err) }
        }
    }

    /// Build the menu message for an XPC error and log full detail (domain,
    /// code, current `SMAppService` status) to Console for diagnosis.
    private func xpcErrorMessage(_ error: Error) -> String {
        let ns = error as NSError
        let statusAtFailure = service.status
        NSLog("Newt: XPC error domain=\(ns.domain) code=\(ns.code) status=\(statusAtFailure.rawValue) desc=\(ns.localizedDescription)")

        let suffix: String
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case 4097: suffix = "helper not running — relaunch Newt"
            case 4099: suffix = "helper crashed — try again"
            case 4101: suffix = "helper replied with invalid data"
            default:   suffix = "\(ns.localizedDescription) (code \(ns.code))"
            }
        } else {
            suffix = "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
        }

        if statusAtFailure != .enabled {
            return "Helper connection error: \(suffix) [status \(statusAtFailure.rawValue)]"
        }
        return "Helper connection error: \(suffix)"
    }

    private func currentConnection() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        // Only accept the genuine helper. Identifier match works under ad-hoc
        // signing, where anchor/team-based requirements would not.
        c.setCodeSigningRequirement("identifier \"\(HelperConstants.helperIdentifier)\"")
        c.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
        }
        c.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }
}
