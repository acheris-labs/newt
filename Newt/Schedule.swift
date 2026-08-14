import Foundation

/// One awake window inside a single day, in half-hour indices (0…48, minute =
/// idx*30) — the same unit the display-on window uses. `end <= start` means the
/// block runs past midnight and finishes on the following day.
struct ScheduleBlock: Codable, Equatable {
    var start: Int
    var end: Int

    var wrapsMidnight: Bool { end <= start }

    /// Length in half-hour steps, counting the wrap into the next day.
    var steps: Int { wrapsMidnight ? (end + WeeklySchedule.stepsPerDay) - start : end - start }

    /// Whether a half-hour index falls inside this block, counting the wrap
    /// into the next day.
    func contains(step: Int) -> Bool {
        let unwrappedEnd = wrapsMidnight ? end + WeeklySchedule.stepsPerDay : end
        return (step >= start && step < unwrappedEnd)
            || (step + WeeklySchedule.stepsPerDay >= start
                && step + WeeklySchedule.stepsPerDay < unwrappedEnd)
    }

    var label: String {
        "\(halfHourLabel(start))–\(halfHourLabel(end))\(wrapsMidnight ? "+1" : "")"
    }
}

/// A repeating week of awake windows. Day 0 is always Monday regardless of the
/// locale's first weekday, so the stored form is stable across machines.
struct WeeklySchedule: Codable, Equatable {
    static let stepsPerDay = 48
    static let dayCount = 7

    private(set) var days: [[ScheduleBlock]]

    init(days: [[ScheduleBlock]]) {
        var d = days
        while d.count < Self.dayCount { d.append([]) }
        self.days = Array(d.prefix(Self.dayCount))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(days: try container.decode([[ScheduleBlock]].self, forKey: .days))
    }

    static let empty = WeeklySchedule(days: Array(repeating: [], count: dayCount))

    /// Fresh-install default: Mon–Fri 08:00–20:00, weekends clear.
    static let workweek = WeeklySchedule(days: (0 ..< dayCount).map { day in
        day < 5 ? [ScheduleBlock(start: 16, end: 40)] : []
    })

    var isEmpty: Bool { days.allSatisfy(\.isEmpty) }

    func blocks(onDay day: Int) -> [ScheduleBlock] {
        days.indices.contains(day) ? days[day] : []
    }

    /// Replace one day's blocks, keeping the week sorted and overlap-free.
    func setting(day: Int, blocks: [ScheduleBlock]) -> WeeklySchedule {
        guard days.indices.contains(day) else { return self }
        var d = days
        d[day] = Self.merge(blocks)
        return WeeklySchedule(days: d)
    }

    func normalized() -> WeeklySchedule {
        WeeklySchedule(days: days.map(Self.merge))
    }

    /// Sort by start and coalesce anything that overlaps or abuts. A run that
    /// grows to cover a full day collapses to a single 00:00–24:00 block, which
    /// keeps `wrapsMidnight` from being ambiguous with "all day".
    private static func merge(_ blocks: [ScheduleBlock]) -> [ScheduleBlock] {
        let cleaned = blocks
            .map { b -> ScheduleBlock in
                let s = max(0, min(stepsPerDay - 1, b.start))
                let e = max(0, min(stepsPerDay, b.end))
                // end == start is a wrap all the way round to itself — a full day.
                if e == s { return ScheduleBlock(start: 0, end: stepsPerDay) }
                return ScheduleBlock(start: s, end: e)
            }
            .sorted { $0.start < $1.start }
        guard var current = cleaned.first else { return [] }
        var out: [ScheduleBlock] = []
        // Work in an unwrapped end (may exceed 48) so the comparisons are plain
        // integer maths; only the final block can legitimately wrap.
        var currentEnd = current.wrapsMidnight ? current.end + stepsPerDay : current.end
        for next in cleaned.dropFirst() {
            let nextEnd = next.wrapsMidnight ? next.end + stepsPerDay : next.end
            if next.start <= currentEnd {
                currentEnd = max(currentEnd, nextEnd)
            } else {
                out.append(rewrap(start: current.start, unwrappedEnd: currentEnd))
                current = next
                currentEnd = nextEnd
            }
        }
        out.append(rewrap(start: current.start, unwrappedEnd: currentEnd))
        // A wrapping tail can swallow an early block of the same day; re-merge
        // once so 22:00–02:00 plus 00:00–06:00 doesn't stay as two rows.
        if let last = out.last, last.wrapsMidnight, out.count > 1,
           let first = out.first, first.start < last.end {
            let head = out.removeFirst()
            let tail = out.removeLast()
            let joined = rewrap(start: tail.start,
                                unwrappedEnd: max(tail.end + stepsPerDay,
                                                  head.end + stepsPerDay))
            out.append(joined)
        }
        return out
    }

