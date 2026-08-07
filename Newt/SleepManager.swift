import Foundation
import IOKit.pwr_mgt

/// The current keep-awake mode. `off` means the Mac sleeps normally.
enum AwakeState: Equatable {
    case off
    case indefinite
    case timed(until: Date)
}

/// Individually toggleable wake mechanisms. Each maps 1:1 to an IOKit
/// assertion or the helper's `pmset disablesleep` flag.
enum WakeMode: String, CaseIterable {
    case display     // PreventUserIdleDisplaySleep — caffeinate -d
    case systemIdle  // PreventUserIdleSystemSleep  — caffeinate -i
    case system      // PreventSystemSleep          — caffeinate -s
    case lidClosed   // pmset -a disablesleep 1 via helper

    var defaultsKey: String { "WakeMode.\(rawValue)" }
    var menuTitle: String {
        switch self {
        case .display:    return "Keep display on"
        case .systemIdle: return "Keep system awake when idle"
        case .system:     return "Prevent system sleep (AC only)"
        case .lidClosed:  return "Stay awake with lid closed"
        }
    }
}

/// What left-clicking the menu bar icon does. Right-click always opens the menu.
enum LeftClickAction: String, CaseIterable {
    case openMenu        // same as right-click — Newt's pre-existing behavior
    case toggleLast      // re-engage at the last-used duration (or 4h on first run)
    case toggleFixed     // engage at the user-configured fixed duration

    var menuTitle: String {
        switch self {
        case .openMenu:    return "Open menu"
        case .toggleLast:  return "Toggle last duration"
        case .toggleFixed: return "Toggle on for fixed duration"
        }
    }
}

/// User-facing notification toggles. Independent booleans (like `WakeMode`),
/// but default OFF — they're new opt-in behavior.
enum NotificationOption: String, CaseIterable {
    case badgeWhenEngaged   // indicator dot on the menu bar icon while engaged
    case notifyOnExpiry     // system notification when a timed clock runs out

    var defaultsKey: String { "Notify.\(rawValue)" }
    var menuTitle: String {
        switch self {
        case .badgeWhenEngaged: return "Indicator dot when engaged"
        case .notifyOnExpiry:   return "Notify when keep-awake expires"
        }
    }
}

/// Single source of truth for keep-awake state. Engaging applies the full
/// lidawake treatment — IOKit power assertions (idle/display sleep) plus the
/// privileged helper's `pmset disablesleep` (lid-close sleep). Disengaging
/// undoes both.
final class SleepManager {
    private(set) var state: AwakeState = .off

    /// Seconds chosen for the active timed session, for menu checkmarks.
    private(set) var activeDurationSeconds: Int = 0

    /// Slider duration table. Index = slider position (0…15). Mostly linear
    /// 2-hour ladder from 4h up, with a 30m/1h/2h ramp for nap-length awakes.
    ///   0  → off (sentinel, never used as a duration)
    ///   -1 → indefinite (sentinel)
    ///   N  → seconds for that timed step.
    static let sliderDurations: [Int] = [
        0,             // 0   off
        30 * 60,       // 1   30 min
        60 * 60,       // 2   1 h
        2  * 3600,     // 3   2 h
        4  * 3600,     // 4   4 h
        6  * 3600,     // 5   6 h
        8  * 3600,     // 6   8 h
        10 * 3600,     // 7   10 h
        12 * 3600,     // 8   12 h
        14 * 3600,     // 9   14 h
        16 * 3600,     // 10  16 h
        18 * 3600,     // 11  18 h
        20 * 3600,     // 12  20 h
        22 * 3600,     // 13  22 h
        24 * 3600,     // 14  24 h
        -1             // 15  indefinite
    ]

    /// The pre-v0.2.7 11-stop geometric table — kept only to remap stored
    /// `LastUsedSliderPosition` / `FixedClickSliderPosition` on first launch
    /// of the new schema. Never read after migration completes.
    private static let legacySliderDurations: [Int] = [
        0, 60, 15 * 60, 30 * 60, 60 * 60, 2 * 3600,
        4 * 3600, 8 * 3600, 16 * 3600, 24 * 3600, -1
    ]

