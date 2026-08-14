import AppKit

/// Seven day rows of draggable awake windows, half-hour snapped. Custom-drawn
/// for the same reason `RangeSliderView` is — AppKit has no multi-range control
/// — and it commits on mouse-up, so a drag is one edit rather than dozens.
final class ScheduleGridView: NSView {
    var onChange: ((WeeklySchedule) -> Void)?

    private var schedule: WeeklySchedule
    private var enabled: Bool

    private let gutter: CGFloat = 44
    private let trackX: CGFloat = 52
    private let stepW: CGFloat = 10
    private let rulerH: CGFloat = 20
    private let rowH: CGFloat = 26
    private let rowGap: CGFloat = 4
    private let edgeGrab: CGFloat = 7
    private var trackW: CGFloat { stepW * CGFloat(WeeklySchedule.stepsPerDay) }

    private enum DragMode { case move, resizeStart, resizeEnd, create }
    private var dragMode: DragMode?
    /// The day being edited, its blocks in flight, and which one is moving.
    /// Held apart from `schedule` because committing would merge and renumber
    /// mid-drag, and the index would stop meaning anything.
    private var dragDay = 0
    private var dragBlocks: [ScheduleBlock] = []
    private var dragIndex = 0
    private var dragAnchorStep = 0
    private var dragGrabOffset = 0
    private var selection: (day: Int, index: Int)?

    init(schedule: WeeklySchedule, enabled: Bool) {
        self.schedule = schedule
        self.enabled = enabled
        super.init(frame: .zero)
        let height = rulerH + CGFloat(WeeklySchedule.dayCount) * (rowH + rowGap)
        // Trailing pad leaves room for the "24:00" ruler label, which is centred
        // on the track's right edge and would otherwise be clipped.
        frame = NSRect(x: 0, y: 0, width: trackX + trackW + 20, height: height)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Sync from `SleepManager`. Ignored mid-drag so an external refresh can't
    /// yank the block out from under the pointer.
    func refresh(schedule: WeeklySchedule, enabled: Bool) {
        guard dragMode == nil else {
            self.enabled = enabled
            return
        }
        // The menu's 1 Hz tick reaches this while the editor is open, so bail
        // out when there is genuinely nothing to redraw.
        guard schedule != self.schedule || enabled != self.enabled else { return }
        if schedule != self.schedule { selection = nil }
        self.enabled = enabled
        self.schedule = schedule
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Geometry

    private func rowY(_ day: Int) -> CGFloat { rulerH + CGFloat(day) * (rowH + rowGap) }

    private func rowRect(_ day: Int) -> NSRect {
        NSRect(x: trackX, y: rowY(day), width: trackW, height: rowH)
    }

    private func x(forStep step: Int) -> CGFloat { trackX + CGFloat(step) * stepW }

    private func step(atX px: CGFloat) -> Int { Int(((px - trackX) / stepW).rounded()) }

    /// The row containing a y coordinate, allowing values outside the view so a
    /// drag can run past the last row. Gaps between rows resolve to the row above.
    private func row(atY py: CGFloat) -> Int {
        Int(floor((py - rulerH) / (rowH + rowGap)))
    }

    /// Blocks to draw for a day — the in-flight copy while dragging it.
    private func blocks(day: Int) -> [ScheduleBlock] {
        dragMode != nil && day == dragDay ? dragBlocks : schedule.blocks(onDay: day)
    }

    /// The visible span of a block on its own row, in half-hour steps. A block
    /// that wraps is clipped at midnight here; the remainder is drawn on the
    /// next row by `spill(intoDay:)`.
    private func primarySpan(_ b: ScheduleBlock) -> (start: Int, end: Int) {
        (b.start, b.wrapsMidnight ? WeeklySchedule.stepsPerDay : b.end)
    }

    /// How far the previous day's wrapping block reaches into this row, in
    /// steps. 0 when nothing spills in.
    private func spill(intoDay day: Int) -> Int {
        let previous = (day + WeeklySchedule.dayCount - 1) % WeeklySchedule.dayCount
        return blocks(day: previous).first(where: \.wrapsMidnight)?.end ?? 0
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        drawRuler()
        let accent = NSColor.controlAccentColor.withAlphaComponent(enabled ? 1 : 0.4)
        for day in 0 ..< WeeklySchedule.dayCount {
            drawDayLabel(day)
            let track = rowRect(day)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 4, yRadius: 4).fill()
            drawGridlines(in: track)

            let spillSteps = spill(intoDay: day)
            if spillSteps > 0 {
                // The tail of the previous day's overnight block. Deliberately
                // faint and untouchable — it is edited from the row that owns it.
                accent.withAlphaComponent(enabled ? 0.3 : 0.15).setFill()
                NSBezierPath(roundedRect: blockRect(day: day, from: 0, to: spillSteps),
                             xRadius: 4, yRadius: 4).fill()
            }

            for (index, block) in blocks(day: day).enumerated() {
                let span = primarySpan(block)
                let rect = blockRect(day: day, from: span.start, to: span.end)
                accent.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                if selection?.day == day && selection?.index == index {
                    NSColor.labelColor.setStroke()
                    let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
                                            xRadius: 4, yRadius: 4)
                    ring.lineWidth = 1.5
                    ring.stroke()
                }
                drawBlockLabel(block, in: rect)
            }
        }
    }

