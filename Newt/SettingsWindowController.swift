import AppKit
import Sparkle

/// Newt's settings, in tabs. Everything you set once and forget lives here; the
/// menu keeps only what you act on day to day.
///
/// Every control writes straight through to `SleepManager` as you change it —
/// there is no OK or Apply, matching the menus and the schedule grid. The menu
/// and this window show some of the same settings, so both are refreshed from
/// the same place: `StatusItemController.refresh()`.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    private let sleep: SleepManager
    private let login: LoginItemController
    private let updater: SPUUpdaterProviding

    /// Called when expiry notifications are switched on, so the controller can
    /// request permission — it owns the `NotificationManager` and the alert.
    var onExpiryNotificationsEnabled: (() -> Void)?

    /// Installing hooks edits someone else's settings file, so the controller
    /// runs the confirm-and-report flow rather than duplicating it here.
    var onToggleIntegration: ((String) -> Void)?

    // General
    private let loginBox = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    private let resumeBox = NSButton(checkboxWithTitle: "Resume last state at launch",
                                     target: nil, action: nil)
    private let autoUpdateBox = NSButton(checkboxWithTitle: "Check for updates automatically",
                                         target: nil, action: nil)
    /// Only on Macs that have a battery to run down.
    private var batterySlider: BatterySliderView?
    private var claimLifetimeSlider: DurationSliderView!
    private var hideIconSlider: DurationSliderView!

    // Schedule
    private let scheduleBox = NSButton(checkboxWithTitle: "Follow this schedule",
                                       target: nil, action: nil)
    private let grid: ScheduleGridView

    // Wake modes
    private var wakeModeBoxes: [WakeMode: NSButton] = [:]
    private var displayHoursSlider: RangeSliderView!
    private let pauseOnBatteryBox = NSButton(checkboxWithTitle: "Pause on battery",
                                             target: nil, action: nil)

    // Integrations
    private var integrationBoxes: [String: NSButton] = [:]

    // Left click
    private var leftClickButtons: [LeftClickAction: NSButton] = [:]
    private var fixedSlider: DurationSliderView!

    // Notifications
    private let expiryBox = NSButton(checkboxWithTitle: "Notify when keep-awake expires",
                                     target: nil, action: nil)
    private let dotBox = NSButton(checkboxWithTitle: "Show an indicator dot while awake",
                                  target: nil, action: nil)
    private let outlineBox = NSButton(checkboxWithTitle: "Outline the dot so it stands out",
                                      target: nil, action: nil)
    private let spinBox = NSButton(checkboxWithTitle: "Spin it when both are holding",
                                   target: nil, action: nil)
    private let sizeSlider = NSSlider(value: 0.46, minValue: 0.30, maxValue: 0.70,
                                      target: nil, action: nil)
    // Icon — idle and awake are the same three controls twice over.
    private let idleBackdropPopup = NSPopUpButton()
    private let awakeBackdropPopup = NSPopUpButton()
    private let idleBackdropWell = NSColorWell()
    private let awakeBackdropWell = NSColorWell()
    private let idleIconWell = NSColorWell()
    private let awakeIconWell = NSColorWell()
    private let idleCutoutBox = NSButton(checkboxWithTitle: "Cut out", target: nil, action: nil)
    private let awakeCutoutBox = NSButton(checkboxWithTitle: "Cut out", target: nil, action: nil)
    private let iconPreview = NSImageView()
    private var automaticButtons: [String: NSButton] = [:]
    /// Held so the spin timer can tell whether its preview is on screen.
    private var tabs: NSTabView!
    private let scheduledWell = NSColorWell()
    private let dynamicWell = NSColorWell()
    private let resetColorsButton = NSButton(title: "Use Automatic Colours",
                                             target: nil, action: nil)
    /// Spins the preview's split dot so the setting can be judged here rather
    /// than by squinting at the menu bar. Runs only while this window is on
    /// screen — `windowWillClose` and every `refresh()` re-check that.
    private var previewSpinTimer: Timer?
    private var previewAngle: Double = 0

    private static let contentSize = NSSize(width: 600, height: 560)

    init(sleep: SleepManager, login: LoginItemController, updater: SPUUpdaterProviding) {
        self.sleep = sleep
        self.login = login
        self.updater = updater
        self.grid = ScheduleGridView(schedule: sleep.schedule, enabled: sleep.scheduleEnabled)

        let content = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        let window = NSWindow(contentRect: content.frame,
                              // Not resizable: every view here uses a hardcoded
                              // frame, as elsewhere in Newt.
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Newt Settings"
        window.contentView = content
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let tabs = NSTabView(frame: content.bounds.insetBy(dx: 12, dy: 12))
        self.tabs = tabs
        tabs.delegate = self
        tabs.addTabViewItem(tab("General", generalView()))
        tabs.addTabViewItem(tab("Wake Modes", wakeModesView()))
        tabs.addTabViewItem(tab("Icon", iconView()))
        tabs.addTabViewItem(tab("Schedule", scheduleView()))
        tabs.addTabViewItem(tab("Left Click", leftClickView()))
        tabs.addTabViewItem(tab("Integrations", integrationsView()))
        content.addSubview(tabs)

        window.delegate = self
        windowFrameAutosaveName = "NewtSettingsWindow"
        // The autosaved frame carries the height this window used to be, and it
        // isn't resizable, so restoring it wholesale would clip the last control
        // on the tallest tab. Position is worth keeping; size isn't.
        window.setContentSize(Self.contentSize)
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    /// Wraps a tab's fixed-height layout in a container that pins it to the top.
    /// Tab views are stretched to the tab view's content rect, and every layout
    /// here uses absolute frames — so without this the shorter tabs would be
    /// pushed to the bottom of the window by whichever tab is tallest.
    private func tab(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        let container = NSView(frame: view.bounds)
        view.autoresizingMask = [.minYMargin]
        container.addSubview(view)
        item.view = container
        return item
    }

    /// Bring settings forward. An accessory app is never frontmost, so the
    /// activate call is what makes the window usable rather than just visible.
    func show(selecting tab: String? = nil) {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let tab { tabs.selectTabViewItem(withIdentifier: tab) }
    }

    /// Pull state back from `SleepManager` — the menu carries some of the same
    /// settings, and `refresh()` runs at 1 Hz while the menu is open, so this
    /// must be cheap and must not disturb a control being dragged.
    func refresh() {
        loginBox.state = login.isEnabled ? .on : .off
        resumeBox.state = sleep.resumeOnLaunch ? .on : .off
        autoUpdateBox.state = updater.automaticallyChecksForUpdates ? .on : .off
        batterySlider?.refresh(value: sleep.batteryThresholdPercent)
        claimLifetimeSlider.refresh(
            position: sleep.dynamicClaimMaxPosition,
            displayText: SleepManager.displayString(forSliderPosition: sleep.dynamicClaimMaxPosition),
            enabled: true)
        hideIconSlider.refresh(
            position: sleep.hideIconAfterPosition,
            displayText: SleepManager.hideIconDisplayString(
                forSliderPosition: sleep.hideIconAfterPosition),
            enabled: true)

        for (mode, box) in wakeModeBoxes {
            box.state = sleep.isEnabled(mode) ? .on : .off
        }
        // Both only apply to "Keep display on", so they follow it in and out of
        // the layout rather than leaving a gap.
        layoutWakeModes()
        pauseOnBatteryBox.state = sleep.pauseDisplayOnBattery ? .on : .off
        displayHoursSlider.refresh(start: sleep.displayWindowStart,
                                   end: sleep.displayWindowEnd, enabled: true)

        for agent in IntegrationInstaller.all {
            integrationBoxes[agent.id]?.state = IntegrationInstaller.isInstalled(agent) ? .on : .off
        }

        scheduleBox.state = sleep.scheduleEnabled ? .on : .off
        grid.refresh(schedule: sleep.schedule, enabled: sleep.scheduleEnabled)

        for (action, button) in leftClickButtons {
            button.state = sleep.leftClickAction == action ? .on : .off
        }
        fixedSlider.refresh(
            position: sleep.fixedClickSliderPosition,
            displayText: SleepManager.displayString(forSliderPosition: sleep.fixedClickSliderPosition),
            enabled: sleep.leftClickAction == .toggleFixed)

        expiryBox.state = sleep.isNotificationEnabled(.notifyOnExpiry) ? .on : .off
        let dotOn = sleep.isNotificationEnabled(.badgeWhenEngaged)
        dotBox.state = dotOn ? .on : .off
        outlineBox.state = sleep.badgeOutline ? .on : .off
        outlineBox.isEnabled = dotOn
        sizeSlider.isEnabled = dotOn
        spinBox.state = sleep.badgeSpin ? .on : .off
        spinBox.isEnabled = dotOn
        scheduledWell.isEnabled = dotOn
        dynamicWell.isEnabled = dotOn
        resetColorsButton.isEnabled = !sleep.badgeColorsAreDefault
        idleBackdropPopup.selectItem(at: IconBackdrop.allCases.firstIndex(
            of: sleep.idleBackdrop) ?? 0)
        awakeBackdropPopup.selectItem(at: IconBackdrop.allCases.firstIndex(
            of: sleep.awakeBackdrop) ?? 0)
        // A backdrop colour is only meaningful once there is a backdrop.
        idleBackdropWell.isEnabled = sleep.idleBackdrop != .none
        awakeBackdropWell.isEnabled = sleep.awakeBackdrop != .none
        automaticButtons["idleBackdrop"]?.isEnabled = idleBackdropWell.isEnabled
        automaticButtons["awakeBackdrop"]?.isEnabled = awakeBackdropWell.isEnabled
        // Only an opaque backdrop has anything to cut the lizard out of.
        idleCutoutBox.state = sleep.idleCutout ? .on : .off
        awakeCutoutBox.state = sleep.awakeCutout ? .on : .off
        idleCutoutBox.isEnabled = sleep.idleBackdrop == .circle
        awakeCutoutBox.isEnabled = sleep.awakeBackdrop == .circle
        for (id, hidden) in [("idleGlyph", sleep.badgeStyle.idle.cutsOut),
                             ("awakeGlyph", sleep.badgeStyle.awake.cutsOut)] {
            automaticButtons[id]?.isHidden = hidden
        }
        idleIconWell.isHidden = sleep.badgeStyle.idle.cutsOut
        awakeIconWell.isHidden = sleep.badgeStyle.awake.cutsOut
        // Don't fight the colour panel while it's open on this well.
        if !idleIconWell.isActive { idleIconWell.color = sleep.idleIconColor ?? .labelColor }
        if !awakeIconWell.isActive { awakeIconWell.color = sleep.awakeIconColor ?? .labelColor }
        if !idleBackdropWell.isActive {
            idleBackdropWell.color = sleep.idleBackdropColor
                ?? StatusItemController.contrasting(to: sleep.idleIconColor ?? .labelColor)
        }
        if !awakeBackdropWell.isActive {
            awakeBackdropWell.color = sleep.awakeBackdropColor
                ?? StatusItemController.contrasting(to: sleep.awakeIconColor ?? .labelColor)
        }
        if !scheduledWell.isActive { scheduledWell.color = sleep.badgeStyle.scheduled }
        if !dynamicWell.isActive { dynamicWell.color = sleep.badgeStyle.dynamic }
        refreshIconPreview()
        if sizeSlider.doubleValue != sleep.badgeSizeScale {
            sizeSlider.doubleValue = sleep.badgeSizeScale
        }
        updatePreviewSpin()
    }

    /// Mirrors the status item's rule: only the two-tone dot has anything to
    /// show, so only that state animates.
    private func updatePreviewSpin() {
        let wanted = (window?.isVisible ?? false)
            && (tabs?.selectedTabViewItem?.identifier as? String) == "Icon"
            && sleep.isNotificationEnabled(.badgeWhenEngaged)
            && sleep.badgeSpin
        guard wanted else {
            previewSpinTimer?.invalidate()
            previewSpinTimer = nil
            previewAngle = 0
            return
        }
        guard previewSpinTimer == nil else { return }
        let steps = 36.0, secondsPerTurn = 4.5
        let timer = Timer(timeInterval: secondsPerTurn / steps, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.previewAngle = (self.previewAngle + (2 * .pi) / steps)
                .truncatingRemainder(dividingBy: 2 * .pi)
            self.refreshIconPreview()
        }
        RunLoop.main.add(timer, forMode: .common)
        previewSpinTimer = timer
    }

    func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        // The preview only animates while it's the tab on screen.
        updatePreviewSpin()
    }

    func windowWillClose(_ notification: Notification) {
        previewSpinTimer?.invalidate()
        previewSpinTimer = nil
    }

    // MARK: - General

    private func generalView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 446))
        let sliderHeight = 44.0, gapBeforeHint = 6.0, gapAfterHint = 20.0
        var top = 424.0

        for box in [loginBox, resumeBox, autoUpdateBox] {
            box.target = self
            box.action = #selector(generalChanged)
            box.frame = NSRect(x: 20, y: top - 20, width: 480, height: 20)
            view.addSubview(box)
            top -= 26
        }
        expiryBox.target = self
        expiryBox.action = #selector(expiryToggled)
        expiryBox.frame = NSRect(x: 20, y: top - 20, width: 480, height: 20)
        view.addSubview(expiryBox)
        top -= 26
        top -= 12

        // Desktops have nothing to run down, so the cutoff would be meaningless.
        if sleep.hasBattery {
            let slider = BatterySliderView(initialValue: sleep.batteryThresholdPercent) {
                [weak self] value in self?.sleep.batteryThresholdPercent = value
            }
            slider.frame.origin = NSPoint(x: 20, y: top - sliderHeight)
            view.addSubview(slider)
            batterySlider = slider
            top -= sliderHeight + gapBeforeHint
            top = addHint("On battery, Newt lets go at this level so macOS can sleep before the "
                          + "battery runs flat, then picks up again once you plug in. "
                          + "0% turns it off.",
                          to: view, top: top) - gapAfterHint
        }

        // "Max claim life" overruns the slider's 100pt title label.
        claimLifetimeSlider = DurationSliderView(
            title: "Claim limit",
            initialPosition: sleep.dynamicClaimMaxPosition,
            initialText: SleepManager.displayString(forSliderPosition: sleep.dynamicClaimMaxPosition),
            textForPosition: { SleepManager.displayString(forSliderPosition: $0) }
        ) { [weak self] position in
            self?.sleep.dynamicClaimMaxPosition = position
            self?.refresh()
        }
        claimLifetimeSlider.frame.origin = NSPoint(x: 20, y: top - sliderHeight)
        view.addSubview(claimLifetimeSlider)
        top -= sliderHeight + gapBeforeHint

        top = addHint("A backstop for dynamic claims: if an agent never releases one — a subagent, "
                      + "a state we don't model, or just sitting waiting for an answer — Newt lets "
                      + "go after this long, so a runaway can't flatten your battery. "
                      + "Off means no limit.",
                      to: view, top: top) - gapAfterHint

        hideIconSlider = DurationSliderView(
            title: "Hide icon",
            initialPosition: sleep.hideIconAfterPosition,
            initialText: SleepManager.hideIconDisplayString(
                forSliderPosition: sleep.hideIconAfterPosition),
            textForPosition: { SleepManager.hideIconDisplayString(forSliderPosition: $0) }
        ) { [weak self] position in
            self?.sleep.hideIconAfterPosition = position
            self?.refresh()
        }
        hideIconSlider.frame.origin = NSPoint(x: 20, y: top - sliderHeight)
        view.addSubview(hideIconSlider)
        top -= sliderHeight + gapBeforeHint

        addHint("Once nothing has held the Mac awake for this long, Newt takes its icon out "
                + "of the menu bar. Open Newt again from Applications or Spotlight to bring "
                + "it back.",
                to: view, top: top)
        return view
    }

    @objc private func generalChanged(_ sender: NSButton) {
        switch sender {
        case loginBox:
            if let message = login.setEnabled(loginBox.state == .on) { showError(message) }
        case resumeBox:
            sleep.setResumeOnLaunch(resumeBox.state == .on)
        default:
            updater.automaticallyChecksForUpdates = autoUpdateBox.state == .on
        }
        refresh()
    }

    // MARK: - Wake modes

    private func wakeModesView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 326))
        let title = NSTextField(labelWithString: "Prevent these kinds of sleep:")
        title.frame = NSRect(x: 20, y: 274, width: 400, height: 18)
        view.addSubview(title)

        for mode in WakeMode.allCases {
            let box = NSButton(checkboxWithTitle: mode.menuTitle, target: self,
                               action: #selector(wakeModeChanged(_:)))
            box.frame = NSRect(x: 28, y: 0, width: 480, height: 20)
            view.addSubview(box)
            wakeModeBoxes[mode] = box

            // Display hours and Pause on battery configure "Keep display on"
            // specifically, so they sit indented beneath it — and disappear
            // with it, which is why the rows are positioned in
            // `layoutWakeModes()` rather than here.
            if mode == .display {
                displayHoursSlider = RangeSliderView(
                    initialStart: sleep.displayWindowStart,
                    initialEnd: sleep.displayWindowEnd
                ) { [weak self] start, end in
                    self?.sleep.setDisplayWindow(start: start, end: end)
                }
                view.addSubview(displayHoursSlider)

                pauseOnBatteryBox.target = self
                pauseOnBatteryBox.action = #selector(pauseOnBatteryChanged)
                pauseOnBatteryBox.frame = NSRect(x: 48, y: 0, width: 440, height: 20)
                view.addSubview(pauseOnBatteryBox)
            }
        }
        layoutWakeModes()
        addHint("Turning every mode off leaves Newt with nothing to do — it will "
                + "refuse to hold your Mac awake until at least one is back on.",
                to: view, top: 60)
        return view
    }

    /// Stack the rows top-down, skipping any that are hidden. Fixed frames
    /// would leave a hole where "Display hours" and "Pause on battery" sit when
    /// "Keep display on" is off.
    private func layoutWakeModes() {
        let displayOn = sleep.isEnabled(.display)
        var y = 246.0
        for mode in WakeMode.allCases {
            guard let box = wakeModeBoxes[mode] else { continue }
            box.frame.origin.y = y
            y -= 28
            guard mode == .display else { continue }
            displayHoursSlider.isHidden = !displayOn
            pauseOnBatteryBox.isHidden = !displayOn || !sleep.hasBattery
            if !displayHoursSlider.isHidden {
                displayHoursSlider.frame.origin = NSPoint(x: 36, y: y - 24)
                y -= 46
            }
            if !pauseOnBatteryBox.isHidden {
                pauseOnBatteryBox.frame.origin.y = y
                y -= 28
            }
        }
    }

    @objc private func wakeModeChanged(_ sender: NSButton) {
        guard let mode = wakeModeBoxes.first(where: { $0.value == sender })?.key else { return }
        sleep.setMode(mode, enabled: sender.state == .on)
        refresh()
    }

    @objc private func pauseOnBatteryChanged() {
        sleep.setPauseDisplayOnBattery(pauseOnBatteryBox.state == .on)
        refresh()
    }

    // MARK: - Integrations

    private func integrationsView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 326))
        let title = NSTextField(labelWithString: "Register dynamic claims with common tools:")
        title.frame = NSRect(x: 20, y: 274, width: 480, height: 18)
        view.addSubview(title)

        for (i, agent) in IntegrationInstaller.all.enumerated() {
            let box = NSButton(checkboxWithTitle: agent.name, target: self,
                               action: #selector(integrationChanged(_:)))
            box.frame = NSRect(x: 28, y: 240 - CGFloat(i) * 28, width: 300, height: 20)
            view.addSubview(box)
            integrationBoxes[agent.id] = box
        }

        addHint("Ticking one lets that tool tell Newt when it starts and stops working, so "
                + "your Mac stays awake through a long run and sleeps normally afterwards. "
                + "Newt only ever touches what it added, and unticking takes it back out.",
                to: view, top: 174)
        return view
    }

    @objc private func integrationChanged(_ sender: NSButton) {
        guard let id = integrationBoxes.first(where: { $0.value == sender })?.key else { return }
        // The controller runs the confirm-and-report flow; refresh() puts the
        // box back if the user cancels out of it.
        onToggleIntegration?(id)
        refresh()
    }

    // MARK: - Schedule

    private func scheduleView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 326))
        scheduleBox.target = self
        scheduleBox.action = #selector(scheduleToggled)
        scheduleBox.frame = NSRect(x: 20, y: 274, width: 300, height: 20)
        view.addSubview(scheduleBox)

        grid.frame = NSRect(x: 20, y: 30, width: grid.frame.width, height: grid.frame.height)
        grid.onChange = { [weak self] schedule in self?.sleep.setSchedule(schedule) }
        view.addSubview(grid)

        addHint("Drag on a row to add hours; drag a block or its edges to adjust. "
                + "Drag a block's right edge into the row below to run it overnight. "
                + "Select a block and press Delete to remove it.",
                to: view, top: 34)
        return view
    }

    @objc private func scheduleToggled() {
        sleep.setScheduleEnabled(scheduleBox.state == .on)
    }

    // MARK: - Left click

    private func leftClickView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 326))
        let title = NSTextField(labelWithString: "Clicking the menu bar icon:")
        title.frame = NSRect(x: 20, y: 274, width: 400, height: 18)
        view.addSubview(title)

        for (i, action) in LeftClickAction.allCases.enumerated() {
            let button = NSButton(radioButtonWithTitle: action.menuTitle,
                                  target: self, action: #selector(leftClickChanged(_:)))
            button.frame = NSRect(x: 28, y: 244 - CGFloat(i) * 26, width: 480, height: 20)
            view.addSubview(button)
            leftClickButtons[action] = button
        }

        // The menu's own "On for" slider, reused unchanged — it's a plain NSView
        // with a fixed frame, so it drops into a window as happily as a menu item.
        fixedSlider = DurationSliderView(
            title: "On for",
            initialPosition: sleep.fixedClickSliderPosition,
            initialText: SleepManager.displayString(forSliderPosition: sleep.fixedClickSliderPosition),
            textForPosition: { SleepManager.displayString(forSliderPosition: $0) }
        ) { [weak self] pos in
            self?.sleep.fixedClickSliderPosition = max(1, pos)
            self?.refresh()
        }
        fixedSlider.frame.origin = NSPoint(x: 28, y: 130)
        view.addSubview(fixedSlider)

        addHint("Right-clicking the icon always opens the menu.", to: view, top: 114)
        return view
    }

    @objc private func leftClickChanged(_ sender: NSButton) {
        guard let action = leftClickButtons.first(where: { $0.value == sender })?.key else { return }
        sleep.setLeftClickAction(action)
        refresh()
    }

    // MARK: - Icon

    /// Everything about how the menu bar icon looks, in one place: the two
    /// states at the top, the claim dot below, and a preview of the lot over
    /// the real desktop picture.
    private func iconView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 490))
        let idleX = 190.0, awakeX = 360.0

        for (title, x) in [("Idle", idleX), ("While awake", awakeX)] {
            let header = NSTextField(labelWithString: title)
            header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            header.frame = NSRect(x: x, y: 450, width: 160, height: 18)
            view.addSubview(header)
        }

        func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat = 165) {
            let field = NSTextField(labelWithString: text)
            field.frame = NSRect(x: x, y: y, width: width, height: 18)
            view.addSubview(field)
        }

        label("Backdrop", x: 20, y: 418)
        for (popup, x) in [(idleBackdropPopup, idleX), (awakeBackdropPopup, awakeX)] {
            popup.removeAllItems()
            popup.addItems(withTitles: IconBackdrop.allCases.map(\.menuTitle))
            popup.frame = NSRect(x: x, y: 414, width: 150, height: 25)
            popup.target = self
            popup.action = #selector(backdropChanged(_:))
            view.addSubview(popup)
        }

        // A colour well can't express "unset", so without an explicit Automatic
        // there is no way back to the adaptive default once you've picked a
        // colour, and the light/dark behaviour would be lost for good.
        func well(_ colorWell: NSColorWell, id: String, x: CGFloat, y: CGFloat) {
            colorWell.identifier = .init(id)
            colorWell.frame = NSRect(x: x, y: y, width: 44, height: 24)
            colorWell.target = self
            colorWell.action = #selector(colorChanged(_:))
            view.addSubview(colorWell)
            let auto = NSButton(title: "Automatic", target: self,
                                action: #selector(resetOneColor(_:)))
            auto.bezelStyle = .rounded
            auto.controlSize = .small
            auto.font = .systemFont(ofSize: 11)
            auto.frame = NSRect(x: x + 50, y: y + 1, width: 84, height: 22)
            auto.identifier = .init(id)
            automaticButtons[id] = auto
            view.addSubview(auto)
        }

        label("Backdrop colour", x: 20, y: 384)
        well(idleBackdropWell, id: "idleBackdrop", x: idleX, y: 380)
        well(awakeBackdropWell, id: "awakeBackdrop", x: awakeX, y: 380)
        label("Lizard colour", x: 20, y: 350)
        well(idleIconWell, id: "idleGlyph", x: idleX, y: 346)
        well(awakeIconWell, id: "awakeGlyph", x: awakeX, y: 346)

        // Cut out replaces the lizard's colour rather than joining it: the
        // wallpaper is what shows through, so there is nothing left to pick.
        for (box, x) in [(idleCutoutBox, idleX), (awakeCutoutBox, awakeX)] {
            box.target = self
            box.action = #selector(cutoutChanged(_:))
            box.frame = NSRect(x: x, y: 318, width: 160, height: 20)
            view.addSubview(box)
        }

        let dotHeader = NSTextField(labelWithString: "Indicator dot")
        dotHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        dotHeader.frame = NSRect(x: 20, y: 282, width: 300, height: 18)
        view.addSubview(dotHeader)

        for (box, y, x) in [(dotBox, 256.0, 20.0), (outlineBox, 232.0, 40.0),
                            (spinBox, 210.0, 40.0)] {
            box.target = self
            box.action = #selector(dotSettingChanged)
            box.frame = NSRect(x: x, y: y, width: 480, height: 20)
            view.addSubview(box)
        }

        label("Size", x: 40, y: 184, width: 40)
        sizeSlider.target = self
        sizeSlider.action = #selector(dotSettingChanged)
        sizeSlider.isContinuous = true
        sizeSlider.frame = NSRect(x: 80, y: 182, width: 180, height: 20)
        view.addSubview(sizeSlider)

        // The colour carries meaning — which claim is holding — so the wells are
        // labelled by what they mean, not "colour 1" and "colour 2".
        label("Slider or schedule", x: 40, y: 156, width: 150)
        well(scheduledWell, id: "scheduled", x: idleX, y: 152)
        label("Dynamic claim", x: 40, y: 124, width: 150)
        well(dynamicWell, id: "dynamic", x: idleX, y: 120)

        // Drawn over the real desktop picture: the whole point of a backdrop is
        // whether the icon survives what is behind the menu bar, and a swatch on
        // this window's own grey can't show that.
        iconPreview.frame = NSRect(x: 20, y: 44, width: 520, height: 64)
        iconPreview.imageScaling = .scaleNone
        iconPreview.wantsLayer = true
        iconPreview.layer?.cornerRadius = 8
        iconPreview.layer?.masksToBounds = true
        view.addSubview(iconPreview)

        resetColorsButton.frame = NSRect(x: 20, y: 8, width: 190, height: 28)
        resetColorsButton.bezelStyle = .rounded
        resetColorsButton.target = self
        resetColorsButton.action = #selector(resetColors)
        view.addSubview(resetColorsButton)
        return view
    }

    @objc private func cutoutChanged(_ sender: NSButton) {
        if sender === idleCutoutBox { sleep.idleCutout = sender.state == .on }
        else { sleep.awakeCutout = sender.state == .on }
        refresh()
    }

    @objc private func backdropChanged(_ sender: NSPopUpButton) {
        let choice = IconBackdrop.allCases[max(0, sender.indexOfSelectedItem)]
        if sender === idleBackdropPopup { sleep.idleBackdrop = choice }
        else { sleep.awakeBackdrop = choice }
        refresh()
    }

    @objc private func resetOneColor(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case "idleBackdrop":  sleep.idleBackdropColor = nil
        case "awakeBackdrop": sleep.awakeBackdropColor = nil
        case "idleGlyph":     sleep.idleIconColor = nil
        case "awakeGlyph":    sleep.awakeIconColor = nil
        case "scheduled":     sleep.scheduledBadgeColor = nil
        default:              sleep.dynamicBadgeColor = nil
        }
        refresh()
    }

    /// The states worth judging, over the desktop picture.
    private func refreshIconPreview() {
        let box = iconPreview.bounds
        let image = NSImage(size: box.size, flipped: false) { rect in
            if let backdrop = self.previewBackdrop(size: rect.size) {
                backdrop.draw(in: rect)
            } else {
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
            }
            // Without the dot, the claim states are indistinguishable from
            // plain "awake" — three identical lizards under three labels.
            let dotOn = self.sleep.isNotificationEnabled(.badgeWhenEngaged)
            var states: [(Bool, StatusItemController.ClaimBadge?)] = [(false, nil), (true, nil)]
            var labels = ["idle", "awake"]
            if dotOn {
                states += [(true, .scheduled), (true, .both)]
                labels += ["+ claim", "+ both"]
            }
            let step = rect.width / Double(states.count)
            for (i, state) in states.enumerated() {
                let mid = step * (Double(i) + 0.5)
                var style = self.sleep.badgeStyle
                if state.1 == .both { style.rotation = self.previewAngle }
                if var icon = StatusItemController.statusImage(
                    active: state.0, badge: state.1, suppressed: false, style: style) {
                    // A template image is black artwork plus an alpha mask — the
                    // status item's *button* applies the menu bar tint, and there
                    // is no button here. Drawn as-is it would come out black.
                    if icon.isTemplate {
                        icon = StatusItemController.tinted(icon, .labelColor)
                    }
                    let h = 22.0, ratio = icon.size.width / icon.size.height
                    icon.draw(in: NSRect(x: mid - h * ratio / 2, y: rect.midY - 3,
                                         width: h * ratio, height: h))
                }
                let caption = NSAttributedString(string: labels[i], attributes: [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor.white])
                // The captions sit on the wallpaper too, and would be just as
                // unreadable as the icon this panel exists to demonstrate.
                let size = caption.size()
                let pill = NSRect(x: mid - size.width / 2 - 5, y: rect.minY + 4,
                                  width: size.width + 10, height: size.height + 2)
                NSColor(white: 0, alpha: 0.55).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
                caption.draw(at: NSPoint(x: mid - size.width / 2, y: rect.minY + 5))
            }
            return true
        }
        image.isTemplate = false
        iconPreview.image = image
    }

    /// The desktop picture cropped to the preview, built once. A 6000×4000
    /// wallpaper costs ~3 ms to rescale and the spin timer redraws 8×/s, so the
    /// scaling is done here rather than per frame — the blit is ~0.1 ms.
    ///
    /// No invalidation, matching `desktopPicture`: both are read once, so
    /// changing your wallpaper shows up the next time Newt starts.
    private func previewBackdrop(size: NSSize) -> NSImage? {
        if let cached = cachedBackdrop, cached.size == size { return cached }
        guard let wallpaper = Self.desktopPicture else { return nil }
        let image = NSImage(size: size, flipped: false) { rect in
            // Anchor the top: the menu bar sits over the top of the picture, so
            // that is the part the icon actually has to survive.
            let scale = max(rect.width / wallpaper.size.width,
                            rect.height / wallpaper.size.height)
            let scaled = NSSize(width: wallpaper.size.width * scale,
                                height: wallpaper.size.height * scale)
            wallpaper.draw(in: NSRect(x: rect.midX - scaled.width / 2,
                                      y: rect.maxY - scaled.height,
                                      width: scaled.width, height: scaled.height))
            return true
        }
        cachedBackdrop = image
        return image
    }

    private var cachedBackdrop: NSImage?

    /// The desktop picture, read once. A dynamic or Photos-managed wallpaper can
    /// fail to load, in which case the preview just falls back to a plain panel.
    private static let desktopPicture: NSImage? = {
        guard let screen = NSScreen.main,
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
    }()

    @objc private func expiryToggled() {
        let on = expiryBox.state == .on
        sleep.setNotificationOption(.notifyOnExpiry, enabled: on)
        if on { onExpiryNotificationsEnabled?() }
        refresh()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        switch sender {
        case idleIconWell:      sleep.idleIconColor = sender.color
        case awakeIconWell:     sleep.awakeIconColor = sender.color
        case idleBackdropWell:  sleep.idleBackdropColor = sender.color
        case awakeBackdropWell: sleep.awakeBackdropColor = sender.color
        case scheduledWell:     sleep.scheduledBadgeColor = sender.color
        default:                sleep.dynamicBadgeColor = sender.color
        }
        refresh()
    }

    @objc private func resetColors() {
        sleep.resetBadgeColors()
        refresh()
    }

    @objc private func dotSettingChanged(_ sender: NSControl) {
        switch sender {
        case dotBox:     sleep.setNotificationOption(.badgeWhenEngaged, enabled: dotBox.state == .on)
        case outlineBox: sleep.badgeOutline = outlineBox.state == .on
        case spinBox:    sleep.badgeSpin = spinBox.state == .on
        default:         sleep.badgeSizeScale = sizeSlider.doubleValue
        }
        refresh()
    }

    // MARK: - Shared bits

    /// Places a hint with its top edge at `top` and returns its bottom edge, so
    /// callers can flow the next control beneath it. Anchoring the top rather
    /// than the bottom keeps the gap above a hint constant however many lines
    /// it wraps to.
    @discardableResult
    private func addHint(_ text: String, to view: NSView, top: CGFloat) -> CGFloat {
        let width = 520.0
        let hint = NSTextField(wrappingLabelWithString: text)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = width
        let height = hint.sizeThatFits(
            NSSize(width: width, height: .greatestFiniteMagnitude)).height
        hint.frame = NSRect(x: 20, y: top - height, width: width, height: height)
        view.addSubview(hint)
        return top - height
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// The slice of Sparkle's updater this window needs. Declared here so the
/// settings window doesn't have to import Sparkle, and so it can be exercised
/// in a harness without a real updater.
protocol SPUUpdaterProviding: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
}

/// Sparkle's updater already has exactly this property; conforming lets the
/// settings window use it without importing Sparkle.
extension SPUUpdater: SPUUpdaterProviding {}