    /// Remap stored slider positions from the legacy 11-stop table to the new
    /// 16-stop one. Runs at most once per machine, gated by `SliderTableVersion`.
    private static func migrateSliderPositionsIfNeeded() {
        let d = UserDefaults.standard
        if d.integer(forKey: "SliderTableVersion") >= 1 { return }
        for key in ["LastUsedSliderPosition", "FixedClickSliderPosition"] {
            guard let old = d.object(forKey: key) as? Int else { continue }
            let idx = max(0, min(legacySliderDurations.count - 1, old))
            let seconds = legacySliderDurations[idx]
            d.set(nearestPosition(forSeconds: seconds), forKey: key)
        }
        d.set(1, forKey: "SliderTableVersion")
    }

    /// Map a duration (seconds) to its position in the table. Exact match
    /// preferred; otherwise closest non-sentinel stop. Used by the legacy-table
    /// migration and to snap URL-scheme sessions to a slider thumb position.
    private static func nearestPosition(forSeconds seconds: Int) -> Int {
        if seconds == 0  { return 0 }
        if seconds == -1 { return sliderDurations.count - 1 }
        if let exact = sliderDurations.firstIndex(of: seconds) { return exact }
        let timed = sliderDurations.enumerated().filter { $0.element > 0 }
        return timed.min { abs($0.element - seconds) < abs($1.element - seconds) }!.offset
    }

    /// Current slider position 0…10. The slider is the single on/off control;
    /// 0 = off, 1–9 = timed, 10 = indefinite. Reset to 0 on disengage.
    private(set) var sliderPosition: Int = 0

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var preventSystemAssertion: IOPMAssertionID = 0
    private var assertionsActive = false
    private var expiryTimer: Timer?
    private var displayWindowTimer: Timer?
    private let helper = HelperClient()
    private let battery = BatteryMonitor()

    /// Called whenever `state` changes — the controller refreshes the menu.
    var onChange: (() -> Void)?
    /// Called with a user-facing message (e.g. helper needs approval).
    var onHelperMessage: ((String) -> Void)?
    /// Fired only when a timed session ends because its clock ran out — not on
    /// manual disengage, battery trip, or quit. The controller decides whether
    /// to post a system notification.
    var onTimerExpired: (() -> Void)?

    var isActive: Bool { state != .off }
    var hasBattery: Bool { battery.hasBattery }

    /// Battery percentage floor at which Newt auto-releases its claims.
    /// 0 disables the cutoff. Persisted to UserDefaults.
    var batteryThresholdPercent: Int {
        get { battery.thresholdPercent }
        set {
            let clamped = max(0, min(30, newValue))
            battery.thresholdPercent = clamped
            UserDefaults.standard.set(clamped, forKey: "BatteryThresholdPercent")
        }
    }

    /// Which mechanisms are enabled. Defaults to all-on on first run so the
    /// upgrade path preserves prior behavior.
    private var enabledModes: Set<WakeMode> = []

    /// Which notification options are on. Defaults to none (opt-in).
    private var enabledNotifications: Set<NotificationOption> = []

    /// Time-of-day window during which "Keep display on" applies, as half-hour
    /// indices (0…48; minute = idx*30). Default 0…48 = all day (no restriction).
    /// Outside the window the display assertion is dropped so the display sleeps.
    private(set) var displayWindowStart = 0
    private(set) var displayWindowEnd = 48

    /// When on, "Keep display on" is suspended while running on battery so the
    /// display may sleep; it resumes on AC. Display-only — other mechanisms are
    /// unaffected. Default off so upgrades preserve prior behavior.
    private(set) var pauseDisplayOnBattery = false

    /// Re-engage at launch with whatever state Newt had when it last quit (or
    /// was killed). Off by default. See `resumeIfNeeded()`.
    private(set) var resumeOnLaunch = false

    /// Left-click behavior. Default `.openMenu` preserves prior UX on upgrade.
    private(set) var leftClickAction: LeftClickAction = .openMenu

