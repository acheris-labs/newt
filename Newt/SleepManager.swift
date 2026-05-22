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

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var assertionsActive = false
    private var expiryTimer: Timer?
    private let helper = HelperClient()

    /// Called whenever `state` changes — the controller refreshes the menu.
    var onChange: (() -> Void)?
    /// Called with a user-facing message (e.g. helper needs approval).
    var onHelperMessage: ((String) -> Void)?

    var isActive: Bool { state != .off }

    /// Seconds left in a timed session, or nil if not timed.
    var remaining: TimeInterval? {
        if case .timed(let until) = state {
            return max(0, until.timeIntervalSinceNow)
        }
        return nil
    }

    // MARK: - Public actions

    func toggleIndefinite() {
        if case .indefinite = state {
            disengage()
        } else {
            engage(.indefinite, durationSeconds: 0)
        }
    }

    func startTimed(seconds: Int) {
        engage(.timed(until: Date().addingTimeInterval(TimeInterval(seconds))),
               durationSeconds: seconds)
    }

    func stop() { disengage() }

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
        helper.setDisableSleep(true) { [weak self] _, err in
            if let err { self?.onHelperMessage?(err) }
        }
        onChange?()
    }

    func disengage() {
        guard state != .off else { return }
        state = .off
        activeDurationSeconds = 0
        expiryTimer?.invalidate()
        expiryTimer = nil
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
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &systemAssertion)
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayAssertion)
        assertionsActive = true
    }

    private func releaseAssertions() {
        guard assertionsActive else { return }
        IOPMAssertionRelease(systemAssertion)
        IOPMAssertionRelease(displayAssertion)
        systemAssertion = 0
        displayAssertion = 0
        assertionsActive = false
    }
}
