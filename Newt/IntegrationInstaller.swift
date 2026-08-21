import Foundation

/// Installs and removes the integration that lets an AI coding agent raise a
/// dynamic claim while it works.
///
/// Agents extend themselves in different ways, so an `Agent` carries the
/// `Method` Newt uses to reach it. Both methods share one safety rule: Newt
/// only ever touches entries it wrote, recognised by the `newt://` URL inside
/// them. That is what makes re-installing and uninstalling safe next to
/// configuration the user and other tools also own.
enum IntegrationInstaller {
    /// Substring that marks an entry as ours. Everything we write drives the
    /// URL scheme, so nothing else plausibly contains it.
    static let marker = "newt://claim?"

    struct Agent {
        /// Stable key, used as the checkbox's `representedObject` and as the
        /// `agent=` value on the claim URL.
        let id: String
        /// How the agent is named to the user.
        let name: String
        let method: Method

        /// Where the change lands, for the confirmation dialog.
        var path: URL {
            switch method {
            case .jsonHooks(let settings, _): settings
            case .pluginFile(let path, _): path
            }
        }
    }

    /// How Newt installs itself into a given agent.
    enum Method {
        /// Merge hook entries into a settings file the user and other tools
        /// also write. Every operation is a merge, and a backup is taken first.
        case jsonHooks(settings: URL, hooks: [HookSpec])
        /// Write a plugin file Newt owns outright, which the agent picks up by
        /// convention. Nothing of the user's is overwritten, so no backup.
        /// `source` is a closure so a harness can supply its own without a
        /// bundle to read from.
        case pluginFile(path: URL, source: () throws -> String)
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

    // MARK: - The agents

    static var claude: Agent {
        Agent(
            id: "claude",
            name: "Claude Code",
            method: .jsonHooks(
                settings: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/settings.json"),
                hooks: [
                    HookSpec(event: "UserPromptSubmit", command: claimCommand(agent: "claude")),
                    HookSpec(event: "Stop", command: releaseCommand),
                    // Belt and braces. The docs are explicit that SessionEnd
                    // does not fire on crash or kill, so it can't be the only
                    // release.
                    HookSpec(event: "SessionEnd", command: releaseCommand),
                ]))
    }

    /// opencode has no hook that fires when a turn *starts* — its two shell
    /// hooks are `file_edited` and `session_completed` — so a claim can only be
    /// raised from a plugin. opencode finds plugins by globbing
    /// `{plugin,plugins}/*.{ts,js}` in its config directory at startup, which
    /// is why installing is a file write and `opencode.json` is never read.
    static var opencode: Agent {
        Agent(
            id: "opencode",
            name: "opencode",
            method: .pluginFile(
                path: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config/opencode/plugin/newt-opencode.js"),
                source: { try bundledSource("newt-opencode") }))
    }

    /// Every agent Newt can integrate with. Adding one means adding an entry
    /// here — the Integrations tab builds itself from this list.
    static var all: [Agent] { [claude, opencode] }

    static func agent(id: String) -> Agent? { all.first { $0.id == id } }

    enum Outcome {
        /// `backup` is nil for a method that had nothing of the user's to save.
        case installed(backup: URL?)
        case alreadyInstalled
        case removed(backup: URL?)
        case notInstalled
    }

    // MARK: - Status

    static func isInstalled(_ agent: Agent) -> Bool {
        switch agent.method {
        case .jsonHooks(let settings, _):
            guard let root = try? load(settings),
                  let hooksByEvent = root["hooks"] as? [String: Any] else { return false }
            return hooksByEvent.values.contains { value in
                guard let groups = value as? [[String: Any]] else { return false }
                return groups.contains { group in
                    entries(in: group).contains { isOurs($0) }
                }
            }
        case .pluginFile(let path, _):
            return isOurPluginFile(path)
        }
    }

    // MARK: - Install

    @discardableResult
    static func install(_ agent: Agent) throws -> Outcome {
        switch agent.method {
        case .jsonHooks(let settings, let hooks):
            return try installHooks(hooks, into: settings)
        case .pluginFile(let path, let source):
            return try installPlugin(try source(), at: path)
        }
    }

    private static func installHooks(_ hooks: [HookSpec], into settings: URL) throws -> Outcome {
        var root = try load(settings)
        var hooksByEvent = root["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for spec in hooks {
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
        return .installed(backup: try write(root, to: settings))
    }

    private static func installPlugin(_ source: String, at path: URL) throws -> Outcome {
        let fm = FileManager.default
        if fm.fileExists(atPath: path.path) {
            guard isOurPluginFile(path) else {
                throw IntegrationInstallerError(
                    "\(path.path) already exists and wasn't written by Newt — refusing to replace it")
            }
            // Ours, but possibly from an older Newt: rewrite so an upgrade
            // doesn't leave a stale plugin behind.
            guard (try? String(contentsOf: path, encoding: .utf8)) != source else {
                return .alreadyInstalled
            }
        }
        try fm.createDirectory(at: path.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try source.write(to: path, atomically: true, encoding: .utf8)
        return .installed(backup: nil)
    }

    /// Rewrites an already-installed plugin whose contents have gone stale,
    /// which is what a Newt upgrade leaves behind — the file is only otherwise
    /// written when the user toggles the checkbox. Silent by design: there is
    /// nothing for the user to decide.
    static func refreshInstalledPlugins() {
        for agent in all {
            guard case .pluginFile(let path, let source) = agent.method,
                  isOurPluginFile(path),
                  let fresh = try? source(),
                  (try? String(contentsOf: path, encoding: .utf8)) != fresh
            else { continue }
            try? fresh.write(to: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Uninstall

    @discardableResult
    static func uninstall(_ agent: Agent) throws -> Outcome {
        switch agent.method {
        case .jsonHooks(let settings, _):
            return try uninstallHooks(from: settings)
        case .pluginFile(let path, _):
            guard isOurPluginFile(path) else { return .notInstalled }
            try FileManager.default.removeItem(at: path)
            return .removed(backup: nil)
        }
    }

    private static func uninstallHooks(from settings: URL) throws -> Outcome {
        var root = try load(settings)
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
        return .removed(backup: try write(root, to: settings))
    }

    // MARK: - Plugin files

    /// True only for a file Newt wrote. Everything else at that path belongs to
    /// someone else and is never replaced or deleted.
    private static func isOurPluginFile(_ url: URL) -> Bool {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return contents.contains(marker)
    }

    private static func bundledSource(_ name: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "js") else {
            throw IntegrationInstallerError("\(name).js is missing from Newt.app — reinstall Newt")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Settings files

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
            throw IntegrationInstallerError("\(url.path) is not a JSON object — refusing to touch it")
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

struct IntegrationInstallerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
