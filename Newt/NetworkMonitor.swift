import Foundation
import Network

/// Tracks how long the Mac has been without a usable network interface, so a
/// dropped connection can veto keep-awake once it has lasted long enough to be
/// deliberate rather than a flaky link.
final class NetworkMonitor {
    /// When the current outage began, or nil while a usable interface is up
    /// (or before the first reading). Stored absolute, so a caller can hang a
    /// one-shot timer off it.
    private(set) var offlineSince: Date?

    /// Called on the main queue whenever connectivity flips.
    var onChange: (() -> Void)?

    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        // NWPathMonitor can't be restarted once cancelled, so each start gets a new one.
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in self?.update(path) }
        m.start(queue: .main)
        monitor = m
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        offlineSince = nil
    }

    /// Counts an outage in progress as starting now.
    func restartOutageClock() {
        if offlineSince != nil { offlineSince = Date() }
    }

    private func update(_ path: NWPath) {
        let online = path.status == .satisfied
            && path.availableInterfaces.contains { $0.type != .loopback }
        if online == (offlineSince == nil) { return }
        offlineSince = online ? nil : Date()
        onChange?()
    }
}
