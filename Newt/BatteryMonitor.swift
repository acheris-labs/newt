import Foundation
import IOKit
import IOKit.ps

/// Polls the battery while Newt has any claim on staying awake, and trips when
/// the percentage falls below a configured floor — so Newt doesn't hold the Mac
/// awake until it runs flat. Polling outlives the trip on purpose: the caller
/// needs to hear about the recovery too.
final class BatteryMonitor {
    /// Percent (0–30) below which Newt should release its claims. 0 disables
    /// the cutoff entirely (hold until the machine dies).
    var thresholdPercent: Int = 0 {
        didSet { restart() }
    }

    /// Called on the main runloop the first time battery ≤ threshold while on
    /// battery. Edge-triggered — it won't repeat every poll while the condition
    /// holds, and re-arms once the charge or the power source recovers.
    var onTrip: (() -> Void)?

    /// Called on the main runloop after every poll, whatever the outcome, so a
    /// caller gating on the battery can notice recovery as well as depletion.
    var onEvaluate: (() -> Void)?

    /// Called on the main runloop when the power source flips between AC and
    /// battery (not on routine percentage ticks). Lets callers react to
    /// plug/unplug without polling — used to suspend/resume "Keep display on".
    var onPowerChange: (() -> Void)?

    private var timer: Timer?
    private var enabled = false
    /// Whether the floor is currently breached, so `onTrip` stays edge-triggered.
    private var tripped = false
    /// Event-driven plug/unplug source, independent of the threshold poll above
    /// (so it works even when the low-battery cutoff is off). Active while enabled.
    private var powerSource: CFRunLoopSource?
    /// Last observed AC state, so `onPowerChange` fires only on real flips.
    private var lastOnAC: Bool?

    /// True if the Mac has an internal battery to monitor at all.
    var hasBattery: Bool { Self.read() != nil }

    /// Current battery snapshot, or nil if no battery. Cheap; can be called
    /// at refresh time to decide whether the keep-awake slider is allowed.
    func currentSnapshot() -> (percent: Int, onAC: Bool)? { Self.read() }

    func enable() {
        // Idempotent: `onEvaluate` re-enters the caller's reconcile step, which
        // calls back here, and a second `restart()` would recurse.
        guard !enabled else { return }
        enabled = true
        restart()
        startPowerNotifications()
    }

    func disable() {
        enabled = false
        tripped = false
        timer?.invalidate()
        timer = nil
        stopPowerNotifications()
    }

    deinit { stopPowerNotifications() }

    // MARK: - Power-source change notifications (event-driven)

    private func startPowerNotifications() {
        guard powerSource == nil else { return }
        lastOnAC = Self.read()?.onAC
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<BatteryMonitor>.fromOpaque(ctx)
                .takeUnretainedValue()
                .powerSourcesChanged()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    private func stopPowerNotifications() {
        guard let source = powerSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = nil
        lastOnAC = nil
    }

    /// IOPS fires on any power-source change; collapse to AC↔battery flips.
    private func powerSourcesChanged() {
        let now = Self.read()?.onAC
        guard now != lastOnAC else { return }
        lastOnAC = now
        onPowerChange?()
    }

    private func restart() {
        timer?.invalidate()
        timer = nil
        tripped = false
        guard enabled, thresholdPercent > 0 else { return }
        // Battery doesn't move fast; 15s is plenty and keeps wake-ups cheap.
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    private func check() {
        // An unreadable snapshot is treated as "not breached" — refusing to
        // hold the Mac awake because IOPS hiccuped would be worse than the risk.
        let breached: Bool
        if let snapshot = Self.read() {
            breached = !snapshot.onAC && snapshot.percent <= thresholdPercent
        } else {
            breached = false
        }
        if breached && !tripped { onTrip?() }
        tripped = breached
        onEvaluate?()
    }

    /// Returns (percent 0–100, onAC) for the internal battery, or nil if none.
    private static func read() -> (percent: Int, onAC: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                as? [CFTypeRef] else { return nil }
        for src in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?
                    .takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = desc[kIOPSCurrentCapacityKey] as? Int,
                  let mx  = desc[kIOPSMaxCapacityKey] as? Int, mx > 0
            else { continue }
            let pct = (cur * 100) / mx
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (pct, onAC)
        }
        return nil
    }
}
