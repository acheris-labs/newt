import AppKit
import Sparkle

/// Owns the menu bar item and its menu, and drives `SleepManager` from it.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(
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

    /// Ticks the remaining-time label while the menu is open.
    private var menuTickTimer: Timer?

    init(updater: SPUStandardUpdaterController) {
        self.updater = updater
        super.init()
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        sleep.onChange = { [weak self] in self?.refresh() }
        sleep.onHelperMessage = { [weak self] msg in self?.showMessage(msg) }
        refresh()
        sleep.prepareHelper()
        // First run defaults to Open at Login — afterward, respect the user.
        if let msg = login.bootstrapDefaultIfNeeded() { showMessage(msg) }
        refresh()
    }

    /// Called on app termination — restores normal sleep behavior.
    func shutdown() {
        sleep.disengage()
    }

    // MARK: - Menu construction

    private func buildMenu() {
        // Keep-awake slider — the primary control.
        durationSliderView = DurationSliderView(
            initialPosition: sleep.sliderPosition,
            initialText:     sleep.displayString()
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

        // "Wake modes" submenu — toggles for the individual IOKit assertions
        // and the helper's lid-close override.
        let wakeModesItem = NSMenuItem(title: "Wake modes", action: nil, keyEquivalent: "")
        let wakeModesSub = NSMenu()
        for mode in WakeMode.allCases {
            let item = NSMenuItem(title: mode.menuTitle,
                                  action: #selector(toggleWakeMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            wakeModesSub.addItem(item)
            wakeModeItems[mode] = item
        }
        wakeModesItem.submenu = wakeModesSub
        menu.addItem(wakeModesItem)

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
    }

    private func showMessage(_ text: String) {
        messageItem.title = text
        messageItem.isHidden = false
    }

    private func clearMessage() {
        messageItem.title = ""
        messageItem.isHidden = true
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
        // mouse-up never fires, so `sliderChanged` is skipped and the visual
        // position would otherwise snap back on next refresh. Commit the
        // slider's current visible value if it diverges from stored state.
        let visual = durationSliderView.currentPosition
        if visual != sleep.sliderPosition {
            sleep.setSliderPosition(visual)
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

    init(initialPosition: Int, initialText: String,
         onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        self.slider = NSSlider(value: Double(initialPosition),
                               minValue: 0, maxValue: 10,
                               target: nil, action: nil)
        self.valueLabel = NSTextField(labelWithString: initialText)
        self.titleLabel = NSTextField(labelWithString: "Keep awake")
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

        // Snap to ticks; only commit on release so dragging across positions
        // doesn't churn the helper / IOPMAssertions on each intermediate tick.
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        slider.numberOfTickMarks = 11
        slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = false
        slider.frame = NSRect(x: 14, y: 4, width: 212, height: 18)
        addSubview(slider)
    }

    required init?(coder: NSCoder) { nil }

    /// The slider's live integer position. Updates during a drag even with
    /// `isContinuous = false` — only action dispatch is suppressed.
    var currentPosition: Int { slider.integerValue }

    /// Sync from external state (e.g. expiry timer fired → slider returns to 0,
    /// or battery dropped below the floor → slider goes disabled).
    func refresh(position: Int, displayText: String, enabled: Bool) {
        if slider.integerValue != position {
            slider.integerValue = position
        }
        slider.isEnabled = enabled
        let color: NSColor = enabled ? .secondaryLabelColor : .tertiaryLabelColor
        titleLabel.textColor = color
        valueLabel.textColor = color
        valueLabel.stringValue = displayText
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let v = Int(sender.doubleValue.rounded())
        sender.integerValue = v
        onChange(v)
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
