import Foundation

/// Installs and removes Newt's hooks in an AI agent's settings file.
///
/// The settings file belongs to the user and usually to other tools as well, so
/// every operation is a merge: parse, change only our own entries, write the
/// rest back untouched. Our entries are recognised by the `newt://` URL inside
/// them, which is what makes both re-installing and uninstalling safe.
enum HookInstaller {
    /// Substring that marks a hook entry as ours. Every command we write drives
    /// the URL scheme, so nothing else plausibly contains it.
    static let marker = "newt://claim?"

    struct Agent {
        /// Stable key, used as the menu item's `representedObject` and as the
        /// `agent=` value on the claim URL.
        let id: String
        /// How the agent is named to the user.
        let name: String
        let settings: URL
        let hooks: [HookSpec]
        /// False for tools Newt doesn't support yet. They're listed so it's
        /// clear what's coming, but can't be switched on.
        var isAvailable = true
    }

    struct HookSpec {
        let event: String
        let command: String
    }

    // MARK: - The hook commands

    /// Pulls `session_id` out of the JSON on stdin with `sed` alone — no jq, no
    /// python — so the hook has no dependency beyond a shell.
    private static let readSessionID =
        #"i=$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"#

    /// `$PPID` is the agent process itself: a `command` hook runs as its direct
    /// child. That gives Newt a pid to watch, so a killed agent's claim is
    /// released even though no hook ran, plus the tty to label it with.
    ///
    /// `open -g` keeps Newt in the background — without it every prompt would
    /// pull focus. The label is percent-encoded because project directories can
    /// contain spaces and the like.
    private static func claimCommand(agent id: String) -> String {
        """
        \(readSessionID); [ -z "$i" ] || open -g \
        "newt://claim?acquire=true&id=$i&agent=\(id)&pid=$PPID\
        &tty=$(ps -o tty= -p $PPID | tr -d ' ')\
        &label=$(basename "$PWD" | sed 's/%/%25/g;s/ /%20/g;s/&/%26/g;s/#/%23/g')"
        """
    }

    private static let releaseCommand = """
        \(readSessionID); [ -z "$i" ] || open -g "newt://claim?acquire=false&id=$i"
        """

    static var claude: Agent {
        Agent(
            id: "claude",
            name: "Claude Code",
            settings: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/settings.json"),
            hooks: [
                HookSpec(event: "UserPromptSubmit", command: claimCommand(agent: "claude")),
                HookSpec(event: "Stop", command: releaseCommand),
                // Belt and braces. The docs are explicit that SessionEnd does
                // not fire on crash or kill, so it can't be the only release.
                HookSpec(event: "SessionEnd", command: releaseCommand),
            ])
    }

    /// Every agent Newt can integrate with. Adding one means adding an entry
    /// here — the menu builds itself from this list.
    ///
    /// A new agent needs its own settings path and hook event names, but can
    /// reuse `claimCommand`/`releaseCommand` as long as it passes a JSON payload
    /// with a `session_id` on stdin and runs the hook as its own child process.
    /// Not wired up yet: the settings path and hook event names still need
    /// confirming against opencode itself, so it's listed but not actionable.
    static var opencode: Agent {
        Agent(
            id: "opencode",
            name: "opencode",
            settings: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/opencode/config.json"),
            hooks: [],
            isAvailable: false)
    }

    static var all: [Agent] { [claude, opencode] }

    static func agent(id: String) -> Agent? { all.first { $0.id == id } }

    enum Outcome {
        case installed(backup: URL)
        case alreadyInstalled
        case removed(backup: URL)
        case notInstalled
    }

    /// True when any of our hooks are already present.
    static func isInstalled(_ agent: Agent) -> Bool {
        guard agent.isAvailable,
              let root = try? load(agent.settings),
              let hooksByEvent = root["hooks"] as? [String: Any] else { return false }
        return hooksByEvent.values.contains { value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.contains { group in
                entries(in: group).contains { isOurs($0) }
            }
        }
    }

    // MARK: - Install

    @discardableResult
    static func install(_ agent: Agent) throws -> Outcome {
        var root = try load(agent.settings)
        var hooksByEvent = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for spec in agent.hooks {
            var groups = hooksByEvent[spec.event] as? [[String: Any]] ?? []
            if groups.contains(where: { group in
                entries(in: group).contains { $0["command"] as? String == spec.command }
            }) { continue }
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": spec.command,
                    // Off the critical path, so a turn gains no latency.
                    "async": true,
                    "timeout": 5,
                ]]
            ])
            hooksByEvent[spec.event] = groups
            changed = true
        }

        guard changed else { return .alreadyInstalled }
        root["hooks"] = hooksByEvent
        return .installed(backup: try write(root, to: agent.settings))
    }

    // MARK: - Uninstall

    @discardableResult
    static func uninstall(_ agent: Agent) throws -> Outcome {
        var root = try load(agent.settings)
        guard var hooksByEvent = root["hooks"] as? [String: Any] else { return .notInstalled }
        var changed = false

        for (event, value) in hooksByEvent {
            guard let groups = value as? [[String: Any]] else { continue }
            var rebuilt: [[String: Any]] = []
            for var group in groups {
                let existing = entries(in: group)
                let kept = existing.filter { !isOurs($0) }
                if kept.count != existing.count { changed = true }
                // Drop a group only if we emptied it. Pre-existing empty groups
                // are someone else's and stay exactly as they were.
                if kept.isEmpty && !existing.isEmpty { continue }
                group["hooks"] = kept
                rebuilt.append(group)
            }
            hooksByEvent[event] = rebuilt
        }

        guard changed else { return .notInstalled }
        root["hooks"] = hooksByEvent
        return .removed(backup: try write(root, to: agent.settings))
    }

    // MARK: - File handling

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(marker) ?? false
    }

    private static func entries(in group: [String: Any]) -> [[String: Any]] {
        group["hooks"] as? [[String: Any]] ?? []
    }

    private static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallerError("\(url.path) is not a JSON object — refusing to touch it")
        }
        return root
    }

    /// Writes via a backup-then-replace so a failure can't leave a half-written
    /// settings file. Returns the backup path so the caller can name it.
    private static func write(_ root: [String: Any], to url: URL) throws -> URL {
        let fm = FileManager.default
        let backup = uniqueBackupURL(for: url)
        if fm.fileExists(atPath: url.path) {
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return backup
    }

    /// The timestamp only resolves to the second, so an install immediately
    /// followed by an uninstall would collide — and those two backups hold
    /// different states, so neither may be dropped.
    private static func uniqueBackupURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent).backup-\(timestamp())"
        var candidate = dir.appendingPathComponent(base)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    /// Matches the `settings.json.backup-<compact ISO8601>` convention already
    /// used in that directory by other tools.
    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.string(from: Date())
    }
}

struct HookInstallerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
