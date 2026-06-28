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
    private var batterySliderView: BatterySliderView?
    private var loginItem: NSMenuItem!
    private var autoUpdateItem: NSMenuItem!
    private var messageItem: NSMenuItem!
    private var wakeModeItems: [WakeMode: NSMenuItem] = [:]
    private var leftClickItems: [LeftClickAction: NSMenuItem] = [:]
    private var fixedClickSliderView: DurationSliderView!
    private var rangeSliderView: RangeSliderView!
    private var rangeSliderItem: NSMenuItem?
    private var pauseOnBatteryItem: NSMenuItem?

    /// Ticks the remaining-time label while the menu is open.
    private var menuTickTimer: Timer?

    /// Workspace wake observer — recreates the status item if macOS reaped it.
    private var wakeObserver: NSObjectProtocol?

    init(updater: SPUStandardUpdaterController) {
        self.updater = updater
        super.init()
        buildMenu()
        menu.delegate = self
        sleep.onChange = { [weak self] in self?.refresh() }
        sleep.onHelperMessage = { [weak self] msg in self?.showMessage(msg) }
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
        refresh()
    }

    /// Wires the status item's button and hover tooltip. Shared by `init` and
    /// `rebuildStatusItem()` so a recreated item behaves identically.
    private func configureStatusItem() {
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
        }
    }

    /// On wake, rebuild the status item only if macOS dropped it. A live item's
    /// button is hosted in an `NSStatusBarWindow`; once reaped it has no window.
    /// Guarding on this avoids needlessly shifting the icon's menu-bar position
    /// on every wake (the common case where nothing was reaped).
    private func handleWake() {
        if statusItem.button?.window == nil { rebuildStatusItem() }
    }

    /// Replaces the reaped status item with a fresh one. The menu, slider views,
    /// and keep-awake state (`sleep`) are independent of the status item and
    /// survive untouched; `configureStatusItem()` re-runs `refresh()` to restore
    /// the correct icon.
    private func rebuildStatusItem() {
        NSStatusBar.system.removeStatusItem(statusItem)
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
        sleep.disengage()
    }

    deinit {
        if let token = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    // MARK: - Menu construction

    private func buildMenu() {
        // Keep-awake slider — the primary control.
        durationSliderView = DurationSliderView(
            initialPosition: sleep.sliderPosition,
            initialText:     sleep.displayString(),
            textForPosition: { SleepManager.displayString(forSliderPosition: $0) }
        ) { [weak self] pos in
            self?.clearMessage()
            self?.sleep.setSliderPosition(pos)
        }
        let durationItem = NSMenuItem()
        durationItem.view = durationSliderView
        menu.addItem(durationItem)

        // Battery cutoff slider — only meaningful on machines with a battery.
        if sleep.hasBattery {
            menu.addItem(.separator())
            let view = BatterySliderView(initialValue: sleep.batteryThresholdPercent) { [weak self] v in
                self?.sleep.batteryThresholdPercent = v
            }
            let item = NSMenuItem()
            item.view = view
            menu.addItem(item)
            batterySliderView = view
        }

        menu.addItem(.separator())

        // "Configuration" submenu — two sections, each introduced by a disabled
        // header item: the four wake-mechanism toggles, then the left-click
        // action radio group + its fixed-duration slider.
        let configItem = NSMenuItem(title: "Configuration", action: nil, keyEquivalent: "")
        let configSub = NSMenu()

        let wakeHeader = NSMenuItem(title: "Wake modes", action: nil, keyEquivalent: "")
        wakeHeader.isEnabled = false
        configSub.addItem(wakeHeader)
        for mode in WakeMode.allCases {
            let item = NSMenuItem(title: mode.menuTitle,
                                  action: #selector(toggleWakeMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            configSub.addItem(item)
            wakeModeItems[mode] = item

            // Directly under "Keep display on": a time-of-day window slider.
            if mode == .display {
                rangeSliderView = RangeSliderView(
                    initialStart: sleep.displayWindowStart,
                    initialEnd: sleep.displayWindowEnd
                ) { [weak self] start, end in
                    self?.sleep.setDisplayWindow(start: start, end: end)
                }
                let rangeItem = NSMenuItem()
                rangeItem.view = rangeSliderView
                rangeItem.isHidden = !sleep.isEnabled(.display)
                configSub.addItem(rangeItem)
                rangeSliderItem = rangeItem

                // Battery Macs only: suspend "Keep display on" while unplugged.
                if sleep.hasBattery {
                    let pauseItem = NSMenuItem(title: "Pause on battery",
                                               action: #selector(togglePauseOnBattery),
                                               keyEquivalent: "")
                    pauseItem.target = self
                    pauseItem.isHidden = !sleep.isEnabled(.display)
                    configSub.addItem(pauseItem)
                    pauseOnBatteryItem = pauseItem
                }
            }
        }
        configSub.addItem(.separator())
        let leftClickHeader = NSMenuItem(title: "Left click action", action: nil, keyEquivalent: "")
        leftClickHeader.isEnabled = false
        configSub.addItem(leftClickHeader)
        for action in LeftClickAction.allCases {
            let item = NSMenuItem(title: action.menuTitle,
                                  action: #selector(toggleLeftClickAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            configSub.addItem(item)
            leftClickItems[action] = item
        }
        fixedClickSliderView = DurationSliderView(
            title: "On for",
            initialPosition: sleep.fixedClickSliderPosition,
            initialText: SleepManager.displayString(forSliderPosition: sleep.fixedClickSliderPosition),
            textForPosition: { SleepManager.displayString(forSliderPosition: $0) }
        ) { [weak self] pos in
            let p = max(1, pos)  // option 3 must engage something
            self?.sleep.fixedClickSliderPosition = p
            self?.refresh()
        }
        let fixedItem = NSMenuItem()
        fixedItem.view = fixedClickSliderView
        configSub.addItem(fixedItem)
        configItem.submenu = configSub
        menu.addItem(configItem)

        loginItem = NSMenuItem(title: "Open at Login",
                               action: #selector(toggleLogin),
                               keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let checkNowItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        checkNowItem.target = updater
        menu.addItem(checkNowItem)

        autoUpdateItem = NSMenuItem(title: "Check Automatically",
                                    action: #selector(toggleAutoUpdate),
                                    keyEquivalent: "")
        autoUpdateItem.target = self
        menu.addItem(autoUpdateItem)

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

    @objc private func toggleLogin() {
        clearMessage()
        if let msg = login.setEnabled(!login.isEnabled) {
            showMessage(msg)
        }
        refresh()
    }

    @objc private func toggleWakeMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = WakeMode(rawValue: raw) else { return }
        clearMessage()
        sleep.setMode(mode, enabled: !sleep.isEnabled(mode))
    }

    @objc private func togglePauseOnBattery() {
        sleep.setPauseDisplayOnBattery(!sleep.pauseDisplayOnBattery)
    }

    @objc private func toggleLeftClickAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = LeftClickAction(rawValue: raw) else { return }
        sleep.setLeftClickAction(action)
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

    @objc private func toggleAutoUpdate() {
        let now = updater.updater.automaticallyChecksForUpdates
        updater.updater.automaticallyChecksForUpdates = !now
        refresh()
    }

    // MARK: - Refresh

    /// Refresh icon and menu state. Also called as the menu opens so the
    /// remaining-time label is current.
    private func refresh() {
        let active = sleep.isActive
        // Newt: filled lizard while keep-awake is on, outline when sleeping.
        let symbol = active ? "lizard.fill" : "lizard"
        if let image = NSImage(systemSymbolName: symbol,
                               accessibilityDescription: "Newt") {
            image.isTemplate = true
            statusItem.button?.image = image
        }
        let blocked = sleep.blockedByBattery
        let label = blocked.map { "battery \($0.percent)% — recharge to enable" }
                    ?? sleep.displayString()
        durationSliderView.refresh(position: sleep.sliderPosition,
                                   displayText: label,
                                   enabled: blocked == nil)
        batterySliderView?.refresh(value: sleep.batteryThresholdPercent)
        loginItem.state = login.isEnabled ? .on : .off
        autoUpdateItem?.state = updater.updater.automaticallyChecksForUpdates ? .on : .off
        for (mode, item) in wakeModeItems {
            item.state = sleep.isEnabled(mode) ? .on : .off
        }
        for (action, item) in leftClickItems {
            item.state = sleep.leftClickAction == action ? .on : .off
        }
        // Surface the remembered duration so the user can see what
        // "toggle last" would re-engage at.
        if let lastItem = leftClickItems[.toggleLast] {
            let dur = SleepManager.displayString(forSliderPosition: sleep.lastUsedSliderPosition)
            lastItem.title = "Toggle last duration (\(dur))"
        }
        // Fixed-click slider is configurable only when option 3 is selected.
        fixedClickSliderView.refresh(
            position: sleep.fixedClickSliderPosition,
            displayText: SleepManager.displayString(forSliderPosition: sleep.fixedClickSliderPosition),
            enabled: sleep.leftClickAction == .toggleFixed)
        rangeSliderItem?.isHidden = !sleep.isEnabled(.display)
        pauseOnBatteryItem?.isHidden = !sleep.isEnabled(.display)
        pauseOnBatteryItem?.state = sleep.pauseDisplayOnBattery ? .on : .off
        rangeSliderView.refresh(start: sleep.displayWindowStart,
                                end: sleep.displayWindowEnd,
                                enabled: true)
    }

    private func showMessage(_ text: String) {
        messageItem.title = text
        messageItem.isHidden = false
    }

    private func clearMessage() {
        messageItem.title = ""
        messageItem.isHidden = true
    }

    // MARK: - NSView tooltip owner

    /// Called by AppKit each time the status-item tooltip is about to appear,
    /// so the string is always current. Empty string suppresses the tooltip.
    @objc func view(_ view: NSView,
                    stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint,
                    userData: UnsafeMutableRawPointer?) -> String {
        sleep.isActive ? sleep.displayString() : ""
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
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
        if let fixed = fixedClickSliderView {
            let fixedVisual = max(1, fixed.currentPosition)
            if fixedVisual != sleep.fixedClickSliderPosition {
                sleep.fixedClickSliderPosition = fixedVisual
            }
            fixed.endDragIfNeeded()
        }
        if let range = rangeSliderView {
            if range.currentStart != sleep.displayWindowStart
                || range.currentEnd != sleep.displayWindowEnd {
                sleep.setDisplayWindow(start: range.currentStart, end: range.currentEnd)
            }
            range.endDragIfNeeded()
        }
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
        titleLabel.frame = NSRect(x: 14, y: 24, width: 100, height: 16)
        addSubview(titleLabel)

        valueLabel.font = font
        valueLabel.alignment = .right
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.frame = NSRect(x: 110, y: 24, width: 116, height: 16)
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

    private let trackMinX: CGFloat = 16
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
        titleLabel.frame = NSRect(x: 14, y: 24, width: 100, height: 16)
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
