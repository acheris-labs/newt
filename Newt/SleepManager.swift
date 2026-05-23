import Foundation
import IOKit.pwr_mgt

/// The current keep-awake mode. `off` means the Mac sleeps normally.
enum AwakeState: Equatable {
    case off
    case indefinite
    case timed(until: Date)
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

    init() {
        let saved = UserDefaults.standard.integer(forKey: "BatteryThresholdPercent")
        battery.thresholdPercent = max(0, min(30, saved))
        battery.onTrip = { [weak self] in
            guard let self, self.isActive else { return }
            self.onHelperMessage?("Released keep-awake — battery hit \(self.battery.thresholdPercent)%")
            self.disengage()
        }
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
        helper.setDisableSleep(true) { [weak self] _, err in
            if let err { self?.onHelperMessage?(err) }
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
        let reason = "Newt — keep awake" as CFString
        // Mirrors `caffeinate -dis` (`-m` disk-idle has no public IOKit
        // assertion; even `caffeinate -m` reaches into private internals.
        // `-u` is a one-shot "declare user active" that only matters when
        // the display is asleep — irrelevant here).
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,    // -i
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &systemAssertion)
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,   // -d
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayAssertion)
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep as CFString,            // -s
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &preventSystemAssertion)
        assertionsActive = true
    }

    private func releaseAssertions() {
        guard assertionsActive else { return }
        IOPMAssertionRelease(systemAssertion)
        IOPMAssertionRelease(displayAssertion)
        IOPMAssertionRelease(preventSystemAssertion)
        systemAssertion = 0
        displayAssertion = 0
        preventSystemAssertion = 0
        assertionsActive = false
    }
}
