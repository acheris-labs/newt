import Foundation

/// Accepts incoming XPC connections from the Newt app and wires each one to a
/// fresh `HelperService`.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // Only the genuine Newt app may talk to us. The requirement is derived
        // from our own signature: Apple-anchored + Team-pinned for signed
        // builds, with an identifier-only fallback under ad-hoc dev signing —
        // see `HelperConstants.peerRequirement`.
        conn.setCodeSigningRequirement(
            HelperConstants.peerRequirement(identifier: HelperConstants.appIdentifier))

        let service = HelperService()
        conn.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.exportedObject = service

        // Crash safety: if the app dies while sleep is disabled, restore it —
        // the daemon equivalent of lidawake's `trap cleanup`.
        conn.invalidationHandler = { service.connectionDropped() }
        conn.interruptionHandler = { service.connectionDropped() }

        conn.resume()
        return true
    }
}

final class HelperService: NSObject, HelperProtocol {
    private var sleepDisabled = false

    func setDisableSleep(_ enabled: Bool, reply: @escaping (Bool, String?) -> Void) {
        if let err = Self.runPmset(disable: enabled) {
            reply(false, err)
        } else {
            sleepDisabled = enabled
            reply(true, nil)
        }
    }

    func getVersion(reply: @escaping (String) -> Void) {
        reply(HelperConstants.version)
    }

    /// Invoked when the app's connection drops. Undo any lingering change.
    func connectionDropped() {
        guard sleepDisabled else { return }
        _ = Self.runPmset(disable: false)
        sleepDisabled = false
    }

    /// Runs `pmset -a disablesleep 0|1`. Returns nil on success, else a message.
    private static func runPmset(disable: Bool) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-a", "disablesleep", disable ? "1" : "0"]
        let errPipe = Pipe()
        proc.standardError = errPipe
        let errData: Data
        do {
            try proc.run()
            // Drain stderr to EOF *before* waiting. Reading concurrently with the
            // child means a child that fills the ~64 KB pipe buffer before exiting
            // can't deadlock this (root) daemon; EOF arrives when pmset exits.
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
        } catch {
            return "could not launch pmset: \(error.localizedDescription)"
        }
        guard proc.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "pmset exited \(proc.terminationStatus)\(msg.map { ": \($0)" } ?? "")"
        }
        return nil
    }
}