    /// Last slider position the user successfully engaged at. Used by
    /// the `.toggleLast` left-click action. Defaults to position 4 (4h).
    private(set) var lastUsedSliderPosition: Int = 4

    /// Slider position used by the `.toggleFixed` left-click action. Clamped
    /// to 1…(count-1) (no "off" — option 3 must engage something). Defaults
    /// to position 4 (4h).
    var fixedClickSliderPosition: Int = 4 {
        didSet {
            let clamped = max(1, min(Self.sliderDurations.count - 1, fixedClickSliderPosition))
            if clamped != fixedClickSliderPosition {
                fixedClickSliderPosition = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: "FixedClickSliderPosition")
        }
    }

    init() {
        // Remap legacy 11-stop slider positions before reading them below.
        Self.migrateSliderPositionsIfNeeded()

        let saved = UserDefaults.standard.integer(forKey: "BatteryThresholdPercent")
        battery.thresholdPercent = max(0, min(30, saved))
        battery.onTrip = { [weak self] in
            guard let self, self.isActive else { return }
            self.onHelperMessage?("Released keep-awake — battery hit \(self.battery.thresholdPercent)%")
            self.disengage()
        }
        // Plug/unplug while engaged: suspend or resume the display assertion if
        // "pause on battery" is on. Other mechanisms are untouched.
        battery.onPowerChange = { [weak self] in self?.reevaluateDisplay() }
        // Load mode toggles. If a key is missing (first run / upgrade), the
        // mode defaults to on.
        let defaults = UserDefaults.standard
        for mode in WakeMode.allCases {
            let on = defaults.object(forKey: mode.defaultsKey) as? Bool ?? true
            if on { enabledModes.insert(mode) }
        }
        // Left-click action + remembered durations.
        if let raw = defaults.string(forKey: "LeftClickAction"),
           let action = LeftClickAction(rawValue: raw) {
            leftClickAction = action
        }
        let timedRange = 1 ... (Self.sliderDurations.count - 1)
        if let n = defaults.object(forKey: "LastUsedSliderPosition") as? Int,
           timedRange.contains(n) {
            lastUsedSliderPosition = n
        }
        if let n = defaults.object(forKey: "FixedClickSliderPosition") as? Int,
           timedRange.contains(n) {
            fixedClickSliderPosition = n
        }
        // Display-on time window (half-hour indices). Missing keys → all day.
        let ws = defaults.object(forKey: "DisplayWindowStart") as? Int ?? 0
        let we = defaults.object(forKey: "DisplayWindowEnd") as? Int ?? 48
        displayWindowStart = max(0, min(47, ws))
        displayWindowEnd = max(displayWindowStart + 1, min(48, we))
        pauseDisplayOnBattery = defaults.object(forKey: "PauseDisplayOnBattery") as? Bool ?? false
        resumeOnLaunch = defaults.object(forKey: "ResumeOnLaunch") as? Bool ?? false
        // Notification options — missing key → off (opt-in).
        for option in NotificationOption.allCases {
            if defaults.object(forKey: option.defaultsKey) as? Bool ?? false {
                enabledNotifications.insert(option)
            }
        }
    }

    func setLeftClickAction(_ action: LeftClickAction) {
        guard action != leftClickAction else { return }
        leftClickAction = action
        UserDefaults.standard.set(action.rawValue, forKey: "LeftClickAction")
        onChange?()
    }

    /// Drive a left-click on the menu bar icon. The controller calls this only
    /// when `leftClickAction != .openMenu`. If currently active, disengages;
    /// otherwise engages at the slider position implied by the current action.
    func performLeftClickToggle() {
        if isActive {
            setSliderPosition(0)
            return
        }
        switch leftClickAction {
        case .openMenu:    return  // controller handles
        case .toggleLast:  setSliderPosition(lastUsedSliderPosition)
        case .toggleFixed: setSliderPosition(fixedClickSliderPosition)
        }
    }

