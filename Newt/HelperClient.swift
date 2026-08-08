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
    /// helper daemon; the version handshake spots that and asks the old
    /// process to quit so `launchd` respawns it from the new bundle.
    func prepare(completion: @escaping (String?) -> Void) {
        if let message = ensureRegistered() {
            completion(message)
            return
        }
        verifyHelperVersion(completion: completion)
    }

    /// XPC-ping the helper for its version. A mismatch means a stale process
    /// survived an update; an XPC error means the daemon isn't reachable at
    /// all, which `repairRegistration()` re-submits for.
    ///
    /// Never calls `SMAppService.unregister()`. Re-registering straight after
    /// an unregister fails with EPERM even though Background Task Management
    /// still shows the record enabled, and the failed attempt leaves it
    /// *disabled* — which only the user can undo, in Login Items. So one
    /// unregister+register bricks the lid-close path permanently.
    private func verifyHelperVersion(completion: @escaping (String?) -> Void) {
        let conn = currentConnection()
        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] error in
            let ns = error as NSError
            NSLog("Newt: getVersion XPC failed (\(ns.domain) \(ns.code)) — re-registering")
            self?.repairRegistration(reason: "xpc-error", completion: completion)
        } as? HelperProtocol

        guard let proxy else {
            NSLog("Newt: getVersion proxy was nil — re-registering")
            repairRegistration(reason: "nil-proxy", completion: completion)
            return
        }
        proxy.getVersion { [weak self] runningVersion in
            if runningVersion == HelperConstants.version {
                NSLog("Newt: helper version ok (\(runningVersion))")
                DispatchQueue.main.async { completion(nil) }
            } else {
                NSLog("Newt: helper stale — running=\(runningVersion) bundled=\(HelperConstants.version)")
                DispatchQueue.main.async { completion(Self.staleHelperMessage) }
            }
        }
    }

    /// Only a helper predating exit-when-idle can still be running from a
    /// replaced bundle. Nothing but `launchd` retires a root process, and the
    /// app can't ask this one to quit, so say what will actually fix it.
    static let staleHelperMessage =
        "Newt's helper is out of date — restart your Mac to finish updating."

    /// Re-submit the helper's launchd disposition without unregistering it.
    /// `register()` is idempotent, so this is safe to run on every launch.
    private func repairRegistration(reason: String, completion: @escaping (String?) -> Void) {
        connection?.invalidate()
        connection = nil
        do {
            try service.register()
            NSLog("Newt: re-registered helper (\(reason)) — status now \(service.status.rawValue)")
            DispatchQueue.main.async { completion(nil) }
        } catch {
            NSLog("Newt: re-register failed (\(reason)): \(error)")
            let message = registrationFailureMessage(error)
            DispatchQueue.main.async { completion(message) }
        }
    }

    /// Turn a `register()` failure into something the user can act on. EPERM
    /// means the helper's Background Task Management record is switched off —
    /// no API re-enables it, so send the user to Login Items.
    private func registrationFailureMessage(_ error: Error) -> String {
        let ns = error as NSError
        NSLog("Newt: register error domain=\(ns.domain) code=\(ns.code) status=\(service.status.rawValue)")
        guard ns.code == Int(EPERM) else {
            return "Could not register the helper: \(ns.localizedDescription)"
        }
        SMAppService.openSystemSettingsLoginItems()
        return "Turn Newt on under Allow in the Background, then reopen Newt."
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
                return registrationFailureMessage(error)
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

        // NSXPCConnectionCodeSigningRequirementFailure: a helper still running
        // from a bundle that was replaced underneath it can no longer be
        // signature-validated, so we can't even reach it to ask it to quit.
        if ns.code == 4102 { return Self.staleHelperMessage }

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
        // Only accept the genuine helper. The requirement is derived from our
        // own signature: Apple-anchored + Team-pinned for signed builds, and an
        // identifier-only fallback under ad-hoc dev signing — see
        // `HelperConstants.peerRequirement`.
        c.setCodeSigningRequirement(
            HelperConstants.peerRequirement(identifier: HelperConstants.helperIdentifier))
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
