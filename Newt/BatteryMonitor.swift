import Foundation
import IOKit
import IOKit.ps

/// Polls the battery while keep-awake is active and trips when the percentage
/// falls below a configured floor — so Newt doesn't hold the Mac awake until
/// it runs flat.
final class BatteryMonitor {
    /// Percent (0–30) below which Newt should release its claims. 0 disables
    /// the cutoff entirely (hold until the machine dies).
    var thresholdPercent: Int = 0 {
        didSet { restart() }
    }

    /// Called on the main runloop when battery ≤ threshold while on battery.
    var onTrip: (() -> Void)?

    /// Called on the main runloop when the power source flips between AC and
    /// battery (not on routine percentage ticks). Lets callers react to
    /// plug/unplug without polling — used to suspend/resume "Keep display on".
    var onPowerChange: (() -> Void)?

    private var timer: Timer?
    private var enabled = false
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
        enabled = true
        restart()
        startPowerNotifications()
    }

    func disable() {
        enabled = false
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
        guard enabled, thresholdPercent > 0 else { return }
        // Battery doesn't move fast; 15s is plenty and keeps wake-ups cheap.
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    private func check() {
        guard let snapshot = Self.read() else { return }
        // Only release when actually on battery. Plugged in → nothing to do.
        guard !snapshot.onAC else { return }
        if snapshot.percent <= thresholdPercent {
            onTrip?()
        }
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