    func isEnabled(_ mode: WakeMode) -> Bool { enabledModes.contains(mode) }

    /// Toggle a wake mechanism. Persists, and if currently engaged, adds or
    /// drops just that assertion (or flips the helper) without bouncing the
    /// whole session.
    func setMode(_ mode: WakeMode, enabled: Bool) {
        guard enabled != enabledModes.contains(mode) else { return }
        if enabled { enabledModes.insert(mode) } else { enabledModes.remove(mode) }
        UserDefaults.standard.set(enabled, forKey: mode.defaultsKey)

        if isActive {
            switch mode {
            case .display:    applyAssertion(mode, on: displayWanted(),
                                             id: &displayAssertion,
                                             type: kIOPMAssertionTypePreventUserIdleDisplaySleep)
                              scheduleDisplayWindowTimer()
            case .systemIdle: applyAssertion(mode, on: enabled, id: &systemAssertion,
                                             type: kIOPMAssertionTypePreventUserIdleSystemSleep)
            case .system:     applyAssertion(mode, on: enabled, id: &preventSystemAssertion,
                                             type: kIOPMAssertionTypePreventSystemSleep)
            case .lidClosed:
                helper.setDisableSleep(enabled) { [weak self] _, err in
                    if let err { self?.onHelperMessage?(err) }
                }
            }
        }
        onChange?()
    }

    func isNotificationEnabled(_ option: NotificationOption) -> Bool {
        enabledNotifications.contains(option)
    }

    /// Toggle a notification option. Persists and refreshes the menu/icon.
    func setNotificationOption(_ option: NotificationOption, enabled: Bool) {
        guard enabled != enabledNotifications.contains(option) else { return }
        if enabled { enabledNotifications.insert(option) } else { enabledNotifications.remove(option) }
        UserDefaults.standard.set(enabled, forKey: option.defaultsKey)
        onChange?()
    }

    /// Seconds left in a timed session, or nil if not timed.
    var remaining: TimeInterval? {
        if case .timed(let until) = state {
            return max(0, until.timeIntervalSinceNow)
        }
        return nil
    }

    // MARK: - Public actions

    /// Drive everything from the slider. 0 disengages; 1–9 starts a timed
    /// session of the corresponding duration; 10 engages indefinite. Refuses
    /// to engage while battery is below the configured floor.
    func setSliderPosition(_ pos: Int) {
        let p = max(0, min(Self.sliderDurations.count - 1, pos))
        let value = Self.sliderDurations[p]
        if value == 0 {
            sliderPosition = 0
            disengage()
            return
        }
        if let message = canEngage() {
            // Don't let the user arm a session the guards will refuse (e.g. a
            // battery cutoff that would just tear it down again). Snap back to
            // 0 and explain why.
            sliderPosition = 0
            onHelperMessage?(message)
            onChange?()
            return
        }
        sliderPosition = p
        // Remember the last successful engagement so `.toggleLast` left-click
        // can re-engage at the same duration later. Only non-zero positions
        // are stored — expiry returning to 0 must not overwrite this.
        lastUsedSliderPosition = p
        UserDefaults.standard.set(p, forKey: "LastUsedSliderPosition")
        if value == -1 {
            engage(.indefinite, durationSeconds: 0)
        } else {
            engage(.timed(until: Date().addingTimeInterval(TimeInterval(value))),
                   durationSeconds: value)
        }
    }

    /// nil when engaging is allowed; otherwise a user-facing refusal message.
    /// Shared by the slider and URL-scheme entry points so the guards can't
    /// drift apart.
    private func canEngage() -> String? {
        if enabledModes.isEmpty {
            return "Enable at least one wake mode in the menu"
        }
        if let blocked = blockedByBattery {
            return "Can't engage — battery \(blocked.percent)% is at or below your \(blocked.threshold)% floor"
        }
        return nil
    }

    /// Engage for an exact number of minutes (URL scheme). The slider thumb
    /// snaps to the nearest stop for display; the session length is exact.
    func engageFor(minutes: Int) {
        let m = max(1, min(24 * 60, minutes))
        engageTimed(until: Date().addingTimeInterval(TimeInterval(m * 60)),
                    seconds: m * 60)
    }

