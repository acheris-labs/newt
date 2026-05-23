import Foundation
import ServiceManagement

/// Registers the privileged helper via `SMAppService` and talks to it over XPC.
final class HelperClient {
    private let plistName = "net.acheris.newt.helper.plist"
    private var connection: NSXPCConnection?

    private var service: SMAppService {
        SMAppService.daemon(plistName: plistName)
    }

    /// Register the helper at launch (no menu click needed) and log the
    /// outcome for diagnostics.
    func prepare(completion: @escaping (String?) -> Void) {
        let message = ensureRegistered()
        completion(message)
    }

    /// Ensure the helper daemon is registered and enabled. Returns nil when
    /// ready, or a user-facing message describing what the user must do.
    @discardableResult
    private func ensureRegistered() -> String? {
        NSLog("Newt: helper status=\(service.status.rawValue) bundle=\(Bundle.main.bundlePath)")
        switch service.status {
        case .enabled:
            return nil
        case .notRegistered:
            do {
                try service.register()
                NSLog("Newt: register() ok, status now \(service.status.rawValue)")
                if service.status == .enabled { return nil }
                SMAppService.openSystemSettingsLoginItems()
                return "Enable Newt under System Settings ▸ Login Items."
            } catch {
                NSLog("Newt: register() failed: \(error)")
                return "Could not register the helper: \(error.localizedDescription)"
            }
        case .requiresApproval:
            SMAppService.openSystemSettingsLoginItems()
            return "Approve Newt under System Settings ▸ Login Items."
        case .notFound:
            return "Helper not found — make sure Newt.app is in /Applications."
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
        let proxy = conn.remoteObjectProxyWithErrorHandler { error in
            DispatchQueue.main.async {
                reply(false, "Helper connection error: \(error.localizedDescription)")
            }
        } as? HelperProtocol

        guard let proxy else {
            reply(false, "Could not reach the helper.")
            return
        }
        proxy.setDisableSleep(enabled) { ok, err in
            DispatchQueue.main.async { reply(ok, err) }
        }
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
