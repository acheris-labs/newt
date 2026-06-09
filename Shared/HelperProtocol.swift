// Shared between the Newt app and the privileged NewtHelper daemon.
// Compiled into both targets.

import Foundation
import Security

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

    /// The strongest XPC peer requirement this build can prove, derived from
    /// *our own* signature so it auto-adapts to how we were signed:
    ///
    /// - Developer ID / Apple Development (anything CI ships): pin Apple's
    ///   anchor + the bundle identifier + our Team ID, so only the genuine,
    ///   team-signed peer is accepted.
    /// - Ad-hoc (local dev): no Team ID is present, so fall back to an
    ///   identifier-only match — exactly the prior behavior, which keeps local
    ///   builds connecting. Any failure path also falls back, so the worst case
    ///   is "no stricter than before," never a rejected legitimate peer.
    ///
    /// Both binaries are signed together with one identity, so each side derives
    /// the same Team ID and demands it of the other.
    static func peerRequirement(identifier: String) -> String {
        var dyn: SecCode?
        var stat: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &dyn) == errSecSuccess, let dyn,
              SecCodeCopyStaticCode(dyn, [], &stat) == errSecSuccess, let stat,
              SecCodeCopySigningInformation(
                stat, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty
        else { return "identifier \"\(identifier)\"" }
        return "anchor apple generic and identifier \"\(identifier)\" "
            + "and certificate leaf[subject.OU] = \"\(team)\""
    }
}