    /// Engage until a wall-clock date (URL scheme). Non-future dates are a no-op.
    func engageUntil(_ date: Date) {
        let seconds = Int(date.timeIntervalSinceNow.rounded())
        guard seconds > 0 else { return }
        engageTimed(until: date, seconds: seconds)
    }

    /// Shared timed-engage path for the exact-duration entry points.
    private func engageTimed(until: Date, seconds: Int) {
        if let message = canEngage() {
            onHelperMessage?(message)
            onChange?()
            return
        }
        sliderPosition = Self.nearestPosition(forSeconds: seconds)
        lastUsedSliderPosition = sliderPosition
        UserDefaults.standard.set(sliderPosition, forKey: "LastUsedSliderPosition")
        engage(.timed(until: until), durationSeconds: seconds)
    }

    /// Re-engage with the state Newt had when it last stopped running.
    /// `EngagedSliderPosition` is written on every engage/disengage, so this
    /// survives crashes and `killall`, and an expired or manually-ended session
    /// correctly stays off. Goes through `setSliderPosition`, so the battery
    /// floor and wake-mode guards apply as if the user moved the slider.
    func resumeIfNeeded() {
        guard resumeOnLaunch, !isActive else { return }
        let p = UserDefaults.standard.integer(forKey: "EngagedSliderPosition")
        guard p > 0 else { return }
        setSliderPosition(p)
    }

    /// nil if engagement is allowed; otherwise the (current %, configured %)
    /// pair so the UI can explain why the slider is greyed out.
    var blockedByBattery: (percent: Int, threshold: Int)? {
        let threshold = battery.thresholdPercent
        guard threshold > 0,
              let snap = battery.currentSnapshot(),
              !snap.onAC,
              snap.percent <= threshold
        else { return nil }
        return (snap.percent, threshold)
    }

    /// Menu label for the slider: "off" / "indefinite" / remaining + end time
    /// ("1h 23m/20:46", "+1" marking an end that lands tomorrow).
    func displayString() -> String {
        switch state {
        case .off:        return "off"
        case .indefinite: return "indefinite"
        case .timed(let until):
            return "\(Self.formatRemaining(until.timeIntervalSinceNow))/\(Self.clockString(until))"
        }
    }

    /// Drag-preview label for a main-slider stop: duration and the wall-clock
    /// time it would run to, e.g. "2h 0m/20:46". Only the main slider uses
    /// this — the "On for" slider configures a *stored* duration, where an end
    /// time computed from "now" would be stale the moment it's read.
    func sliderLabel(forPosition p: Int) -> String {
        let idx = max(0, min(Self.sliderDurations.count - 1, p))
        let secs = Self.sliderDurations[idx]
        if secs == 0  { return "off" }
        if secs == -1 { return "indefinite" }
        let end = Date().addingTimeInterval(TimeInterval(secs))
        return "\(Self.formatRemaining(TimeInterval(secs)))/\(Self.clockString(end))"
    }

    /// "20:46", flight-style "+1" suffix when the date lands tomorrow (the
    /// spelled-out "(tomorrow)" wouldn't fit beside a duration in the menu).
    private static func clockString(_ date: Date) -> String {
        let time = clockFormatter.string(from: date)
        return Calendar.current.isDateInTomorrow(date) ? "\(time)+1" : time
    }

    /// Follows the system's locale and its 12/24-hour setting. A hardcoded
    /// "HH:mm" would be rewritten by the 24-Hour Time override anyway;
    /// `autoupdatingCurrent` also picks up changes without a relaunch.
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Static label for an arbitrary slider position 0…10. Used by views
    /// configuring a duration that isn't currently engaged (e.g. the fixed
    /// left-click duration).
    static func displayString(forSliderPosition p: Int) -> String {
        let idx = max(0, min(sliderDurations.count - 1, p))
        let secs = sliderDurations[idx]
        if secs == 0  { return "off" }
        if secs == -1 { return "indefinite" }
        return formatRemaining(TimeInterval(secs))
    }