    private func blockRect(day: Int, from: Int, to: Int) -> NSRect {
        NSRect(x: x(forStep: from), y: rowY(day),
               width: CGFloat(to - from) * stepW, height: rowH)
    }

    private func drawRuler() {
        let font = NSFont.systemFont(ofSize: 9)
        for hour in stride(from: 0, through: 24, by: 3) {
            let px = x(forStep: hour * 2)
            let text = halfHourLabel(hour * 2) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: px - size.width / 2, y: 2), withAttributes: attrs)
        }
    }

    private func drawGridlines(in track: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        for hour in stride(from: 3, through: 21, by: 3) {
            let px = x(forStep: hour * 2)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: px, y: track.minY))
            line.line(to: NSPoint(x: px, y: track.maxY))
            line.lineWidth = 1
            line.stroke()
        }
    }

    private func drawDayLabel(_ day: Int) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor
        ]
        let text = scheduleDayNames[day] as NSString
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: gutter - size.width,
                              y: rowY(day) + (rowH - size.height) / 2),
                  withAttributes: attrs)
    }

    /// The times, drawn inside the block when it's wide enough to hold them.
    private func drawBlockLabel(_ block: ScheduleBlock, in rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = block.label as NSString
        let size = text.size(withAttributes: attrs)
        guard size.width + 10 < rect.width else { return }
        text.draw(at: NSPoint(x: rect.midX - size.width / 2,
                              y: rect.midY - size.height / 2),
                  withAttributes: attrs)
    }

    // MARK: - Hit testing

    private enum Hit {
        case block(day: Int, index: Int, mode: DragMode, grabOffset: Int)
        case track(day: Int, step: Int)
    }

    private func hit(at point: NSPoint) -> Hit? {
        let day = row(atY: point.y)
        guard (0 ..< WeeklySchedule.dayCount).contains(day) else { return nil }
        let track = rowRect(day)
        guard point.y >= track.minY, point.y <= track.maxY,
              point.x >= trackX, point.x <= trackX + trackW
        else { return nil }

        for (index, block) in blocks(day: day).enumerated() {
            let span = primarySpan(block)
            let left = x(forStep: span.start)
            let right = x(forStep: span.end)
            guard point.x >= left, point.x <= right else { continue }
            let mode: DragMode
            if point.x - left <= edgeGrab {
                mode = .resizeStart
            } else if right - point.x <= edgeGrab {
                mode = .resizeEnd
            } else {
                mode = .move
            }
            return .block(day: day, index: index, mode: mode,
                          grabOffset: step(atX: point.x) - block.start)
        }
        return .track(day: day, step: max(0, min(WeeklySchedule.stepsPerDay - 1, step(atX: point.x))))
    }

    // MARK: - Mouse (commit on mouse-up)

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard let target = hit(at: point) else {
            selection = nil
            needsDisplay = true
            return
        }
        switch target {
        case let .block(day, index, mode, grabOffset):
            beginDrag(day: day, blocks: schedule.blocks(onDay: day), index: index, mode: mode)
            dragGrabOffset = grabOffset
            dragAnchorStep = step(atX: point.x)
        case let .track(day, start):
            var blocks = schedule.blocks(onDay: day)
            // A plain click with no drag leaves a one-hour block.
            let end = min(WeeklySchedule.stepsPerDay, start + 2)
            blocks.append(ScheduleBlock(start: start, end: end))
            beginDrag(day: day, blocks: blocks, index: blocks.count - 1, mode: .create)
            dragAnchorStep = start
        }
        needsDisplay = true
    }

    private func beginDrag(day: Int, blocks: [ScheduleBlock], index: Int, mode: DragMode) {
        dragDay = day
        dragBlocks = blocks
        dragIndex = index
        dragMode = mode
        selection = (day, index)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mode = dragMode, dragBlocks.indices.contains(dragIndex) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let steps = WeeklySchedule.stepsPerDay
        let raw = step(atX: point.x)
        var block = dragBlocks[dragIndex]

        switch mode {
        case .create:
            let here = clampStep(raw)
            let low = min(here, dragAnchorStep, steps - 1)
            block = ScheduleBlock(start: low, end: max(here, dragAnchorStep, low + 1))

        case .move:
            let length = block.steps
            let newStart = max(0, min(steps - 1, raw - dragGrabOffset))
            let unwrappedEnd = newStart + length
            block = ScheduleBlock(start: newStart,
                                  end: unwrappedEnd > steps ? unwrappedEnd - steps : unwrappedEnd)

        case .resizeStart:
            let unwrappedEnd = block.wrapsMidnight ? block.end + steps : block.end
            block.start = max(0, min(unwrappedEnd - 1, min(steps - 1, clampStep(raw))))

        case .resizeEnd:
            // Dragging down into the next row is how an overnight block is made:
            // the pointer is literally in tomorrow.
            let rowDelta = row(atY: point.y) - dragDay
            let unwrapped = rowDelta >= 1 ? steps + clampStep(raw) : clampStep(raw)
            let bounded = max(block.start + 1, min(block.start + steps, unwrapped))
            block.end = bounded > steps ? bounded - steps : bounded
        }

        dragBlocks[dragIndex] = block
        needsDisplay = true
    }

    private func clampStep(_ s: Int) -> Int { max(0, min(WeeklySchedule.stepsPerDay, s)) }

    override func mouseUp(with event: NSEvent) {
        guard dragMode != nil else { return }
        let day = dragDay
        let blocks = dragBlocks
        let edited = dragBlocks.indices.contains(dragIndex) ? dragBlocks[dragIndex] : nil
        dragMode = nil
        commit(day: day, blocks: blocks, reselecting: edited)
    }

    private func commit(day: Int, blocks: [ScheduleBlock], reselecting edited: ScheduleBlock?) {
        schedule = schedule.setting(day: day, blocks: blocks)
        // Merging renumbers, so the index can't carry over. Re-find the block
        // the user just touched by a step it still contains — without this a
        // plain click would clear the selection and Delete would never apply.
        selection = edited.flatMap { block in
            schedule.blocks(onDay: day)
                .firstIndex { $0.contains(step: block.start) }
                .map { (day, $0) }
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onChange?(schedule)
    }

    // MARK: - Delete

    override func keyDown(with event: NSEvent) {
        let deleteKeys: Set<UInt16> = [51, 117]   // delete, forward-delete
        guard deleteKeys.contains(event.keyCode), let selected = selection else {
            super.keyDown(with: event)
            return
        }
        deleteBlock(day: selected.day, index: selected.index)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let target = hit(at: point),
              case let .block(day, index, _, _) = target else { return }
        selection = (day, index)
        needsDisplay = true
        let menu = NSMenu()
        let item = NSMenuItem(title: "Delete", action: #selector(deleteSelected), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func deleteSelected() {
        guard let selected = selection else { return }
        deleteBlock(day: selected.day, index: selected.index)
    }

    private func deleteBlock(day: Int, index: Int) {
        var blocks = schedule.blocks(onDay: day)
        guard blocks.indices.contains(index) else { return }
        blocks.remove(at: index)
        commit(day: day, blocks: blocks, reselecting: nil)
    }

    // MARK: - Cursors

    override func resetCursorRects() {
        for day in 0 ..< WeeklySchedule.dayCount {
            for block in blocks(day: day) {
                let span = primarySpan(block)
                let rect = blockRect(day: day, from: span.start, to: span.end)
                addCursorRect(NSRect(x: rect.minX, y: rect.minY, width: edgeGrab, height: rect.height),
                              cursor: .resizeLeftRight)
                addCursorRect(NSRect(x: rect.maxX - edgeGrab, y: rect.minY, width: edgeGrab, height: rect.height),
                              cursor: .resizeLeftRight)
                let body = rect.insetBy(dx: edgeGrab, dy: 0)
                if body.width > 0 { addCursorRect(body, cursor: .openHand) }
            }
        }
    }
}
