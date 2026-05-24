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

/// Single source of truth for keep-awake state. Engaging applies the full
/// lidawake treatment — IOKit power assertions (idle/display sleep) plus the
/// privileged helper's `pmset disablesleep` (lid-close sleep). Disengaging
/// undoes both.
final class SleepManager {
    private(set) var state: AwakeState = .off

    /// Seconds chosen for the active timed session, for menu checkmarks.
    private(set) var activeDurationSeconds: Int = 0

    /// Slider duration table. Index = slider position (0…10).
    ///   0  → off (sentinel, never used as a duration)
    ///   -1 → indefinite (sentinel)
    ///   N  → seconds for that timed step.
    static let sliderDurations: [Int] = [
        0,             // 0  off
        60,            // 1  1 min
        15 * 60,       // 2  15 min
        30 * 60,       // 3  30 min
        60 * 60,       // 4  1 h
        2  * 3600,     // 5  2 h
        4  * 3600,     // 6  4 h
        8  * 3600,     // 7  8 h
        16 * 3600,     // 8  16 h
        24 * 3600,     // 9  24 h
        -1             // 10 indefinite
    ]

    /// Current slider position 0…10. The slider is the single on/off control;
    /// 0 = off, 1–9 = timed, 10 = indefinite. Reset to 0 on disengage.
    private(set) var sliderPosition: Int = 0

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var preventSystemAssertion: IOPMAssertionID = 0
    private var assertionsActive = false
    private var expiryTimer: Timer?
    private let helper = HelperClient()
    private let battery = BatteryMonitor()

    /// Called whenever `state` changes — the controller refreshes the menu.
    var onChange: (() -> Void)?
    /// Called with a user-facing message (e.g. helper needs approval).
    var onHelperMessage: ((String) -> Void)?

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

    /// Left-click behavior. Default `.openMenu` preserves prior UX on upgrade.
    private(set) var leftClickAction: LeftClickAction = .openMenu

    /// Last slider position the user successfully engaged at (1…10). Used by
    /// the `.toggleLast` left-click action. Defaults to 6 (4h).
    private(set) var lastUsedSliderPosition: Int = 6

    /// Slider position used by the `.toggleFixed` left-click action. Clamped to
    /// 1…10 (no "off" — option 3 must engage something). Defaults to 6 (4h).
    var fixedClickSliderPosition: Int = 6 {
        didSet {
            let clamped = max(1, min(10, fixedClickSliderPosition))
            if clamped != fixedClickSliderPosition {
                fixedClickSliderPosition = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: "FixedClickSliderPosition")
        }
    }

    init() {
        let saved = UserDefaults.standard.integer(forKey: "BatteryThresholdPercent")
        battery.thresholdPercent = max(0, min(30, saved))
        battery.onTrip = { [weak self] in
            guard let self, self.isActive else { return }
            self.onHelperMessage?("Released keep-awake — battery hit \(self.battery.thresholdPercent)%")
            self.disengage()
        }
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
        if let n = defaults.object(forKey: "LastUsedSliderPosition") as? Int,
           (1...10).contains(n) {
            lastUsedSliderPosition = n
        }
        if let n = defaults.object(forKey: "FixedClickSliderPosition") as? Int,
           (1...10).contains(n) {
            fixedClickSliderPosition = n
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
            case .display:    applyAssertion(mode, on: enabled, id: &displayAssertion,
                                             type: kIOPMAssertionTypePreventUserIdleDisplaySleep)
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
        if enabledModes.isEmpty {
            sliderPosition = 0
            onHelperMessage?("Enable at least one wake mode in the menu")
            onChange?()
            return
        }
        if let blocked = blockedByBattery {
            // Don't let the user re-arm a session that the cutoff will just
            // tear down again. Snap back to 0 and explain why.
            sliderPosition = 0
            onHelperMessage?(
                "Can't engage — battery \(blocked.percent)% is at or below your \(blocked.threshold)% floor")
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

    /// Menu label for the slider: "off" / "1h 23m" (remaining) / "indefinite".
    func displayString() -> String {
        switch state {
        case .off:        return "off"
        case .indefinite: return "indefinite"
        case .timed(let until):
            return Self.formatRemaining(until.timeIntervalSinceNow)
        }
    }

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
        if h > 0  { return "\(h)h \(m)m" }
        if m > 0  { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Register the privileged helper early, so approval isn't deferred to the
    /// first toggle. Surfaces any message via `onHelperMessage`.
    func prepareHelper() {
        helper.prepare { [weak self] message in
            if let message { self?.onHelperMessage?(message) }
        }
    }

    // MARK: - Engage / disengage

    private func engage(_ newState: AwakeState, durationSeconds: Int) {
        state = newState
        activeDurationSeconds = durationSeconds
        if !assertionsActive { createAssertions() }
        scheduleExpiry()
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
        expiryTimer?.invalidate()
        expiryTimer = nil
        battery.disable()
        releaseAssertions()
        helper.setDisableSleep(false) { _, _ in }
        onChange?()
    }

    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard case .timed(let until) = state else { return }
        let t = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            self?.disengage()
        }
        RunLoop.main.add(t, forMode: .common)
        expiryTimer = t
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
        if enabledModes.contains(.display) {
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
