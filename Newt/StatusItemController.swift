import AppKit

/// Owns the menu bar item and its menu, and drives `SleepManager` from it.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength)
    private let sleep = SleepManager()
    private let menu = NSMenu()

    private var noSleepItem: NSMenuItem!
    private var durationParent: NSMenuItem!
    private let durationMenu = NSMenu()
    private var stopItem: NSMenuItem!
    private var messageItem: NSMenuItem!

    /// Label / seconds for each timed-session choice (mirrors lidawake).
    private let durations: [(label: String, seconds: Int)] = [
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
        ("1 hour", 60 * 60),
        ("2 hours", 2 * 60 * 60),
        ("4 hours", 4 * 60 * 60),
        ("8 hours", 8 * 60 * 60),
    ]

    override init() {
        super.init()
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        sleep.onChange = { [weak self] in self?.refresh() }
        sleep.onHelperMessage = { [weak self] msg in self?.showMessage(msg) }
        refresh()
        // Register the privileged helper now rather than on first toggle.
        sleep.prepareHelper()
    }

    /// Called on app termination — restores normal sleep behavior.
    func shutdown() {
        sleep.disengage()
    }

    // MARK: - Menu construction

    private func buildMenu() {
        noSleepItem = NSMenuItem(title: "No sleep",
                                 action: #selector(toggleNoSleep),
                                 keyEquivalent: "")
        noSleepItem.target = self
        menu.addItem(noSleepItem)

        menu.addItem(.separator())

        durationParent = NSMenuItem(title: "Keep awake for",
                                    action: nil, keyEquivalent: "")
        for d in durations {
            let item = NSMenuItem(title: d.label,
                                  action: #selector(pickDuration(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = d.seconds
            durationMenu.addItem(item)
        }
        durationParent.submenu = durationMenu
        menu.addItem(durationParent)

        stopItem = NSMenuItem(title: "Stop",
                              action: #selector(stop), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(.separator())

        messageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        messageItem.isEnabled = false
        messageItem.isHidden = true
        menu.addItem(messageItem)

        let quit = NSMenuItem(title: "Quit Newt",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func toggleNoSleep() {
        clearMessage()
        sleep.toggleIndefinite()
    }

    @objc private func pickDuration(_ sender: NSMenuItem) {
        clearMessage()
        sleep.startTimed(seconds: sender.tag)
    }

    @objc private func stop() {
        clearMessage()
        sleep.stop()
    }

    // MARK: - Refresh

    /// Refresh icon and menu state. Also called as the menu opens so the
    /// remaining-time label is current.
    private func refresh() {
        let active = sleep.isActive
        let symbol = active ? "eye" : "eye.slash"
        if let image = NSImage(systemSymbolName: symbol,
                               accessibilityDescription: "Newt") {
            image.isTemplate = true
            statusItem.button?.image = image
        }

        noSleepItem.state = (sleep.state == .indefinite) ? .on : .off

        if let remaining = sleep.remaining {
            durationParent.title = "Keep awake for — \(Self.format(remaining)) left"
        } else {
            durationParent.title = "Keep awake for"
        }
        for item in durationMenu.items {
            item.state = (item.tag == sleep.activeDurationSeconds
                          && sleep.activeDurationSeconds != 0) ? .on : .off
        }

        // Stop is only meaningful for a timed session; the checkbox handles
        // the indefinite case.
        if case .timed = sleep.state {
            stopItem.isHidden = false
        } else {
            stopItem.isHidden = true
        }
    }

    private func showMessage(_ text: String) {
        messageItem.title = text
        messageItem.isHidden = false
    }

    private func clearMessage() {
        messageItem.title = ""
        messageItem.isHidden = true
    }

    /// Format a remaining interval as e.g. "1h 42m" or "12m".
    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let minutes = (total + 59) / 60          // round up so it never shows 0m
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }
}
