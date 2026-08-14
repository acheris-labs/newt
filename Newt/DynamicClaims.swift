import Foundation

/// A keep-awake claim raised from outside Newt over `newt://claim` — an AI
/// coding agent while it works, or anything else that wants to hold the Mac
/// awake for a while.
///
/// Held only for the duration of a turn: the agent's hooks claim when a prompt
/// is submitted and release when the turn ends. `pid` is the agent process, so
/// the claim can be dropped automatically if it dies without releasing.
struct DynamicClaim {
    let id: String          // the agent's session id
    let agent: String       // "claude" — others later
    let pid: pid_t?         // nil when the CLI couldn't identify the owner
    let tty: String?
    let label: String       // project directory name
    let since: Date

    /// "claude — newt (ttys002) · 2m". The age is the tell for a claim that has
    /// outstayed its welcome, so it's on the row rather than buried in the
    /// tooltip. An unresolved owner is called out because such a claim has no
    /// automatic release behind it.
    var menuTitle: String {
        let where_ = tty ?? (pid == nil ? "owner unknown" : "no tty")
        return "\(agent) — \(label) (\(where_)) · \(Self.elapsed(since))"
    }

    var detail: String {
        var parts = ["session \(id)"]
        if let pid { parts.append("pid \(pid)") }
        parts.append("held \(Self.elapsed(since))")
        return parts.joined(separator: ", ")
    }

    /// Everything known about the claim, for the detail dialog. Labelled lines
    /// rather than prose — the point is to identify *which* claim this is.
    var detailLines: [(String, String)] {
        [
            ("Agent", agent),
            ("Project", label),
            ("Terminal", tty ?? "none"),
            ("Process", pid.map { "pid \($0)" } ?? "not identified"),
            ("Started", "\(SleepManager.clockString(since)) (held \(Self.elapsed(since)))"),
            ("Session", id),
        ]
    }

    /// True when nothing will release this claim on its own — worth saying out
    /// loud in the dialog, since that's the case the Revoke button exists for.
    var hasNoAutomaticRelease: Bool { pid == nil }

    static func elapsed(_ from: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(from))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

/// Tracks the dynamic claims currently in force.
///
/// An agent releases its own claim at the end of a turn, but that can't be the
/// only path — a killed agent never runs its release hook. Each claim with a
/// resolved pid therefore also gets a process-exit watcher, so the claim goes
/// away the moment its owner does. Anything neither path catches is evictable
/// from the menu.
final class DynamicClaimRegistry {
    private(set) var claims: [String: DynamicClaim] = [:]
    private var watchers: [String: DispatchSourceProcess] = [:]

    /// Fired on the main queue whenever the set of claims changes.
    var onChange: (() -> Void)?

    var isEmpty: Bool { claims.isEmpty }

    /// Oldest first, so the list doesn't reshuffle under the pointer as turns
    /// come and go.
    var sortedClaims: [DynamicClaim] { claims.values.sorted { $0.since < $1.since } }

    /// Raise a claim, or refresh one already held under the same id — which is
    /// the normal case, once per turn. A refresh keeps the original start time
    /// so the menu shows how long the agent has really been working.
    func add(_ claim: DynamicClaim) {
        if let pid = claim.pid, !Self.isAlive(pid) { return }

        var stored = claim
        if let existing = claims[claim.id] {
            stored = DynamicClaim(id: claim.id, agent: claim.agent, pid: claim.pid,
                                tty: claim.tty, label: claim.label, since: existing.since)
            if existing.pid == claim.pid {
                claims[claim.id] = stored
                onChange?()
                return
            }
        }
        claims[claim.id] = stored
        watch(stored)
        onChange?()
    }

    @discardableResult
    func remove(id: String) -> Bool {
        guard claims.removeValue(forKey: id) != nil else { return false }
        watchers.removeValue(forKey: id)?.cancel()
        onChange?()
        return true
    }

    func removeAll() {
        guard !claims.isEmpty else { return }
        claims.removeAll()
        watchers.values.forEach { $0.cancel() }
        watchers.removeAll()
        onChange?()
    }

    private func watch(_ claim: DynamicClaim) {
        watchers.removeValue(forKey: claim.id)?.cancel()
        guard let pid = claim.pid else { return }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                      queue: .main)
        source.setEventHandler { [weak self] in self?.remove(id: claim.id) }
        source.resume()
        watchers[claim.id] = source
        // The process could have exited between the liveness check and the
        // source being armed, in which case the exit event is already lost.
        if !Self.isAlive(pid) { remove(id: claim.id) }
    }

    /// Signal 0 probes for existence without delivering anything. `EPERM` means
    /// the process exists but belongs to someone else.
    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