    private static func rewrap(start: Int, unwrappedEnd: Int) -> ScheduleBlock {
        if unwrappedEnd >= start + stepsPerDay { return ScheduleBlock(start: 0, end: stepsPerDay) }
        if unwrappedEnd > stepsPerDay { return ScheduleBlock(start: start, end: unwrappedEnd - stepsPerDay) }
        return ScheduleBlock(start: start, end: unwrappedEnd)
    }

    // MARK: - Wall-clock evaluation

    /// End of the block currently in progress, or nil when `date` isn't covered.
    func blockEnd(covering date: Date, calendar: Calendar = .current) -> Date? {
        intervals(around: date, back: 1, forward: 1, calendar: calendar)
            .first { $0.start <= date && date < $0.end }?
            .end
    }

    /// Next moment the schedule's answer changes — a block starting or ending.
    /// nil for an empty schedule (nothing will ever change on its own).
    func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date? {
        intervals(around: date, back: 1, forward: 8, calendar: calendar)
            .flatMap { [$0.start, $0.end] }
            .filter { $0 > date }
            .min()
    }

    /// Start of the next block, skipping one already in progress.
    func nextStart(after date: Date, calendar: Calendar = .current) -> Date? {
        intervals(around: date, back: 0, forward: 8, calendar: calendar)
            .map(\.start)
            .filter { $0 > date }
            .min()
    }

    /// Every block anchored on a calendar day in the window, resolved to
    /// absolute dates. Blocks are anchored to the day they *start* on, so the
    /// window reaches one day back to catch a wrap that's still running.
    private func intervals(around date: Date, back: Int, forward: Int,
                           calendar: Calendar) -> [(start: Date, end: Date)] {
        guard !isEmpty else { return [] }
        let today = calendar.startOfDay(for: date)
        var out: [(start: Date, end: Date)] = []
        for offset in -back ... forward {
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: today),
                  let nextDayStart = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { continue }
            for block in blocks(onDay: Self.mondayIndex(of: dayStart, calendar: calendar)) {
                let start = Self.date(dayStart: dayStart, halfHour: block.start,
                                      nextDayStart: nextDayStart, calendar: calendar)
                let end: Date
                if block.wrapsMidnight {
                    guard let dayAfter = calendar.date(byAdding: .day, value: 1, to: nextDayStart)
                    else { continue }
                    end = Self.date(dayStart: nextDayStart, halfHour: block.end,
                                    nextDayStart: dayAfter, calendar: calendar)
                } else {
                    end = Self.date(dayStart: dayStart, halfHour: block.end,
                                    nextDayStart: nextDayStart, calendar: calendar)
                }
                if end > start { out.append((start, end)) }
            }
        }
        return out
    }

    /// 0 = Monday. `Calendar.weekday` is 1 = Sunday, and its `firstWeekday` is
    /// locale-dependent, so neither can be used as the storage index directly.
    static func mondayIndex(of date: Date, calendar: Calendar = .current) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    /// Resolve a half-hour index to wall-clock time on a given day. Built from
    /// date components rather than by adding minutes so that 08:00 stays 08:00
    /// on the two DST days, where the day is 23 or 25 hours long.
    private static func date(dayStart: Date, halfHour idx: Int,
                             nextDayStart: Date, calendar: Calendar) -> Date {
        if idx >= stepsPerDay { return nextDayStart }
        var c = calendar.dateComponents([.year, .month, .day], from: dayStart)
        c.hour = idx / 2
        c.minute = (idx % 2) * 30
        return calendar.date(from: c) ?? dayStart
    }

    // MARK: - Persistence

    private static let defaultsKey = "ScheduleBlocks"

    static func load() -> WeeklySchedule {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(WeeklySchedule.self, from: data)
        else { return .workweek }
        return decoded.normalized()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

/// "8:00" / "20:30" / "24:00" for a half-hour index. Deliberately 24-hour and
/// locale-independent: it labels a grid axis, where a stack of "8:00 PM" would
/// not fit and column alignment matters more than local convention.
func halfHourLabel(_ idx: Int) -> String {
    String(format: "%d:%02d", idx / 2, (idx % 2) * 30)
}

/// Short day names for the editor, Monday first to match the storage order.
let scheduleDayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
