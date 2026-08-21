import AppKit
import Sparkle

/// Newt's settings, in tabs. Everything you set once and forget lives here; the
/// menu keeps only what you act on day to day.
///
/// Every control writes straight through to `SleepManager` as you change it —
/// there is no OK or Apply, matching the menus and the schedule grid. The menu
/// and this window show some of the same settings, so both are refreshed from
/// the same place: `StatusItemController.refresh()`.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
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
    private let scheduledWell = NSColorWell()
    private let dynamicWell = NSColorWell()
    private let resetColorsButton = NSButton(title: "Use Default Colours",
                                             target: nil, action: nil)
    private let dotPreview = NSImageView()
    /// Spins the preview's split dot so the setting can be judged here rather
    /// than by squinting at the menu bar. Runs only while this window is on
    /// screen — `windowWillClose` and every `refresh()` re-check that.
    private var previewSpinTimer: Timer?
    private var previewAngle: Double = 0

    private static let contentSize = NSSize(width: 600, height: 396)

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
        tabs.addTabViewItem(tab("General", generalView()))
        tabs.addTabViewItem(tab("Wake Modes", wakeModesView()))
        tabs.addTabViewItem(tab("Schedule", scheduleView()))
        tabs.addTabViewItem(tab("Left Click", leftClickView()))
        tabs.addTabViewItem(tab("Integrations", integrationsView()))
        tabs.addTabViewItem(tab("Notifications", notificationsView()))
        content.addSubview(tabs)

        window.delegate = self
        windowFrameAutosaveName = "NewtSettingsWindow"
        window.center()
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    private func tab(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    /// Bring settings forward. An accessory app is never frontmost, so the
    /// activate call is what makes the window usable rather than just visible.
    func show(selecting tab: String? = nil) {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let tab, let tabs = window?.contentView?.subviews.compactMap({ $0 as? NSTabView }).first {
            tabs.selectTabViewItem(withIdentifier: tab)
        }
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
        resetColorsButton.isEnabled = dotOn && !sleep.badgeColorsAreDefault
        // Don't fight the colour panel while it's open on this well.
        if !scheduledWell.isActive { scheduledWell.color = sleep.badgeStyle.scheduled }
        if !dynamicWell.isActive { dynamicWell.color = sleep.badgeStyle.dynamic }
        if sizeSlider.doubleValue != sleep.badgeSizeScale {
            sizeSlider.doubleValue = sleep.badgeSizeScale
        }
        refreshDotPreview()
        updatePreviewSpin()
    }

    /// Mirrors the status item's rule: only the two-tone dot has anything to
    /// show, so only that state animates.
    private func updatePreviewSpin() {
        let wanted = (window?.isVisible ?? false)
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
            self.refreshDotPreview()
        }
        RunLoop.main.add(timer, forMode: .common)
        previewSpinTimer = timer
    }

    func windowWillClose(_ notification: Notification) {
        previewSpinTimer?.invalidate()
        previewSpinTimer = nil
    }

    // MARK: - General

    private func generalView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        let sliderHeight = 44.0, gapBeforeHint = 6.0, gapAfterHint = 20.0
        var top = 304.0

        for box in [loginBox, resumeBox, autoUpdateBox] {
            box.target = self
            box.action = #selector(generalChanged)
            box.frame = NSRect(x: 20, y: top - 20, width: 480, height: 20)
            view.addSubview(box)
            top -= 26
        }
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

        addHint("A backstop for dynamic claims: if an agent never releases one — a subagent, "
                + "a state we don't model, or just sitting waiting for an answer — Newt lets "
                + "go after this long, so a runaway can't flatten your battery. "
                + "Off means no limit.",
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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
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

    // MARK: - Notifications

    private func notificationsView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        expiryBox.target = self
        expiryBox.action = #selector(expiryToggled)
        expiryBox.frame = NSRect(x: 20, y: 274, width: 480, height: 20)
        view.addSubview(expiryBox)

        let dotHeader = NSTextField(labelWithString: "Indicator dot")
        dotHeader.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        dotHeader.frame = NSRect(x: 20, y: 226, width: 300, height: 18)
        view.addSubview(dotHeader)

        dotBox.target = self
        dotBox.action = #selector(dotSettingChanged)
        dotBox.frame = NSRect(x: 20, y: 200, width: 480, height: 20)
        view.addSubview(dotBox)

        outlineBox.target = self
        outlineBox.action = #selector(dotSettingChanged)
        outlineBox.frame = NSRect(x: 40, y: 176, width: 460, height: 20)
        view.addSubview(outlineBox)

        spinBox.target = self
        spinBox.action = #selector(dotSettingChanged)
        spinBox.frame = NSRect(x: 40, y: 154, width: 460, height: 20)
        view.addSubview(spinBox)

        let sizeLabel = NSTextField(labelWithString: "Size")
        sizeLabel.frame = NSRect(x: 40, y: 126, width: 40, height: 18)
        view.addSubview(sizeLabel)
        sizeSlider.target = self
        sizeSlider.action = #selector(dotSettingChanged)
        sizeSlider.isContinuous = true
        sizeSlider.frame = NSRect(x: 80, y: 124, width: 180, height: 20)
        view.addSubview(sizeSlider)

        // The colour carries meaning — which claim is holding — so the wells are
        // labelled by what they mean, not "colour 1" and "colour 2".
        let scheduledLabel = NSTextField(labelWithString: "Slider or schedule")
        scheduledLabel.frame = NSRect(x: 40, y: 96, width: 140, height: 18)
        view.addSubview(scheduledLabel)
        scheduledWell.frame = NSRect(x: 186, y: 92, width: 44, height: 24)
        scheduledWell.target = self
        scheduledWell.action = #selector(colorChanged(_:))
        view.addSubview(scheduledWell)

        let dynamicLabel = NSTextField(labelWithString: "Dynamic claim")
        dynamicLabel.frame = NSRect(x: 40, y: 68, width: 140, height: 18)
        view.addSubview(dynamicLabel)
        dynamicWell.frame = NSRect(x: 186, y: 64, width: 44, height: 24)
        dynamicWell.target = self
        dynamicWell.action = #selector(colorChanged(_:))
        view.addSubview(dynamicWell)

        resetColorsButton.frame = NSRect(x: 240, y: 62, width: 170, height: 28)
        resetColorsButton.bezelStyle = .rounded
        resetColorsButton.target = self
        resetColorsButton.action = #selector(resetColors)
        view.addSubview(resetColorsButton)

        // Live preview, so size and colour can be judged without going up to the
        // menu bar and engaging something.
        dotPreview.frame = NSRect(x: 290, y: 112, width: 200, height: 44)
        dotPreview.imageScaling = .scaleNone
        view.addSubview(dotPreview)

        return view
    }

    @objc private func expiryToggled() {
        let on = expiryBox.state == .on
        sleep.setNotificationOption(.notifyOnExpiry, enabled: on)
        if on { onExpiryNotificationsEnabled?() }
        refresh()
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        if sender === scheduledWell { sleep.scheduledBadgeColor = sender.color }
        else { sleep.dynamicBadgeColor = sender.color }
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

    /// The three dot states side by side at menu bar size, drawn by the same
    /// function the status item uses so the preview can't drift from reality.
    private func refreshDotPreview() {
        let glyph = 18.0, gap = 26.0
        let image = NSImage(size: NSSize(width: gap * 3, height: 22), flipped: false) { _ in
            let badges: [StatusItemController.ClaimBadge] = [.scheduled, .dynamic, .both]
            for (i, badge) in badges.enumerated() {
                var style = self.sleep.badgeStyle
                if badge == .both { style.rotation = self.previewAngle }
                guard let icon = StatusItemController.statusImage(
                    active: true, badge: badge, suppressed: false,
                    style: style) else { continue }
                let ratio = icon.size.width / icon.size.height
                icon.draw(in: NSRect(x: Double(i) * gap, y: 2,
                                     width: glyph * ratio, height: glyph))
            }
            return true
        }
        image.isTemplate = false
        dotPreview.image = image
        dotPreview.alphaValue = sleep.isNotificationEnabled(.badgeWhenEngaged) ? 1 : 0.35
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