    private static func formatRemaining(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        // ≥ 1h: hours + minutes (seconds add noise at that scale).
        // <  1h: minutes + seconds.
        // A zero trailing unit is dropped — every slider stop is an exact
        // multiple, so it would otherwise always read "2h 0m" / "30m 0s".
        if h > 0  { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0  { return s > 0 ? "\(m)m \(s)s" : "\(m)m" }
        return "\(s)s"
    }

    /// Register the privileged helper early, so approval isn't deferred to the
    /// first toggle. Surfaces any message via `onHelperMessage`.
    func prepareHelper() {
        helper.prepare { [weak self] message in
            guard let self else { return }
            if let message { self.onHelperMessage?(message) }
            // The version handshake can bounce the daemon (the usual case:
            // first launch after an update). Bouncing drops the XPC connection,
            // and the helper's disconnect safety restores `disablesleep 0` — so
            // anything engaged before this point, notably a launch-time resume,
            // has silently lost lid-close protection. Re-assert it; setting the
            // flag twice is harmless.
            if self.isActive, self.enabledModes.contains(.lidClosed) {
                self.helper.setDisableSleep(true) { [weak self] _, err in
                    if let err { self?.onHelperMessage?(err) }
                }
            }
        }
    }

    // MARK: - Engage / disengage

    private func engage(_ newState: AwakeState, durationSeconds: Int) {
        state = newState
        activeDurationSeconds = durationSeconds
        // Live engagement record for "Resume last state at launch" — written on
        // every transition (not just clean quit) so it survives crashes.
        UserDefaults.standard.set(sliderPosition, forKey: "EngagedSliderPosition")
        if !assertionsActive { createAssertions() }
        scheduleExpiry()
        scheduleDisplayWindowTimer()
        battery.enable()
        if enabledModes.contains(.lidClosed) {
            helper.setDisableSleep(true) { [weak self] _, err in
                if let err { self?.onHelperMessage?(err) }
            }
        }
        onChange?()
    }

    func disengage() {
        guard state != .off else { return }
        state = .off
        activeDurationSeconds = 0
        sliderPosition = 0
        UserDefaults.standard.set(0, forKey: "EngagedSliderPosition")
        expiryTimer?.invalidate()
        expiryTimer = nil
        displayWindowTimer?.invalidate()
        displayWindowTimer = nil
        battery.disable()
        releaseAssertions()
        helper.setDisableSleep(false) { _, _ in }
        onChange?()
    }

    /// App-termination teardown: releases everything like `disengage()`, but
    /// preserves the resume record — quitting while engaged must count as
    /// "engaged at quit" for `resumeIfNeeded()`, and `disengage()` zeroes it.
    func shutdown() {
        let p = sliderPosition
        disengage()
        if p > 0 { UserDefaults.standard.set(p, forKey: "EngagedSliderPosition") }
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard case .timed(let until) = state else { return }
        let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            self?.onTimerExpired?()
            self?.disengage()
        }
        RunLoop.main.add(t, forMode: .common)
        expiryTimer = t
    }

    // MARK: - Display-on time window

    /// True when the current local time is inside the display-on window (or the
    /// window covers the full day).
    func isNowInDisplayWindow() -> Bool {
        if displayWindowStart == 0 && displayWindowEnd == 48 { return true }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let mins = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return mins >= displayWindowStart * 30 && mins < displayWindowEnd * 30
    }

    private func displayWanted() -> Bool {
        guard enabledModes.contains(.display), isNowInDisplayWindow() else { return false }
        if pauseDisplayOnBattery && isOnBattery { return false }
        return true
    }

    /// True when running on battery (not AC). False when there's no battery or
    /// the power source can't be read.
    private var isOnBattery: Bool {
        guard let snap = battery.currentSnapshot() else { return false }
        return !snap.onAC
    }

    private var displayWindowRestricted: Bool {
        !(displayWindowStart == 0 && displayWindowEnd == 48)
    }

