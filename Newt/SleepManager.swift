import AppKit
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
        case .badgeWhenEngaged: return "Indicator dot when awake"
        case .notifyOnExpiry:   return "Notify when keep-awake expires"
        }
    }
}

/// Single source of truth for keep-awake state. Engaging applies the full
/// lidawake treatment — IOKit power assertions (idle/display sleep) plus the
/// privileged helper's `pmset disablesleep` (lid-close sleep). Disengaging
/// undoes both.
///
/// Three independent *claims* can ask for the Mac to stay awake — the duration
/// slider, the weekly schedule, and dynamic claims raised over `newt://` (an AI
/// agent working through its hooks, say) — and
/// two *vetoes* can refuse — the low battery floor and manual suppression.
/// Assertions are applied when at least one claim is up and neither veto is.
/// `reconcile()` is the only place that decides; nothing else touches the
/// assertion or helper APIs.
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
    private var boundaryTimer: Timer?
    private var isReconciling = false
    private var systemObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private let helper = HelperClient()
    private let battery = BatteryMonitor()

    /// Claims raised from outside — an AI agent while it works, or anything
    /// else driving `newt://claim`. In memory only: a Newt restart drops them,
    /// which fails safe, and a live agent re-claims on its next turn.
    let dynamicClaims = DynamicClaimRegistry()

    /// Called whenever `state` changes — the controller refreshes the menu.
    var onChange: (() -> Void)?
    /// Called with a user-facing message (e.g. helper needs approval).
    var onHelperMessage: ((String) -> Void)?
    /// Fired only when a timed session ends because its clock ran out — not on
    /// manual disengage, battery trip, or quit. The controller decides whether
    /// to post a system notification.
    var onTimerExpired: (() -> Void)?

    /// True when Newt is actually holding the Mac awake right now — a claim is
    /// up and no veto is refusing it. This, not the slider position, is what the
    /// icon, badge and tooltip reflect.
    var isActive: Bool { assertionsActive }

    /// True when the duration slider itself is holding a session, regardless of
    /// whether a veto is currently suppressing it.
    var hasSliderClaim: Bool { state != .off }

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

    /// Indicator dot diameter as a fraction of the icon's height. Adjustable
    /// because how visible a dot needs to be depends on the wallpaper behind
    /// the menu bar, which Newt can't see.
    var badgeSizeScale: Double = 0.46 {
        didSet {
            badgeSizeScale = max(0.30, min(0.70, badgeSizeScale))
            guard badgeSizeScale != oldValue else { return }
            UserDefaults.standard.set(badgeSizeScale, forKey: "BadgeSizeScale")
            onChange?()
        }
    }

    /// Outline the dot in the menu bar's own text colour. That colour is by
    /// definition legible against this menu bar, so the ring separates the dot
    /// from any wallpaper behind it.
    var badgeOutline = true {
        didSet {
            guard badgeOutline != oldValue else { return }
            UserDefaults.standard.set(badgeOutline, forKey: "BadgeOutline")
            onChange?()
        }
    }

    /// Slider position for the longest a dynamic claim may be held before Newt
    /// lets go of it. Position 0 ("off") and the top stop ("indefinite") both
    /// mean no limit; the stops between are the same 30m…24h ladder as Keep
    /// awake, so the control reads the same way.
    var dynamicClaimMaxPosition: Int = 0 {
        didSet {
            dynamicClaimMaxPosition = max(0, min(Self.sliderDurations.count - 1,
                                                 dynamicClaimMaxPosition))
            guard dynamicClaimMaxPosition != oldValue else { return }
            UserDefaults.standard.set(dynamicClaimMaxPosition,
                                      forKey: "DynamicClaimMaxPosition")
            applyDynamicClaimLimit()
            onChange?()
        }
    }

    /// Seconds a dynamic claim may live, or nil for no limit.
    var dynamicClaimMaxSeconds: TimeInterval? {
        let value = Self.sliderDurations[dynamicClaimMaxPosition]
        return value > 0 ? TimeInterval(value) : nil
    }

    private func applyDynamicClaimLimit() {
        dynamicClaims.maxLifetime = dynamicClaimMaxSeconds
    }

    /// Slider position for how long Newt stays idle before taking its icon out
    /// of the menu bar. Position 0 ("off") and the top stop ("never") both keep
    /// the icon on screen; the stops between are the same 30m…24h ladder as
    /// Keep awake.
    ///
    /// The top stop is the default, so the icon never disappears unless the
    /// user asks for it.
    var hideIconAfterPosition: Int = SleepManager.sliderDurations.count - 1 {
        didSet {
            hideIconAfterPosition = max(0, min(Self.sliderDurations.count - 1,
                                               hideIconAfterPosition))
            guard hideIconAfterPosition != oldValue else { return }
            UserDefaults.standard.set(hideIconAfterPosition,
                                      forKey: "HideIconAfterPosition")
            onChange?()
        }
    }

    /// Seconds Newt may sit idle before hiding its icon, or nil to never hide.
    var hideIconAfterSeconds: TimeInterval? {
        let value = Self.sliderDurations[hideIconAfterPosition]
        return value > 0 ? TimeInterval(value) : nil
    }

    /// The label for a `hideIconAfterPosition`. Deliberately not
    /// `displayString(forSliderPosition:)`: that renders the top stop as
    /// "indefinite", which on a *hide* control reads as the opposite of what it
    /// means.
    static func hideIconDisplayString(forSliderPosition p: Int) -> String {
        sliderDurations[max(0, min(sliderDurations.count - 1, p))] == -1
            ? "never" : displayString(forSliderPosition: p)
    }

    /// Spin the split dot while both a long-lived claim and a dynamic one are in
    /// force. Costs a repeating timer for as long as that lasts, so it's
    /// switchable.
    var badgeSpin = true {
        didSet {
            guard badgeSpin != oldValue else { return }
            UserDefaults.standard.set(badgeSpin, forKey: "BadgeSpin")
            onChange?()
        }
    }

    /// Custom indicator dot colours, or nil to use the system green/blue.
    ///
    /// Left unset by default on purpose: `systemGreen`/`systemBlue` are dynamic
    /// colours that adapt to appearance, and freezing them into stored
    /// components would lose that. Only an explicit pick is persisted.
    var scheduledBadgeColor: NSColor? {
        didSet {
            guard scheduledBadgeColor != oldValue else { return }
            Self.store(scheduledBadgeColor, forKey: "BadgeColorScheduled")
            onChange?()
        }
    }

    var dynamicBadgeColor: NSColor? {
        didSet {
            guard dynamicBadgeColor != oldValue else { return }
            Self.store(dynamicBadgeColor, forKey: "BadgeColorDynamic")
            onChange?()
        }
    }

    // MARK: - Menu bar icon
    //
    // Idle and awake are two complete, independent looks: each picks its own
    // backdrop and its own two colours. A transparent menu bar shows the
    // wallpaper through, and the lizard is a thin organic shape that a bright
    // one swallows, so the backdrop is what makes it legible at all.

    var idleBackdrop: IconBackdrop = .none {
        didSet {
            guard idleBackdrop != oldValue else { return }
            UserDefaults.standard.set(idleBackdrop.rawValue, forKey: "IconBackdropIdle")
            onChange?()
        }
    }

    var awakeBackdrop: IconBackdrop = .none {
        didSet {
            guard awakeBackdrop != oldValue else { return }
            UserDefaults.standard.set(awakeBackdrop.rawValue, forKey: "IconBackdropAwake")
            onChange?()
        }
    }

    var idleBackdropColor: NSColor? {
        didSet {
            guard idleBackdropColor != oldValue else { return }
            Self.store(idleBackdropColor, forKey: "IconColorBackdropIdle")
            onChange?()
        }
    }

    var awakeBackdropColor: NSColor? {
        didSet {
            guard awakeBackdropColor != oldValue else { return }
            Self.store(awakeBackdropColor, forKey: "IconColorBackdropAwake")
            onChange?()
        }
    }

    var idleCutout = false {
        didSet {
            guard idleCutout != oldValue else { return }
            UserDefaults.standard.set(idleCutout, forKey: "IconCutoutIdle")
            onChange?()
        }
    }

    var awakeCutout = false {
        didSet {
            guard awakeCutout != oldValue else { return }
            UserDefaults.standard.set(awakeCutout, forKey: "IconCutoutAwake")
            onChange?()
        }
    }

    var idleIconColor: NSColor? {
        didSet {
            guard idleIconColor != oldValue else { return }
            Self.store(idleIconColor, forKey: "IconColorGlyphIdle")
            onChange?()
        }
    }

    /// Colour to fill the lizard with while Newt is holding the Mac awake, or
    /// nil to leave it the menu bar's own text colour.
    var awakeIconColor: NSColor? {
        didSet {
            guard awakeIconColor != oldValue else { return }
            Self.store(awakeIconColor, forKey: "IconColorAwake")
            onChange?()
        }
    }

    /// Everything the status item needs to draw the icon.
    var badgeStyle: BadgeStyle {
        BadgeStyle(scale: badgeSizeScale,
                   outline: badgeOutline,
                   scheduled: scheduledBadgeColor ?? .systemGreen,
                   dynamic: dynamicBadgeColor ?? .systemBlue,
                   idle: IconLook(backdrop: idleBackdrop,
                                  backdropColor: idleBackdropColor,
                                  glyphColor: idleIconColor,
                                  cutout: idleCutout),
                   awake: IconLook(backdrop: awakeBackdrop,
                                   backdropColor: awakeBackdropColor,
                                   glyphColor: awakeIconColor,
                                   cutout: awakeCutout))
    }

    /// True when every colour — both icon looks and both dots — is automatic.
    /// The backdrop *shapes* aren't colours, so they're deliberately excluded:
    /// resetting colours shouldn't silently undo a style choice.
    var badgeColorsAreDefault: Bool {
        [scheduledBadgeColor, dynamicBadgeColor, idleBackdropColor,
         awakeBackdropColor, idleIconColor, awakeIconColor].allSatisfy { $0 == nil }
    }

    func resetBadgeColors() {
        scheduledBadgeColor = nil
        dynamicBadgeColor = nil
        idleBackdropColor = nil
        awakeBackdropColor = nil
        idleIconColor = nil
        awakeIconColor = nil
    }

    /// Stored as sRGB components rather than an archived `NSColor` so the value
    /// is legible in `defaults read` and can't break on an archive format change.
    private static func storedColor(forKey key: String) -> NSColor? {
        guard let parts = UserDefaults.standard.array(forKey: key) as? [Double],
              parts.count == 4 else { return nil }
        return NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: parts[3])
    }

    private static func store(_ color: NSColor?, forKey key: String) {
        guard let rgb = color?.usingColorSpace(.sRGB) else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(
            [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent],
            forKey: key)
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

    /// Whether the weekly schedule gets a vote. Off by default so an upgrade
    /// never starts holding the Mac awake on its own.
    private(set) var scheduleEnabled = false

    /// The weekly awake windows. Only consulted when `scheduleEnabled`.
    private(set) var schedule = WeeklySchedule.workweek

    /// When set and still in the future, every claim is refused. `.distantFuture`
    /// means "until the user clears it" — see `setSuppressed(_:)`.
    private(set) var suppressedUntil: Date?

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
            self.onHelperMessage?("Held off keep-awake — battery hit \(self.battery.thresholdPercent)%")
        }
        // Every poll, so the veto lifts again once the charge or the power
        // source recovers — the claims themselves are never torn down.
        battery.onEvaluate = { [weak self] in self?.reconcile(notify: false) }
        // Plug/unplug while engaged: suspend or resume the display assertion if
        // "pause on battery" is on. Other mechanisms are untouched.
        // Reconcile first: plugging back in can lift the battery veto and
        // rebuild the assertions, and only then is there a display assertion
        // for `reevaluateDisplay` to adjust.
        battery.onPowerChange = { [weak self] in
            self?.reconcile()
            self?.reevaluateDisplay()
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
        badgeSizeScale = defaults.object(forKey: "BadgeSizeScale") as? Double ?? 0.46
        badgeOutline = defaults.object(forKey: "BadgeOutline") as? Bool ?? true
        badgeSpin = defaults.object(forKey: "BadgeSpin") as? Bool ?? true
        scheduledBadgeColor = Self.storedColor(forKey: "BadgeColorScheduled")
        dynamicBadgeColor = Self.storedColor(forKey: "BadgeColorDynamic")
        idleIconColor = Self.storedColor(forKey: "IconColorGlyphIdle")
        awakeIconColor = Self.storedColor(forKey: "IconColorAwake")
        idleBackdropColor = Self.storedColor(forKey: "IconColorBackdropIdle")
        awakeBackdropColor = Self.storedColor(forKey: "IconColorBackdropAwake")
        idleBackdrop = (defaults.string(forKey: "IconBackdropIdle")
            .flatMap(IconBackdrop.init(rawValue:))) ?? .none
        awakeBackdrop = (defaults.string(forKey: "IconBackdropAwake")
            .flatMap(IconBackdrop.init(rawValue:))) ?? .none
        idleCutout = defaults.bool(forKey: "IconCutoutIdle")
        awakeCutout = defaults.bool(forKey: "IconCutoutAwake")
        // Weekly schedule. Missing keys → the workweek default, switched off.
        scheduleEnabled = defaults.object(forKey: "ScheduleEnabled") as? Bool ?? false
        schedule = WeeklySchedule.load()
        if let stamp = defaults.object(forKey: "SuppressedUntil") as? Double {
            suppressedUntil = Date(timeIntervalSinceReferenceDate: stamp)
        }
        dynamicClaims.onChange = { [weak self] in self?.reconcile() }
        dynamicClaims.onExpired = { [weak self] claim in
            guard let self else { return }
            let held = SleepManager.displayString(forSliderPosition: self.dynamicClaimMaxPosition)
            self.onHelperMessage?("Released \(claim.agent) — \(claim.label): held over \(held)")
        }
        dynamicClaimMaxPosition = defaults.object(forKey: "DynamicClaimMaxPosition") as? Int ?? 0
        applyDynamicClaimLimit()
        hideIconAfterPosition = defaults.object(forKey: "HideIconAfterPosition") as? Int
            ?? Self.sliderDurations.count - 1
        registerSystemObservers()
    }

    deinit {
        systemObservers.forEach { $0.center.removeObserver($0.token) }
    }

    /// The boundary timer is a wall-clock appointment, and three things move the
    /// wall clock out from under it: the Mac sleeping through the fire date, the
    /// clock being set, and a time-zone change. Each just re-runs the decision.
    private func registerSystemObservers() {
        let reconcileOnEvent: (Notification) -> Void = { [weak self] _ in self?.reconcile() }
        let workspace = NSWorkspace.shared.notificationCenter
        systemObservers.append((workspace, workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main, using: reconcileOnEvent)))
        for name in [Notification.Name.NSSystemClockDidChange,
                     Notification.Name.NSSystemTimeZoneDidChange] {
            systemObservers.append((.default, NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main, using: reconcileOnEvent)))
        }
    }

    func setLeftClickAction(_ action: LeftClickAction) {
        guard action != leftClickAction else { return }
        leftClickAction = action
        UserDefaults.standard.set(action.rawValue, forKey: "LeftClickAction")
        onChange?()
    }

    /// Drive a left-click on the menu bar icon. The controller calls this only
    /// when `leftClickAction != .openMenu`. Clicking "off" has to silence every
    /// claim or the click looks ignored, so it suppresses the schedule too;
    /// clicking "on" first lifts any suppression it finds.
    func performLeftClickToggle() {
        if isActive {
            setSliderPosition(0)
            if scheduleClaimEnd != nil { setSuppressed(true) }
            return
        }
        if isSuppressed {
            setSuppressed(false)
            if isActive { return }
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
        // Not just onChange — dropping the last enabled mode has to release
        // everything, and re-adding the first has to build it back up.
        reconcile()
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
    /// drift apart. A veto arriving mid-session only pauses the claim, but an
    /// explicit request to start one is refused outright and told why.
    private func canEngage() -> String? {
        if enabledModes.isEmpty {
            return "Enable at least one wake mode in the menu"
        }
        if let blocked = blockedByBattery {
            return "Can't engage — battery \(blocked.percent)% is at or below your \(blocked.threshold)% floor"
        }
        if isSuppressed {
            return "Can't engage — Newt is suppressed. Untick Suppress in the menu."
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

    /// Launch-time catch-up. Re-engages the slider claim Newt had when it last
    /// stopped running, if "Resume last state at launch" is on —
    /// `EngagedSliderPosition` is written on every engage/disengage, so this
    /// survives crashes and `killall`, and an expired or manually-ended session
    /// correctly stays off. Goes through `setSliderPosition`, so the battery
    /// floor and wake-mode guards apply as if the user moved the slider.
    ///
    /// Always reconciles afterwards, so a schedule block already in progress
    /// takes effect at launch regardless of that setting.
    func resumeIfNeeded() {
        if resumeOnLaunch, !hasSliderClaim {
            let p = UserDefaults.standard.integer(forKey: "EngagedSliderPosition")
            if p > 0 { setSliderPosition(p) }
        }
        reconcile()
    }

    // MARK: - Claims and vetoes

    /// End of the schedule block in progress, or nil when the schedule isn't
    /// asking for anything right now.
    var scheduleClaimEnd: Date? {
        guard scheduleEnabled else { return nil }
        return schedule.blockEnd(covering: Date())
    }

    /// True while the manual suppress veto is in force.
    var isSuppressed: Bool {
        guard let until = suppressedUntil else { return false }
        return until > Date()
    }

    /// True when something is asking Newt to stay awake, whether or not a veto
    /// is currently refusing it.
    var hasAnyClaim: Bool {
        hasSliderClaim || scheduleClaimEnd != nil || !dynamicClaims.isEmpty
    }

    private var shouldHoldAwake: Bool {
        guard blockedByBattery == nil, !isSuppressed, !enabledModes.isEmpty else { return false }
        return hasAnyClaim
    }

    /// Apply or release everything to match the current claims and vetoes.
    /// Idempotent and safe to call from any event — a timer edge, a power
    /// change, a menu toggle, waking from sleep.
    ///
    /// `notify` is for callers that change something the menu shows without
    /// changing whether Newt is engaged. The battery poll passes false, so a
    /// quiet 15-second tick doesn't redraw the status icon forever.
    private func reconcile(notify: Bool = true) {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        clearExpiredSuppression()
        // Before computing the answer: enabling the monitor polls immediately,
        // which re-enters here and is dropped by the guard above.
        updateBatteryMonitor()

        let wasActive = assertionsActive
        let want = shouldHoldAwake
        if want && !assertionsActive {
            createAssertions()
            if enabledModes.contains(.lidClosed) {
                helper.setDisableSleep(true) { [weak self] _, err in
                    if let err { self?.onHelperMessage?(err) }
                }
            }
        } else if !want && assertionsActive {
            releaseAssertions()
            helper.setDisableSleep(false) { _, _ in }
        }

        scheduleExpiry()
        scheduleDisplayWindowTimer()
        scheduleBoundaryTimer()
        if notify || assertionsActive != wasActive { onChange?() }
    }

    /// The battery has to stay watched whenever a claim exists, not just while
    /// engaged — otherwise nothing would notice the charge recovering and lift
    /// the veto.
    private func updateBatteryMonitor() {
        let claimPossible = hasSliderClaim
            || (scheduleEnabled && !schedule.isEmpty)
            || !dynamicClaims.isEmpty
        if claimPossible { battery.enable() } else { battery.disable() }
    }

    private func clearExpiredSuppression() {
        guard let until = suppressedUntil, until <= Date() else { return }
        suppressedUntil = nil
        UserDefaults.standard.removeObject(forKey: "SuppressedUntil")
    }

    /// Wake at the next moment the answer could change: a schedule edge, or the
    /// suppression expiring.
    private func scheduleBoundaryTimer() {
        var fire: Date?
        if scheduleEnabled, let next = schedule.nextBoundary(after: Date()) {
            fire = next
        }
        if let until = suppressedUntil, until < .distantFuture {
            fire = min(fire ?? until, until)
        }
        // A second past the edge, so re-arming can't land on the same instant
        // and spin.
        let target = fire?.addingTimeInterval(1)
        // reconcile() runs on every battery poll; re-arming an identical timer
        // four times a minute is pure churn.
        if boundaryTimer?.isValid == true, boundaryTimer?.fireDate == target { return }
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        guard let target else { return }
        let t = Timer(fire: target, interval: 0, repeats: false) { [weak self] _ in
            self?.reconcile()
        }
        RunLoop.main.add(t, forMode: .common)
        boundaryTimer = t
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
    /// ("1h 23m/20:46", "+1" marking an end that lands tomorrow). Describes the
    /// slider's own claim; when a veto is in force it says so instead, since the
    /// countdown would otherwise imply the Mac is being held awake.
    func displayString() -> String {
        if isSuppressed { return "suppressed" }
        if let blocked = blockedByBattery { return "held off — battery \(blocked.percent)%" }
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
    static func clockString(_ date: Date) -> String {
        let time = clockFormatter.string(from: date)
        return Calendar.current.isDateInTomorrow(date) ? "\(time)+1" : time
    }

    /// Follows the system's locale and 12/24-hour setting — a hardcoded "HH:mm"
    /// gets rewritten by the 24-Hour Time override anyway.
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
            // A bounce during the handshake (first launch after an update) drops
            // XPC, and the helper's disconnect safety resets `disablesleep` — so
            // a launch-time resume would silently lose lid-close protection.
            // Re-asserting is idempotent.
            if self.isActive, self.enabledModes.contains(.lidClosed) {
                self.helper.setDisableSleep(true) { [weak self] _, err in
                    if let err { self?.onHelperMessage?(err) }
                }
            }
        }
    }

    // MARK: - Engage / disengage

    /// Raise the slider claim. Whether that actually applies assertions is
    /// `reconcile()`'s call — a veto can be in force.
    private func engage(_ newState: AwakeState, durationSeconds: Int) {
        state = newState
        activeDurationSeconds = durationSeconds
        // Live engagement record for "Resume last state at launch" — written on
        // every transition (not just clean quit) so it survives crashes.
        UserDefaults.standard.set(sliderPosition, forKey: "EngagedSliderPosition")
        reconcile()
    }

    /// Drop the slider claim. The Mac may well stay awake afterwards — the
    /// schedule is a separate claim and this doesn't touch it.
    func disengage() {
        state = .off
        activeDurationSeconds = 0
        sliderPosition = 0
        UserDefaults.standard.set(0, forKey: "EngagedSliderPosition")
        reconcile()
    }

    /// App-termination teardown: releases everything unconditionally — claims
    /// don't outlive the process — but preserves the resume record, since
    /// quitting while engaged must count as "engaged at quit" for
    /// `resumeIfNeeded()`.
    func shutdown() {
        let p = sliderPosition
        state = .off
        activeDurationSeconds = 0
        sliderPosition = 0
        expiryTimer?.invalidate()
        expiryTimer = nil
        displayWindowTimer?.invalidate()
        displayWindowTimer = nil
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        battery.disable()
        releaseAssertions()
        helper.setDisableSleep(false) { _, _ in }
        if p > 0 { UserDefaults.standard.set(p, forKey: "EngagedSliderPosition") }
    }

    private func scheduleExpiry() {
        var until: Date?
        if case .timed(let u) = state { until = u }
        // reconcile() re-runs this on every battery poll; tearing down and
        // rebuilding an identical timer four times a minute risks re-arming it
        // across the instant it was due to fire.
        if expiryTimer?.isValid == true, expiryTimer?.fireDate == until { return }
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let until else { return }
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

    // MARK: - Weekly schedule

    func setScheduleEnabled(_ on: Bool) {
        guard on != scheduleEnabled else { return }
        scheduleEnabled = on
        UserDefaults.standard.set(on, forKey: "ScheduleEnabled")
        reconcile()
    }

    func setSchedule(_ new: WeeklySchedule) {
        let normalized = new.normalized()
        guard normalized != schedule else { return }
        schedule = normalized
        normalized.save()
        reconcile()
    }

    /// Turn the manual veto on or off. Switching it on lasts until the end of
    /// the block in progress, or the start of the next one if none is — so
    /// "not today, thanks" doesn't also cancel tomorrow. With no schedule to
    /// hang that on, it stays until cleared by hand.
    func setSuppressed(_ on: Bool) {
        if on {
            let until: Date
            if let end = scheduleClaimEnd {
                until = end
            } else if scheduleEnabled, let next = schedule.nextStart(after: Date()) {
                until = next
            } else {
                until = .distantFuture
            }
            suppressedUntil = until
            UserDefaults.standard.set(until.timeIntervalSinceReferenceDate, forKey: "SuppressedUntil")
        } else {
            suppressedUntil = nil
            UserDefaults.standard.removeObject(forKey: "SuppressedUntil")
        }
        reconcile()
    }

    /// One-line summary of the dynamic claims in force, for the menu. nil when
    /// none are.
    func dynamicStatusString() -> String? {
        let claims = dynamicClaims.sortedClaims
        guard let first = claims.first else { return nil }
        if claims.count == 1 { return "\(first.agent) is working — \(first.label)" }
        return "\(claims.count) agents working"
    }

    /// Everything holding the Mac awake right now, one line each, for the icon's
    /// tooltip. Empty when nothing is — including when a veto is refusing, since
    /// then the claims exist but aren't doing anything.
    func awakeReasons() -> [String] {
        guard isActive else { return [] }
        var lines: [String] = []
        switch state {
        case .off:
            break
        case .indefinite:
            lines.append("Keep awake — indefinite")
        case .timed(let until):
            lines.append("Keep awake — \(Self.formatRemaining(until.timeIntervalSinceNow))"
                         + " left, until \(Self.clockString(until))")
        }
        if let end = scheduleClaimEnd {
            lines.append("Schedule — until \(Self.clockString(end))")
        }
        lines.append(contentsOf: dynamicClaims.sortedClaims.map(\.menuTitle))
        return lines
    }

    /// What the schedule is doing, short enough to sit on the end of the "Use
    /// schedule" menu item rather than taking a row of its own. nil when the
    /// schedule is switched off and has nothing to say.
    func scheduleSummary() -> String? {
        guard scheduleEnabled else { return nil }
        if isSuppressed {
            guard let until = suppressedUntil, until < .distantFuture else {
                return "suppressed"
            }
            return "suppressed until \(Self.clockString(until))"
        }
        if let end = scheduleClaimEnd {
            return "awake until \(Self.clockString(end))"
        }
        guard let next = schedule.nextStart(after: Date()) else {
            return "no hours set"
        }
        return "next \(Self.dayTimeString(next))"
    }

    /// "Mon 8:00" — day plus time, in the user's locale and 12/24-hour setting.
    private static func dayTimeString(_ date: Date) -> String {
        dayTimeFormatter.string(from: date)
    }

    private static let dayTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("EEE jmm")
        return f
    }()

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

/// What sits behind the lizard so a transparent menu bar can't swallow it.
enum IconBackdrop: String, CaseIterable {
    case none, outline, glow, circle

    var menuTitle: String {
        switch self {
        case .none:    return "None"
        case .outline: return "Outline"
        case .glow:    return "Glow"
        case .circle:  return "Circle"
        }
    }
}

/// How the menu bar icon is drawn in one state. Newt keeps two of these — idle
/// and awake — and they're independent, so the icon can change shape as well as
/// colour when something starts holding the Mac awake.
///
/// A nil colour means "work it out": the glyph follows the menu bar's own text
/// colour, and the backdrop takes whatever contrasts with the glyph. Storing the
/// resolved colour instead would freeze it, and it would stop adapting when the
/// menu bar flips between light and dark.
struct IconLook {
    var backdrop: IconBackdrop = .none
    var backdropColor: NSColor?
    var glyphColor: NSColor?
    /// Punch the lizard out of the backdrop rather than filling it, so the
    /// wallpaper shows through the glyph. Only a backdrop that is actually
    /// opaque has anything to cut it out of, so this applies to `.circle` alone.
    var cutout = false

    var cutsOut: Bool { cutout && backdrop == .circle }
}

/// How the menu bar indicator dot is drawn. Colors are configurable because
/// which ones stand out depends on the wallpaper behind the menu bar, which
/// Newt can't see; the *meaning* of each is fixed.
struct BadgeStyle {
    var scale: Double = 0.46
    var outline: Bool = true
    /// Slider or schedule — the long-lived claims.
    var scheduled: NSColor = .systemGreen
    /// Dynamic claims, usually an AI agent mid-turn.
    var dynamic: NSColor = .systemBlue
    var idle = IconLook()
    var awake = IconLook()
    /// Radians the split is turned through. Only the two-tone "both" dot uses
    /// it — a solid disc looks identical however far you rotate it.
    var rotation: Double = 0
}
