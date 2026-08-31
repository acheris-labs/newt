import AppKit
import Sparkle

/// Owns the menu bar item and its menu, and drives `SleepManager` from it.
final class StatusItemController: NSObject, NSMenuDelegate {
    // `var` because the status item is recreated if macOS reaps it on wake
    // from deep sleep — see `handleWake()`.
    private var statusItem = NSStatusBar.system.statusItem(
        withLength: NSStatusItem.variableLength)
    private let sleep = SleepManager()
    private let login = LoginItemController()
    private let menu = NSMenu()
    private let updater: SPUStandardUpdaterController

    private var durationSliderView: DurationSliderView!
    private var messageItem: NSMenuItem!
    private var scheduleItem: NSMenuItem!
    private var suppressItem: NSMenuItem!
    private var claimsItem: NSMenuItem!
    /// Retained across openings — letting it deallocate would lose the
    /// window's position and the tab you were on.
    private var settingsWindow: SettingsWindowController?
    /// Lazy so opting out of notifications never touches `UserNotifications`.
    private lazy var notifications = NotificationManager()
    /// Re-renders the badged (non-template) icon when the menu bar flips
    /// light/dark — a non-template image doesn't auto-retint.
    private var appearanceObservation: NSKeyValueObservation?

    /// Ticks the remaining-time label while the menu is open.
    private var menuTickTimer: Timer?

    /// Idle countdown for "Hide icon". `idleSince` is when Newt last stopped
    /// claiming anything; the timer is a one-shot armed at the deadline, not a
    /// poll. `hiddenByIdle` separates "we put the icon away" from "macOS reaped
    /// it", which look identical from the outside — see
    /// `restoreStatusItemIfNeeded()`.
    private var idleSince: Date?
    private var idleHideTimer: Timer?
    private var hiddenByIdle = false
    private var menuIsOpen = false

    /// Spins the split dot. Runs only while that dot is actually on screen —
    /// both claim kinds up, the dot switched on, and spin enabled — so the app
    /// is idle again the moment any of those stops being true.
    private var badgeSpinTimer: Timer?
    private var badgeSpinFrame = 0
    /// One full turn, pre-rendered. Re-rendering the SF Symbol, the tint and the
    /// knockout 24 times a second cost ~8% CPU; the rotation is periodic, so a
    /// fixed set of frames can just be cycled instead. Rebuilt only when
    /// something that affects the drawing changes.
    private var badgeSpinFrames: [NSImage] = []
    private var badgeSpinFramesKey = ""

    /// Whether the current `messageItem` text has already been on screen for a
    /// full menu opening — see `menuWillOpen`.
    private var messageSeen = false

    /// Workspace wake observer — recreates the status item if macOS reaped it.
    private var wakeObserver: NSObjectProtocol?

    init(updater: SPUStandardUpdaterController) {
        self.updater = updater
        super.init()
        buildMenu()
        // Enablement is set explicitly in `refresh()`; leaving validation on
        // would let AppKit override it (notably on the Claims submenu parent).
        menu.autoenablesItems = false
        menu.delegate = self
        sleep.onChange = { [weak self] in self?.refresh() }
        sleep.onHelperMessage = { [weak self] msg in self?.showMessage(msg) }
        sleep.onTimerExpired = { [weak self] in
            guard let self, self.sleep.isNotificationEnabled(.notifyOnExpiry) else { return }
            self.notifications.postTimerEnded()
        }
        configureStatusItem()
        // macOS can reap our status item from the menu bar after deep sleep and
        // never restore it (the process keeps running, the icon just vanishes).
        // Recreate it on wake. NSWorkspace sleep/wake notifications post only on
        // the *workspace* center, never the default NotificationCenter.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleWake() }
        sleep.prepareHelper()
        // First run defaults to Open at Login — afterward, respect the user.
        if let msg = login.bootstrapDefaultIfNeeded() { showMessage(msg) }
        sleep.resumeIfNeeded()
        refresh()
    }