    /// Add/drop the display assertion as its conditions change — the clock
    /// crossing the window edges, or a plug/unplug when "pause on battery" is on.
    private func reevaluateDisplay() {
        guard assertionsActive else { return }
        let want = displayWanted()
        guard want != (displayAssertion != 0) else { return }
        applyAssertion(.display, on: want, id: &displayAssertion,
                       type: kIOPMAssertionTypePreventUserIdleDisplaySleep)
        onChange?()
    }

    /// Poll once a minute while engaged with a restricted window, flipping the
    /// display assertion at the boundaries (mirrors BatteryMonitor's poll shape).
    private func scheduleDisplayWindowTimer() {
        displayWindowTimer?.invalidate()
        displayWindowTimer = nil
        guard isActive, enabledModes.contains(.display), displayWindowRestricted else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.reevaluateDisplay()
        }
        RunLoop.main.add(t, forMode: .common)
        displayWindowTimer = t
    }

    /// Set the display-on window (half-hour indices, end > start). Persists; if
    /// engaged, re-evaluates the display assertion now and re-arms the timer.
    func setDisplayWindow(start: Int, end: Int) {
        let s = max(0, min(47, start))
        let e = max(s + 1, min(48, end))
        guard s != displayWindowStart || e != displayWindowEnd else { return }
        displayWindowStart = s
        displayWindowEnd = e
        UserDefaults.standard.set(s, forKey: "DisplayWindowStart")
        UserDefaults.standard.set(e, forKey: "DisplayWindowEnd")
        if isActive {
            reevaluateDisplay()
            scheduleDisplayWindowTimer()
        }
        onChange?()
    }

    /// Toggle "pause display on battery". Persists; if engaged, re-evaluates the
    /// display assertion now for the current power state.
    func setPauseDisplayOnBattery(_ on: Bool) {
        guard on != pauseDisplayOnBattery else { return }
        pauseDisplayOnBattery = on
        UserDefaults.standard.set(on, forKey: "PauseDisplayOnBattery")
        if isActive { reevaluateDisplay() }
        onChange?()
    }

    /// Toggle "resume last state at launch". Persists.
    func setResumeOnLaunch(_ on: Bool) {
        guard on != resumeOnLaunch else { return }
        resumeOnLaunch = on
        UserDefaults.standard.set(on, forKey: "ResumeOnLaunch")
        onChange?()
    }

    // MARK: - IOKit power assertions

    private func createAssertions() {
        // Maps to subsets of `caffeinate -dis` depending on which modes are
        // enabled. `-m` disk-idle has no public IOKit assertion; `-u` is a
        // one-shot "declare user active" pulse with no continuous mode and
        // is not exposed as a toggle.
        if enabledModes.contains(.systemIdle) {
            createAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep, into: &systemAssertion)
        }
        if displayWanted() {
            createAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep, into: &displayAssertion)
        }
        if enabledModes.contains(.system) {
            createAssertion(kIOPMAssertionTypePreventSystemSleep, into: &preventSystemAssertion)
        }
        assertionsActive = true
    }

    private func createAssertion(_ type: String, into id: inout IOPMAssertionID) {
        IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Newt — keep awake" as CFString,
            &id)
    }

    /// Add or drop a single assertion while keep-awake is engaged.
    private func applyAssertion(_ mode: WakeMode, on: Bool,
                                id: inout IOPMAssertionID, type: String) {
        if on {
            if id == 0 { createAssertion(type, into: &id) }
        } else {
            if id != 0 { IOPMAssertionRelease(id); id = 0 }
        }
    }

    private func releaseAssertions() {
        guard assertionsActive else { return }
        if systemAssertion != 0         { IOPMAssertionRelease(systemAssertion);         systemAssertion = 0 }
        if displayAssertion != 0        { IOPMAssertionRelease(displayAssertion);        displayAssertion = 0 }
        if preventSystemAssertion != 0  { IOPMAssertionRelease(preventSystemAssertion);  preventSystemAssertion = 0 }
        assertionsActive = false
    }
}