    /// Wires the status item's button and hover tooltip. Shared by `init` and
    /// `rebuildStatusItem()` so a recreated item behaves identically.
    private func configureStatusItem() {
        // Persist the icon's menu bar position. Without an autosave name a fresh
        // item is placed at the left end of the status area — the side a notch
        // clips first — and any position the user drags to is forgotten on the
        // next launch. Never rename this: the saved position is keyed off it.
        statusItem.autosaveName = "NewtStatusItem"
        // `isVisible` is persisted under the autosave name, so an item hidden by
        // the idle timeout would come back hidden on the next launch. Launching
        // Newt again is the documented way to get the icon back; it has to work.
        statusItem.isVisible = true
        // Custom click handling: left-click obeys `LeftClickAction`, right-click
        // (and Control-click) always opens the menu. We don't assign
        // `statusItem.menu` here — assigning it would short-circuit the action
        // and make every click open the menu unconditionally.
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refresh()
        // Hover tooltip showing remaining time while keep-awake is engaged.
        // Registered *after* the first refresh so `button.bounds` reflects the
        // icon size — registering against `.zero` silently fails. Owner-callback
        // form so the string is computed at hover time; an empty return
        // suppresses the tooltip when not engaged.
        if let button = statusItem.button {
            button.addToolTip(button.bounds, owner: self, userData: nil)
            // Re-render the badged (non-template) icon on light/dark menu bar
            // flips — a non-template image won't auto-retint.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                self?.refresh()
            }
        }
    }

    /// On wake, rebuild the status item only if macOS dropped it. A live item's
    /// button is hosted in an `NSStatusBarWindow`; once reaped it has no window.
    /// Guarding on this avoids needlessly shifting the icon's menu-bar position
    /// on every wake (the common case where nothing was reaped).
    private func handleWake() {
        restoreStatusItemIfNeeded()
    }

    /// Re-assert the status item, preferring the cheap path. Recreating an
    /// `NSStatusItem` churns its menu bar position — on a crowded bar that can
    /// drop the icon into the strip a notch clips — so toggle `isVisible` first
    /// and rebuild only if the item is genuinely gone.
    private func restoreStatusItemIfNeeded() {
        // A hidden item has no window either, so without this the next wake
        // would drag the icon back out on its own.
        guard !hiddenByIdle else { return }
        guard statusItem.button?.window == nil else { return }
        statusItem.isVisible = true
        // AppKit doesn't rehost the button synchronously, so give it a runloop
        // turn before concluding the item is unrecoverable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.hiddenByIdle,
                  self.statusItem.button?.window == nil else { return }
            self.rebuildStatusItem()
        }
    }

    /// User-initiated recovery, called when the app is re-opened while already
    /// running — what people try when the icon has vanished. Re-asserts
    /// visibility, then falls back to the same repair path as wake.
    func revealStatusItem() {
        hiddenByIdle = false
        statusItem.isVisible = true
        restoreStatusItemIfNeeded()
        restartIdleHideCountdown()
    }

    /// Last resort, when the item can't be revived in place. The menu, slider
    /// views, and keep-awake state (`sleep`) are independent of the status item
    /// and survive untouched; `configureStatusItem()` re-runs `refresh()` to
    /// restore the correct icon.
    private func rebuildStatusItem() {
        // Drop the observation before the observed button goes away;
        // `configureStatusItem()` re-establishes it on the new button.
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        // Deliberately no `removeStatusItem` — that discards the autosaved
        // position, which would defeat `autosaveName` on every rebuild. Dropping
        // the old item's last strong reference deallocates it, and an
        // `NSStatusItem` removes itself from the bar on dealloc anyway.
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength)
        configureStatusItem()
    }

    /// Called on app termination — restores normal sleep behavior.
    func shutdown() {
        if let token = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            wakeObserver = nil
        }
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        idleHideTimer?.invalidate()
        idleHideTimer = nil
        sleep.shutdown()
    }

    deinit {
        if let token = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        appearanceObservation?.invalidate()
    }

    // MARK: - Menu construction

    private func buildMenu() {
        // Keep-awake slider — the primary control.
        durationSliderView = DurationSliderView(
            initialPosition: sleep.sliderPosition,
            initialText:     sleep.displayString(),
            textForPosition: { [weak self] in
                self?.sleep.sliderLabel(forPosition: $0) ?? ""
            }
        ) { [weak self] pos in
            self?.clearMessage()
            self?.sleep.setSliderPosition(pos)
        }
        let durationItem = NSMenuItem()
        durationItem.view = durationSliderView
        menu.addItem(durationItem)

        scheduleItem = NSMenuItem(title: "Use schedule",
                                  action: #selector(toggleSchedule),
                                  keyEquivalent: "")
        scheduleItem.target = self
        menu.addItem(scheduleItem)

        suppressItem = NSMenuItem(title: "Suppress all claims",
                                  action: #selector(toggleSuppress),
                                  keyEquivalent: "")
        suppressItem.target = self
        menu.addItem(suppressItem)

        menu.addItem(.separator())

        // Sits with Suppress: both are about what's currently holding the Mac
        // awake. Always present so it's a predictable place to look, greyed
        // out when nothing is held.
        claimsItem = NSMenuItem(title: "Claims", action: nil, keyEquivalent: "")
        let claimsSub = NSMenu()
        // The submenu can legitimately hold nothing but disabled rows — the
        // slider and schedule are shown but can't be revoked from here — and
        // AppKit's automatic validation would grey out the parent in that case.
        // Managing enablement by hand keeps `isEnabled` the single truth.
        claimsSub.autoenablesItems = false
        claimsItem.submenu = claimsSub
        menu.addItem(claimsItem)


        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(showSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // Open at Login, Resume last state and Check Automatically now live in
        // Settings ▸ General. Checking *now* is an action, not a setting, so it
        // stays where you can reach it in one click.
        let checkNowItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        checkNowItem.target = updater
        menu.addItem(checkNowItem)

        messageItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        messageItem.isEnabled = false
        messageItem.isHidden = true
        menu.addItem(messageItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Newt",
                               action: #selector(showAbout),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit Newt",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Actions





    @objc private func toggleSchedule() {
        clearMessage()
        sleep.setScheduleEnabled(!sleep.scheduleEnabled)
    }

    @objc private func toggleSuppress() {
        clearMessage()
        sleep.setSuppressed(!sleep.isSuppressed)
    }

    /// Show what a claim actually is, and offer to revoke it. Revoking is not
    /// wired straight to the menu item on purpose: identifying the right claim
    /// matters more than saving a click, and a live agent would just re-claim
    /// on its next turn anyway.
    @objc private func showClaimDetail(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let claim = sleep.dynamicClaims.claims[id] else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "\(claim.agent) — \(claim.label)"
        var body = claim.detailLines.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
        if claim.hasNoAutomaticRelease {
            body += "\n\nNewt couldn't identify the process behind this claim, "
                + "so nothing will release it automatically."
        }
        alert.informativeText = body
        alert.alertStyle = .informational

        let revoke = alert.addButton(withTitle: "Revoke")
        // `hasDestructiveAction` alone leaves dark red text on a red bezel in
        // dark mode, which is unreadable. Setting both the fill and the title
        // colour is the only way to be legible in either appearance — and the
        // title has to come with the bezel, since white on the default grey is
        // just as bad the other way.
        revoke.bezelColor = .systemRed
        revoke.attributedTitle = NSAttributedString(string: "Revoke", attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                return style
            }(),
        ])
        let cancel = alert.addButton(withTitle: "Cancel")
        // Return dismisses rather than revokes — the destructive option should
        // never be the one you hit by reflex.
        revoke.keyEquivalent = ""
        cancel.keyEquivalent = "\r"

        if alert.runModal() == .alertFirstButtonReturn {
            sleep.dynamicClaims.remove(id: id)
        }
    }

    @objc private func releaseAllClaims() {
        sleep.dynamicClaims.removeAll()
    }

    /// Add or remove the integration that lets an agent raise a claim while it
    /// works. Changing a file in the user's home directory is worth confirming
    /// first, and the wording has to match what actually happens — the two
    /// methods differ in whether anything of the user's is touched at all.
    private func toggleIntegration(id: String) {
        guard let agent = IntegrationInstaller.agent(id: id) else { return }
        let installed = IntegrationInstaller.isInstalled(agent)
        NSApp.activate(ignoringOtherApps: true)

        let noun: String
        let detail: String
        switch agent.method {
        case .jsonHooks:
            noun = "Hooks"
            detail = installed
                ? "Newt will remove its hooks from:\n\(agent.path.path)\n\nAnything else in that file is left alone."
                : "Newt will add three hooks to:\n\(agent.path.path)\n\nThey tell Newt when \(agent.name) starts and finishes working. Anything already in that file is left alone, and a backup is made first."
        case .pluginFile:
            noun = "Plugin"
            detail = installed
                ? "Newt will delete the plugin it added at:\n\(agent.path.path)\n\nNothing else in \(agent.name)'s configuration is touched."
                : "Newt will add a plugin at:\n\(agent.path.path)\n\nIt tells Newt when \(agent.name) starts and finishes working. \(agent.name) picks up plugins from that folder on its own, so none of your settings are changed."
        }

        let confirm = NSAlert()
        confirm.messageText = installed
            ? "Stop keeping your Mac awake while \(agent.name) works?"
            : "Keep your Mac awake while \(agent.name) works?"
        confirm.informativeText = detail
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: installed ? "Remove \(noun)" : "Add \(noun)")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            let outcome = installed ? try IntegrationInstaller.uninstall(agent)
                                    : try IntegrationInstaller.install(agent)
            let backupLine = { (backup: URL?) in
                backup.map { "\n\nBackup: \($0.path)" } ?? ""
            }
            switch outcome {
            case .installed(let backup):
                showAlert("\(noun) added",
                          informative: "\(agent.name) usually picks this up straight away. If a session that's already open doesn't, restart it.\(backupLine(backup))")
            case .removed(let backup):
                showAlert("\(noun) removed",
                          informative: "If a session that's already open keeps claiming, restart it.\(backupLine(backup))")
            case .alreadyInstalled, .notInstalled:
                break
            }
        } catch {
            showAlert("Couldn't set up \(agent.name)", informative: "\(error)")
        }
        refresh()
    }

    @objc private func showSettings() {
        openSettings(selecting: nil)
    }

    private func openSettings(selecting tab: String?) {
        if settingsWindow == nil {
            let window = SettingsWindowController(sleep: sleep, login: login,
                                                  updater: updater.updater)
            window.onExpiryNotificationsEnabled = { [weak self] in
                self?.confirmNotificationAuthorization()
            }
            window.onToggleIntegration = { [weak self] id in
                self?.toggleIntegration(id: id)
            }
            settingsWindow = window
        }
        settingsWindow?.show(selecting: tab)
    }

    /// Ask for notification permission when expiry alerts are switched on, and
    /// turn the option back off if it's refused — a ticked box that can never
    /// fire is worse than an unticked one. Lives here rather than in the
    /// settings window because the alert and the `NotificationManager` do.
    private func confirmNotificationAuthorization() {
        notifications.requestAuthorization { [weak self] granted, message in
            guard let self, !granted else { return }
            self.sleep.setNotificationOption(.notifyOnExpiry, enabled: false)
            self.showAlert(
                "Newt can't post notifications",
                informative: message ?? "Allow notifications for Newt in System Settings ▸ Notifications, then turn this option on again.")
        }
    }


    /// Standard macOS About panel. It pulls the app icon (the Newt logo), name,
    /// version (`CFBundleShortVersionString` + `CFBundleVersion`), and copyright
    /// (`NSHumanReadableCopyright`) from the bundle automatically; we supply the
    /// license + no-warranty note as the credits blurb.
    @objc private func showAbout() {
        let blurb = "Free software under the MIT License.\n"
            + "Provided \u{201C}as is\u{201D}, without warranty of any kind, express or implied."
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(string: blurb, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
        // A menu bar (LSUIElement) app isn't active, so the panel would open
        // behind other windows without activating first.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// Routes left/right mouse events on the menu bar icon. Right-click and
    /// Control-click always pop the menu. Left-click obeys `leftClickAction`.
    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
        let isControlClick = event?.modifierFlags.contains(.control) ?? false
        let opensMenu = isRightClick || isControlClick || sleep.leftClickAction == .openMenu
        if opensMenu {
            // Standard idiom for "show menu without owning it persistently."
            // Assigning `menu` then performing a click pops it; clearing the
            // assignment afterward restores the custom action for future clicks.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        clearMessage()
        sleep.performLeftClickToggle()
    }

    // MARK: - newt:// URL scheme

    /// Entry point for the `newt://` scheme (registered in Info.plist, routed
    /// via AppDelegate). Everything goes through the same SleepManager API as
    /// the menu, so the battery floor and wake-mode guards apply unchanged.
    ///   newt://engage?minutes=240   engage for exactly N minutes (1…1440)
    ///   newt://engage?until=17:00   engage until the next HH:MM occurrence
    ///   newt://engage               engage at the last-used duration
    ///   newt://off                  end the slider's session (not the schedule)
    ///   newt://toggle               off if the slider is running, else last-used
    ///   newt://suppress             veto everything (add ?toggle to flip)
    ///   newt://unsuppress           lift the veto
    ///   newt://claim?acquire=…&id=… raise/drop a dynamic claim
    func handleURL(_ url: URL) {
        clearMessage()
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func query(_ name: String) -> String? {
            comps?.queryItems?.first { $0.name == name }?.value
        }
        // Presence, not value, so both `?toggle` and `?toggle=1` work.
        func hasFlag(_ name: String) -> Bool {
            comps?.queryItems?.contains { $0.name == name } ?? false
        }
        // Hosts are case-insensitive too (RFC 3986 §3.2.2).
        switch url.host?.lowercased() {
        case "engage":
            if let m = query("minutes") {
                guard let minutes = Int(m), (1...1440).contains(minutes) else {
                    showMessage("newt:// — minutes must be 1…1440")
                    return
                }
                sleep.engageFor(minutes: minutes)
            } else if let u = query("until") {
                guard let date = Self.nextOccurrence(ofClockTime: u) else {
                    showMessage("newt:// — until must be HH:MM")
                    return
                }
                sleep.engageUntil(date)
            } else {
                sleep.setSliderPosition(sleep.lastUsedSliderPosition)
            }
        case "off":
            sleep.setSliderPosition(0)
        case "toggle":
            // The slider's own claim, not `isActive` — otherwise a schedule
            // block in progress would make this a no-op.
            sleep.setSliderPosition(sleep.hasSliderClaim ? 0 : sleep.lastUsedSliderPosition)
        case "suppress":
            sleep.setSuppressed(hasFlag("toggle") ? !sleep.isSuppressed : true)
        case "unsuppress":
            sleep.setSuppressed(false)
        case "claim":
            handleClaimURL(query: query)
        default:
            showMessage("newt:// — unknown action \u{201C}\(url.host ?? "")\u{201D}")
        }
    }

    /// Raise or drop a dynamic claim. Usually driven by an AI agent's hooks, but
    /// anything can; `id` identifies the claim and is all a release needs.
    private func handleClaimURL(query: (String) -> String?) {
        guard let id = query("id"), !id.isEmpty else {
            showMessage("newt:// — claim needs an id")
            return
        }
        let acquire = query("acquire").map { $0 != "false" && $0 != "0" } ?? true
        guard acquire else {
            sleep.dynamicClaims.remove(id: id)
            return
        }
        sleep.dynamicClaims.add(DynamicClaim(
            id: id,
            agent: query("agent") ?? "agent",
            pid: query("pid").flatMap(pid_t.init),
            // `ps` prints "??" for a process with no controlling terminal.
            tty: query("tty").flatMap { $0 == "??" || $0.isEmpty ? nil : $0 },
            label: query("label") ?? "unknown",
            since: Date()))
    }

    /// "17:00" → the next Date that wall-clock time occurs (today if still
    /// ahead, else tomorrow). nil for anything that isn't a valid HH:MM.
    private static func nextOccurrence(ofClockTime s: String) -> Date? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        let cal = Calendar.current
        guard let today = cal.date(bySettingHour: h, minute: m, second: 0,
                                   of: Date()) else { return nil }
        if today > Date() { return today }
        return cal.date(byAdding: .day, value: 1, to: today)
    }


    // MARK: - Refresh

    /// Refresh icon and menu state. Also called as the menu opens so the
    /// remaining-time label is current.
    private func refresh() {
        let active = sleep.isActive
        // Filled lizard while engaged, outline when sleeping; a red corner dot
        // is layered on when the "badge" option is enabled and engaged.
        applyStatusImage()
        let blocked = sleep.blockedByBattery
        let vetoLabel = blocked.map { "battery \($0.percent)% — recharge to enable" }
                    ?? (sleep.isSuppressed ? "suppressed" : nil)
        durationSliderView.refresh(position: sleep.sliderPosition,
                                   displayText: vetoLabel ?? sleep.displayString(),
                                   enabled: vetoLabel == nil)
        scheduleItem.state = sleep.scheduleEnabled ? .on : .off
        // Status rides on the item itself rather than an indented row beneath.
        scheduleItem.title = sleep.scheduleSummary()
            .map { "Use schedule — \($0)" } ?? "Use schedule"
        suppressItem.state = sleep.isSuppressed ? .on : .off
        suppressItem.title = suppressTitle()
        refreshClaims()
        updateIdleHide()
        settingsWindow?.refresh()
    }

    /// Drives the "Hide icon" timeout. Newt counts as idle when nothing is
    /// claiming — a claim a veto is currently refusing still keeps the icon on
    /// screen, since that is when the tooltip explaining why is worth reading.
    private func updateIdleHide() {
        guard !sleep.hasAnyClaim, !menuIsOpen else {
            if hiddenByIdle {
                hiddenByIdle = false
                statusItem.isVisible = true
            }
            cancelIdleHide()
            return
        }
        guard let delay = sleep.hideIconAfterSeconds else { return cancelIdleHide() }
        guard !hiddenByIdle else { return }
        let since = idleSince ?? Date()
        idleSince = since
        let deadline = since.addingTimeInterval(delay)
        // refresh() runs on every state change; the deadline only actually moves
        // when the delay setting does, so don't churn a timer for the rest.
        if let timer = idleHideTimer, abs(timer.fireDate.timeIntervalSince(deadline)) < 1 {
            return
        }
        idleHideTimer?.invalidate()
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            self?.hideStatusItem()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleHideTimer = timer
    }

    private func cancelIdleHide() {
        idleSince = nil
        idleHideTimer?.invalidate()
        idleHideTimer = nil
    }

    private func restartIdleHideCountdown() {
        cancelIdleHide()
        updateIdleHide()
    }

    private func hideStatusItem() {
        idleHideTimer = nil
        guard !sleep.hasAnyClaim, !menuIsOpen else {
            restartIdleHideCountdown()
            return
        }
        hiddenByIdle = true
        statusItem.isVisible = false
    }

    /// Rebuilds the Claims submenu: everything currently holding the Mac awake,
    /// whatever raised it. Cheap and infrequent, so rebuilding beats diffing.
    ///
    /// Dynamic claims can be revoked from here. The slider and the schedule are
    /// listed for completeness but greyed — they're turned off with their own
    /// controls, and revoking them here would just be a second way to do the
    /// same thing.
    private func refreshClaims() {
        guard let submenu = claimsItem.submenu else { return }
        submenu.removeAllItems()

        let dynamic = sleep.dynamicClaims.sortedClaims
        claimsItem.isEnabled = !dynamic.isEmpty || sleep.hasSliderClaim
            || sleep.scheduleClaimEnd != nil
        guard claimsItem.isEnabled else { return }

        if !dynamic.isEmpty {
            submenu.addItem(disabledRow("Click a dynamic claim for details"))
            for claim in dynamic {
                let item = NSMenuItem(title: claim.menuTitle,
                                      action: #selector(showClaimDetail(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = claim.id
                item.toolTip = claim.detail
                submenu.addItem(item)
            }
        }

        if sleep.hasSliderClaim {
            let row = disabledRow("Keep awake slider — \(sleep.displayString())")
            row.toolTip = "Slide Keep awake back to off to release this"
            submenu.addItem(row)
        }
        if let end = sleep.scheduleClaimEnd {
            let row = disabledRow("Schedule — until \(SleepManager.clockString(end))")
            row.toolTip = "Untick Use schedule, or Suppress, to release this"
            submenu.addItem(row)
        }

        guard !dynamic.isEmpty else { return }
        submenu.addItem(.separator())
        let all = NSMenuItem(title: "Release all dynamic claims",
                             action: #selector(releaseAllClaims),
                             keyEquivalent: "")
        all.target = self
        submenu.addItem(all)
    }

    /// A greyed, unclickable row — the same idiom the Configuration submenu's
    /// section headers use.
    private func disabledRow(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Draw the icon for the current state, and keep the spin timer in step
    /// with whether the split dot is showing.
    private func applyStatusImage() {
        let badge = currentBadge()
        let spinning = badge == .both && sleep.badgeSpin
        updateBadgeSpin(spinning: spinning)
        if spinning, !badgeSpinFrames.isEmpty {
            statusItem.button?.image = badgeSpinFrames[badgeSpinFrame % badgeSpinFrames.count]
            return
        }
        statusItem.button?.image = Self.statusImage(
            active: sleep.isActive, badge: badge, suppressed: sleep.isSuppressed,
            style: sleep.badgeStyle)
    }

    private static let spinFrameCount = 36
    private static let spinSecondsPerTurn = 4.5

    private func updateBadgeSpin(spinning: Bool) {
        // Only the two-tone dot has anything to show; a solid disc is radially
        // symmetric, so spinning it would burn a timer for no visible change.
        guard spinning else {
            badgeSpinTimer?.invalidate()
            badgeSpinTimer = nil
            badgeSpinFrames = []
            badgeSpinFramesKey = ""
            badgeSpinFrame = 0
            return
        }
        rebuildSpinFramesIfNeeded()
        guard badgeSpinTimer == nil else { return }
        let interval = Self.spinSecondsPerTurn / Double(Self.spinFrameCount)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, !self.badgeSpinFrames.isEmpty else { return }
            self.badgeSpinFrame = (self.badgeSpinFrame + 1) % self.badgeSpinFrames.count
            self.statusItem.button?.image = self.badgeSpinFrames[self.badgeSpinFrame]
        }
        // `.common` so it keeps turning while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        badgeSpinTimer = timer
    }

    /// Frames depend on everything that affects the drawing — including the menu
    /// bar's appearance, since the outline follows `labelColor`.
    private func rebuildSpinFramesIfNeeded() {
        let style = sleep.badgeStyle
        let appearance = statusItem.button?.effectiveAppearance.name.rawValue ?? ""
        let key = "\(style.scale)|\(style.outline)|\(style.scheduled)|\(style.dynamic)"
            + "|\(style.idle)|\(style.awake)|\(appearance)"
        guard key != badgeSpinFramesKey || badgeSpinFrames.isEmpty else { return }
        badgeSpinFramesKey = key
        badgeSpinFrames = (0 ..< Self.spinFrameCount).compactMap { i in
            var frame = style
            frame.rotation = (2 * .pi) * Double(i) / Double(Self.spinFrameCount)
            return Self.statusImage(active: sleep.isActive, badge: .both,
                                    suppressed: false, style: frame)
        }
    }

    /// Which dot to draw, or nil for none. Only meaningful while engaged: the
    /// badge says *why* the Mac is awake, so it has nothing to say when it isn't.
    private func currentBadge() -> ClaimBadge? {
        guard sleep.isActive, sleep.isNotificationEnabled(.badgeWhenEngaged) else { return nil }
        let scheduled = sleep.hasSliderClaim || sleep.scheduleClaimEnd != nil
        let dynamic = !sleep.dynamicClaims.isEmpty
        switch (scheduled, dynamic) {
        case (true, true):  return .both
        case (false, true): return .dynamic
        default:            return .scheduled
        }
    }

    /// Spelling out when suppression lifts is the only way the user can tell a
    /// "skip this block" from a latch they have to clear themselves.
    private func suppressTitle() -> String {
        guard sleep.isSuppressed, let until = sleep.suppressedUntil,
              until < .distantFuture else { return "Suppress all claims" }
        return "Suppress all claims (until \(SleepManager.clockString(until)))"
    }

    private func showMessage(_ text: String) {
        messageItem.title = text
        messageItem.isHidden = false
        messageSeen = false
    }

    private func clearMessage() {
        messageItem.title = ""
        messageItem.isHidden = true
        messageSeen = false
    }

    /// Modal alert for things the menu's message line can't deliver — anything
    /// reported asynchronously, after the click that triggered it has already
    /// dismissed the menu. A menu bar (LSUIElement) app isn't active, so the
    /// panel needs the same activation `showAbout()` uses.
    private func showAlert(_ text: String, informative: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text
        alert.informativeText = informative
        alert.alertStyle = .informational
        alert.runModal()
    }

    /// The menu bar image for a given state. `idle` and `awake` are separate
    /// looks, so this picks one and every decision below follows from it.
    ///
    /// A template image (which AppKit auto-tints for the menu bar) is used
    /// whenever nothing here needs colour. Anything else — a claim dot, a
    /// chosen glyph colour, or any backdrop — has to be a non-template
    /// composite, and `appearanceObservation` re-renders it on light/dark flips.
    ///
    /// Static so it can be rendered without a live status item.
    static func statusImage(active: Bool, badge: ClaimBadge?, suppressed: Bool,
                            style: BadgeStyle = BadgeStyle()) -> NSImage? {
        let look = active ? style.awake : style.idle
        let symbol = active ? "lizard.fill" : "lizard"
        guard let base = NSImage(systemSymbolName: symbol,
                                 accessibilityDescription: "Newt") else { return nil }
        guard suppressed || badge != nil
                || look.backdrop != .none || look.glyphColor != nil else {
            base.isTemplate = true
            return base
        }
        let canvas = canvasSize(for: look.backdrop, base: base.size)
        // A round backdrop's edge falls short of the canvas corner a badge would
        // otherwise sit in, so pull it back in.
        let round = look.backdrop == .circle
        let inset = round ? canvas.height * 0.1 : 0
        let image = NSImage(size: canvas, flipped: false) { rect in
            drawIcon(base, symbol: symbol, in: rect, look: look)
            if suppressed {
                drawCautionBadge(in: rect, basis: base.size.height, cornerInset: inset)
            } else if let badge {
                drawClaimBadge(in: rect, badge: badge, style: style,
                               basis: base.size.height, cornerInset: inset)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Room for the backdrop to live in. Only the shapes that draw outside the
    /// glyph need it, so the plain icon keeps exactly the size — and therefore
    /// the dot placement — it has always had.
    private static func canvasSize(for backdrop: IconBackdrop, base: NSSize) -> NSSize {
        switch backdrop {
        case .none:            return base
        case .outline:         return NSSize(width: base.width + 3, height: base.height + 3)
        case .glow:            return NSSize(width: base.width + 5, height: base.height + 5)
        case .circle:
            let d = max(base.width, base.height) + 2
            return NSSize(width: d, height: d)
        }
    }

    /// The backdrop a colour has to be to lift the glyph off the wallpaper: the
    /// opposite end of the scale. Resolved from the glyph at draw time, so it
    /// follows the menu bar between light and dark rather than freezing.
    private static func contrasting(to color: NSColor) -> NSColor {
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        let luma = 0.299 * rgb.redComponent
                 + 0.587 * rgb.greenComponent
                 + 0.114 * rgb.blueComponent
        return luma > 0.5 ? NSColor(white: 0, alpha: 0.85) : NSColor(white: 1, alpha: 0.9)
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func drawIcon(_ base: NSImage, symbol: String,
                                 in rect: NSRect, look: IconLook) {
        let glyphColor = look.glyphColor ?? .labelColor
        let backColor = look.backdropColor ?? contrasting(to: glyphColor)

        // `.circle` swaps the glyph for SF Symbols' own lizard-in-a-disc, which
        // is a two-layer symbol: palette colours the lizard and the disc
        // separately. A flat tint would colour the disc and knock the lizard
        // out of it, letting the wallpaper through the very shape we're trying
        // to make readable.
        if look.backdrop == .circle {
            let side = min(rect.width, rect.height)
            let config = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
                .applying(.init(paletteColors: [glyphColor, backColor]))
            if let disc = NSImage(systemSymbolName: "lizard.circle.fill",
                                  accessibilityDescription: "Newt")?
                .withSymbolConfiguration(config) {
                let ratio = disc.size.width / disc.size.height
                disc.draw(in: NSRect(x: rect.midX - side * ratio / 2,
                                     y: rect.midY - side / 2,
                                     width: side * ratio, height: side))
            }
            return
        }

        let h = base.size.height
        let ratio = base.size.width / h
        let scale = min(rect.width / (h * ratio), rect.height / h)
        let glyph = NSRect(x: rect.midX - h * ratio * scale / 2,
                           y: rect.midY - h * scale / 2,
                           width: h * ratio * scale, height: h * scale)

        switch look.backdrop {
        case .none, .circle:
            break
        case .outline:
            // Dilate the glyph in every direction — a stroke around an arbitrary
            // symbol path, without needing the path itself.
            let ring = tinted(base, backColor)
            let width = max(1, rect.height * 0.055)
            for step in stride(from: 0.0, to: 2 * .pi, by: .pi / 10) {
                ring.draw(in: glyph.offsetBy(dx: cos(step) * width, dy: sin(step) * width))
            }
        case .glow:
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = backColor.withAlphaComponent(0.95)
            shadow.shadowBlurRadius = rect.height * 0.16
            shadow.shadowOffset = .zero
            shadow.set()
            // One pass is too faint to rescue a thin glyph against a bright
            // wallpaper; the shadow compounds where the passes overlap.
            let lit = tinted(base, glyphColor)
            for _ in 0 ..< 3 { lit.draw(in: glyph) }
            NSGraphicsContext.restoreGraphicsState()
        }
        tinted(base, glyphColor).draw(in: glyph)
    }

    /// What's holding the Mac awake, for the indicator dot: the long-lived
    /// controls (slider, schedule), transient agent claims, or both at once.
    enum ClaimBadge {
        case scheduled
        case dynamic
        case both
    }

    /// Green for the slider/schedule, blue for dynamic claims — so a glance says
    /// whether the Mac is awake because you asked, or because an agent is busy.
    /// Both at once splits the dot down the middle: equal halves read as "a mix"
    /// at menu bar size, where a small inner core just reads as the outer color.
    ///
    /// Two things make the dot legible over an arbitrary wallpaper, and neither
    /// is the color itself. A gap punched out of the lizard stops the badge
    /// merging into the glyph, and an outline in `labelColor` — the one color
    /// AppKit has already chosen to be readable against this menu bar —
    /// separates it from whatever is showing through behind.
    /// `basis` is the height the dot is sized from — the glyph's, not the
    /// canvas's, so a backdrop that enlarges the canvas doesn't inflate the dot
    /// with it. `cornerInset` pulls it in for a round backdrop, whose edge falls
    /// short of the canvas corner the dot would otherwise sit in.
    static func drawClaimBadge(in rect: NSRect, badge: ClaimBadge, style: BadgeStyle,
                               basis: CGFloat? = nil, cornerInset: CGFloat = 0) {
        let height = basis ?? rect.height
        let d = height * style.scale
        // Bottom-right corner (rect is unflipped, so minY is the bottom).
        let dot = NSRect(x: rect.maxX - d - cornerInset, y: rect.minY + cornerInset,
                         width: d, height: d)
        let ring = max(1, (height * 0.06).rounded())

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSBezierPath(ovalIn: dot.insetBy(dx: -ring, dy: -ring)).fill()
        NSGraphicsContext.restoreGraphicsState()

        switch badge {
        case .scheduled:
            style.scheduled.setFill()
            NSBezierPath(ovalIn: dot).fill()
        case .dynamic:
            style.dynamic.setFill()
            NSBezierPath(ovalIn: dot).fill()
        case .both:
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: dot).addClip()
            // Turn the split about the dot's centre. The halves are drawn
            // oversized so no corner of them can rotate into view inside the
            // circular clip.
            let spin = NSAffineTransform()
            spin.translateX(by: dot.midX, yBy: dot.midY)
            spin.rotate(byRadians: CGFloat(style.rotation))
            spin.translateX(by: -dot.midX, yBy: -dot.midY)
            spin.concat()
            let over = d * 2
            style.scheduled.setFill()
            NSRect(x: dot.midX - over, y: dot.midY - over, width: over, height: over * 2).fill()
            style.dynamic.setFill()
            NSRect(x: dot.midX, y: dot.midY - over, width: over, height: over * 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        guard style.outline else { return }
        NSColor.labelColor.setStroke()
        let stroke = NSBezierPath(ovalIn: dot.insetBy(dx: ring / 2, dy: ring / 2))
        stroke.lineWidth = ring
        stroke.stroke()
    }

    /// A yellow caution triangle in the bottom-right corner, sitting in a gap
    /// punched out of the lizard so the two shapes don't read as one blob.
    ///
    /// The two palette colors map to the symbol's mark and triangle layers in
    /// that order, giving an opaque badge with a dark exclamation. Tinting the
    /// plain symbol instead would leave the mark as negative space, which loses
    /// contrast against a light menu bar.
    private static func drawCautionBadge(in rect: NSRect, basis: CGFloat? = nil,
                                         cornerInset: CGFloat = 0) {
        let config = NSImage.SymbolConfiguration(paletteColors: [.black, .systemYellow])
        guard let warning = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                    accessibilityDescription: nil)?
                                .withSymbolConfiguration(config) else { return }
        let height = basis ?? rect.height
        let side = height * 0.62
        // Bottom-right corner (rect is unflipped, so minY is the bottom).
        let badge = NSRect(x: rect.maxX - side - cornerInset, y: rect.minY + cornerInset,
                           width: side, height: side)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        NSBezierPath(ovalIn: badge.insetBy(dx: -height * 0.06, dy: -height * 0.06)).fill()
        NSGraphicsContext.restoreGraphicsState()

        warning.draw(in: badge)
    }

    // MARK: - NSView tooltip owner

    /// Called by AppKit each time the status-item tooltip is about to appear,
    /// so the string is always current. Empty string suppresses the tooltip.
    @objc func view(_ view: NSView,
                    stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint,
                    userData: UnsafeMutableRawPointer?) -> String {
        // The caution badge says "off deliberately"; the tooltip is where the
        // user finds out until when. Phrased as a statement — `suppressTitle()`
        // is the menu command, which reads as an instruction here.
        if sleep.isSuppressed {
            let until = sleep.suppressedUntil.flatMap { $0 < .distantFuture ? $0 : nil }
                .map { " until \(SleepManager.clockString($0))" } ?? ""
            return "Suppressed\(until) — nothing is keeping your Mac awake"
        }
        if let blocked = sleep.blockedByBattery {
            return "Held off — battery \(blocked.percent)% is at or below your"
                 + " \(blocked.threshold)% floor"
        }
        // Every contributor, not just the first: "why is my Mac awake" usually
        // has more than one answer, and the icon alone can't say which.
        let reasons = sleep.awakeReasons()
        guard !reasons.isEmpty else { return "" }
        guard reasons.count > 1 else { return reasons[0] }
        return (["Keeping your Mac awake:"] + reasons.map { "  • \($0)" }).joined(separator: "\n")
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        updateIdleHide()
        // One menu opening of visibility, then retire. Messages are often posted
        // while the menu is closed, so clearing outright would mean never seen —
        // but keeping them resurfaces stale errors hours later.
        if !messageItem.isHidden {
            if messageSeen { clearMessage() } else { messageSeen = true }
        }
        // Tick the remaining-time label live while the menu is shown.
        // .common mode includes NSEventTracking so the timer fires during
        // menu tracking — without it the label would freeze the moment the
        // menu opened.
        menuTickTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        menuTickTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        restartIdleHideCountdown()
        menuTickTimer?.invalidate()
        menuTickTimer = nil
        // If the user was mid-drag and the mouse left the menu, the slider's
        // mouse-up never fires, so commit the slider's current visible value
        // if it diverges from stored state. Then clear the drag flag so the
        // next refresh resumes normal sync.
        let visual = durationSliderView.currentPosition
        if visual != sleep.sliderPosition {
            sleep.setSliderPosition(visual)
        }
        durationSliderView.endDragIfNeeded()
        // The "On for" slider moved into the settings window, where a window
        // closing mid-drag isn't a thing — only the sliders still hosted in the
        // menu need this rescue.
    }
}

// MARK: - Slider views

/// The primary control: a slider whose 11 ticks select keep-awake duration.
/// Position 0 = off, 1–9 = 1 min … 24 h (geometric after the first step),
/// 10 = indefinite. Right label shows current state — "off", remaining time
/// like "1h 23m", or "indefinite".
final class DurationSliderView: NSView {
    private let slider: NSSlider
    private let valueLabel: NSTextField
    private let titleLabel: NSTextField
    private let onChange: (Int) -> Void
    private let textForPosition: (Int) -> String
    /// True between a `.leftMouseDown` and the corresponding `.leftMouseUp`
    /// (or `endDragIfNeeded()` if the menu closes mid-drag). While set, the
    /// label and thumb are owned by the live drag — external `refresh()`
    /// skips them so the menu's 1Hz tick timer can't snap the thumb back.
    private var isDragging = false

    init(title: String = "Keep awake",
         initialPosition: Int, initialText: String,
         textForPosition: @escaping (Int) -> String,
         onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        self.textForPosition = textForPosition
        self.slider = NSSlider(value: Double(initialPosition),
                               minValue: 0,
                               maxValue: Double(SleepManager.sliderDurations.count - 1),
                               target: nil, action: nil)
        self.valueLabel = NSTextField(labelWithString: initialText)
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 44))

        let font = NSFont.menuFont(ofSize: 0)
        titleLabel.font = font
        titleLabel.textColor = .secondaryLabelColor
        // "Keep awake" measures ~72pt; the slack goes to the value label, which
        // now carries both a duration and a clock time.
        titleLabel.frame = NSRect(x: 14, y: 24, width: 76, height: 16)
        addSubview(titleLabel)

        valueLabel.font = font
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.frame = NSRect(x: 90, y: 24, width: 136, height: 16)
        // Labels clip without an ellipsis by default; truncating the head keeps
        // the end time and "+1" marker, which matter more than the leading digits.
        valueLabel.lineBreakMode = .byTruncatingHead
        addSubview(valueLabel)

        // Continuous so the action fires on every tick crossed during drag —
        // the handler shows a live preview in the value label. Commit (the
        // expensive `onChange` that touches the helper / IOPMAssertions) is
        // gated on mouse-up via `NSApp.currentEvent.type` so a drag across
        // positions still results in exactly one commit at release.
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.numberOfTickMarks = SleepManager.sliderDurations.count
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.frame = NSRect(x: 14, y: 4, width: 212, height: 18)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { nil }

    /// The slider's live integer position. Updates continuously during a drag.
    var currentPosition: Int { slider.integerValue }

    /// Sync from external state (e.g. expiry timer fired → slider returns to 0,
    /// or battery dropped below the floor → slider goes disabled). Skipped for
    /// thumb/label while a drag is in progress so we don't fight the user.
    func refresh(position: Int, displayText: String, enabled: Bool) {
        slider.isEnabled = enabled
        let color: NSColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
        titleLabel.textColor = color
        valueLabel.textColor = color
        guard !isDragging else { return }
        if slider.integerValue != position {
            slider.integerValue = position
        }
        valueLabel.stringValue = displayText
    }

    /// Called by `menuDidClose` after committing the visual position — clears
    /// the drag flag so the next `refresh()` resumes normal syncing. If the
    /// menu closed mid-drag the mouse-up event never reached us.
    func endDragIfNeeded() {
        isDragging = false
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let pos = Int(sender.doubleValue.rounded())
        sender.integerValue = pos
        // Always reflect the would-be value in the label, even mid-drag.
        valueLabel.stringValue = textForPosition(pos)
        // Mouse-driven drag fires action with .leftMouseDown / .leftMouseDragged
        // during the drag and .leftMouseUp on release. Keyboard arrows arrive
        // as .keyDown and should commit on each press (matches prior behavior).
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged:
            isDragging = true
        default:
            isDragging = false
            onChange(pos)
        }
    }
}

/// A dual-thumb range slider hosted in an NSMenuItem: picks the time-of-day
/// window (half-hour steps, 0…48 → 00:00…24:00) during which "Keep display on"
/// applies. NSSlider can't do two thumbs, so this is custom-drawn. Commits on
/// mouse-up like DurationSliderView; refresh skips the thumbs mid-drag.
final class RangeSliderView: NSView {
    private let titleLabel: NSTextField
    private let valueLabel: NSTextField
    private let onChange: (Int, Int) -> Void

    private var start: Int
    private var end: Int
    private var enabled = true
    private var isDragging = false
    private enum Thumb { case start, end }
    private var activeThumb: Thumb = .start

    // Indented from the menu's left edge so the bar visually tucks under
    // "Keep display on", matching the indented "Pause on battery" item below it.
    private let trackMinX: CGFloat = 30
    private let trackMaxX: CGFloat = 224
    private let centerY: CGFloat = 13
    private let thumbR: CGFloat = 8   // ~16pt knob, matching the system slider
    private static let steps = 48   // 48 half-hours across 0…24h

    init(initialStart: Int, initialEnd: Int,
         onChange: @escaping (Int, Int) -> Void) {
        self.start = initialStart
        self.end = initialEnd
        self.onChange = onChange
        self.titleLabel = NSTextField(labelWithString: "Display hours")
        self.valueLabel = NSTextField(labelWithString: "")
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 44))

        let font = NSFont.menuFont(ofSize: 0)
        titleLabel.font = font
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 28, y: 24, width: 100, height: 16)
        addSubview(titleLabel)

        valueLabel.font = font
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.frame = NSRect(x: 110, y: 24, width: 116, height: 16)
        addSubview(valueLabel)
        updateLabel()
    }

    required init?(coder: NSCoder) { nil }

    /// Live thumb positions (half-hour indices), updated continuously on drag.
    var currentStart: Int { start }
    var currentEnd: Int { end }

    /// Sync from external state; greys out when disabled. Skips thumbs/label
    /// while dragging so the menu's 1Hz tick can't fight the user.
    func refresh(start: Int, end: Int, enabled: Bool) {
        self.enabled = enabled
        let color: NSColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
        titleLabel.textColor = color
        valueLabel.textColor = color
        guard !isDragging else { return }
        self.start = start
        self.end = end
        updateLabel()
        needsDisplay = true
    }

    func endDragIfNeeded() { isDragging = false }

    // MARK: drawing

    private func x(_ idx: Int) -> CGFloat {
        trackMinX + CGFloat(idx) / CGFloat(Self.steps) * (trackMaxX - trackMinX)
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackH: CGFloat = 4
        // Groove.
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect:
            NSRect(x: trackMinX, y: centerY - trackH / 2, width: trackMaxX - trackMinX, height: trackH),
            xRadius: trackH / 2, yRadius: trackH / 2).fill()
        // Selected range fill.
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect:
            NSRect(x: x(start), y: centerY - trackH / 2, width: x(end) - x(start), height: trackH),
            xRadius: trackH / 2, yRadius: trackH / 2).fill()
        // Knobs — control-face circle with a soft shadow + hairline ring, the
        // way the system slider knob reads on the menu.
        for cx in [x(start), x(end)] {
            let rect = NSRect(x: cx - thumbR, y: centerY - thumbR, width: thumbR * 2, height: thumbR * 2)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.shadowColor.withAlphaComponent(0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -0.5)
            shadow.shadowBlurRadius = 1.5
            shadow.set()
            NSColor.controlColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25))
            ring.lineWidth = 0.5
            ring.stroke()
        }
    }

    // MARK: mouse (commit on mouse-up)

    private func index(at point: NSPoint) -> Int {
        let frac = (point.x - trackMinX) / (trackMaxX - trackMinX)
        return max(0, min(Self.steps, Int((frac * CGFloat(Self.steps)).rounded())))
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        let i = index(at: convert(event.locationInWindow, from: nil))
        activeThumb = abs(i - start) <= abs(i - end) ? .start : .end
        isDragging = true
        moveActive(to: i)
    }

    override func mouseDragged(with event: NSEvent) {
        guard enabled, isDragging else { return }
        moveActive(to: index(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onChange(start, end)
    }

    private func moveActive(to i: Int) {
        switch activeThumb {
        case .start: start = max(0, min(end - 1, i))
        case .end:   end = max(start + 1, min(Self.steps, i))
        }
        updateLabel()
        needsDisplay = true
    }

    private func updateLabel() { valueLabel.stringValue = Self.windowLabel(start, end) }

    static func windowLabel(_ s: Int, _ e: Int) -> String {
        if s == 0 && e == steps { return "All day" }
        return "\(hhmm(s))–\(hhmm(e))"
    }
    private static func hhmm(_ idx: Int) -> String {
        String(format: "%d:%02d", idx / 2, (idx % 2) * 30)
    }
}

/// A small NSView hosted inside an NSMenuItem: label + slider for the
/// battery-percent floor at which Newt auto-releases keep-awake.
/// Range 0…30; 0 reads as "off" (hold until the Mac dies).
final class BatterySliderView: NSView {
    private let slider: NSSlider
    private let valueLabel: NSTextField
    private let titleLabel: NSTextField
    private let onChange: (Int) -> Void

    init(initialValue: Int, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        self.slider = NSSlider(value: Double(initialValue),
                               minValue: 0, maxValue: 30,
                               target: nil, action: nil)
        self.valueLabel = NSTextField(labelWithString: "")
        self.titleLabel = NSTextField(labelWithString: "Low battery cutoff")
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 44))

        let font = NSFont.menuFont(ofSize: 0)
        titleLabel.font = font
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.frame = NSRect(x: 14, y: 24, width: 170, height: 16)
        addSubview(titleLabel)

        valueLabel.font = font
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.frame = NSRect(x: 170, y: 24, width: 56, height: 16)
        addSubview(valueLabel)

        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.numberOfTickMarks = 7    // 0, 5, 10, 15, 20, 25, 30
        slider.allowsTickMarkValuesOnly = false
        slider.frame = NSRect(x: 14, y: 4, width: 212, height: 18)
        addSubview(slider)

        updateLabel(initialValue)
    }

    required init?(coder: NSCoder) { nil }

    /// Sync from external state changes (e.g. another source updates the
    /// threshold). Avoids a feedback loop with `onChange`.
    func refresh(value: Int) {
        if slider.integerValue != value {
            slider.integerValue = value
        }
        updateLabel(value)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let v = Int(sender.doubleValue.rounded())
        sender.integerValue = v
        updateLabel(v)
        onChange(v)
    }

    private func updateLabel(_ v: Int) {
        valueLabel.stringValue = v == 0 ? "off" : "\(v)%"
    }
}
