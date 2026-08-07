# Today Timeline Spine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild Today around a single forward-flowing timeline spine that interleaves calendar events, your tasks, and agent work chronologically from now through the coming days.

**Architecture:** A new pure builder (`TimelineSpine`) reuses the existing `DayPlanner.agenda` per-day merge across a forward horizon, producing day-sectioned `[SpineDay]`. A pure `TimeBand` buckets times into morning/afternoon/evening. `TimelineSpineView` draws the rail (owner-coloured dots, day headers, soft band markers, a coral "now" line) and `TodayView` swaps its flat scheduled list for it. Every existing Today behaviour (FOCUS, ritual banner, agent nudge, progress, quick capture, inbox) is preserved.

**Tech Stack:** Swift 5.9 / SwiftUI / SwiftData, Swift Package Manager, XCTest. macOS 14+. Logic is pure and TDD; views verified by `swift build` + Leon's eye-check.

**Spec:** `docs/specs/2026-07-24-today-timeline-spine-redesign-design.md`

**Convention:** every commit message ends with the trailer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` (CLAUDE.md). Commit commands below omit it for brevity — add it.

---

## File Structure

- Create `Sources/MustardKit/Logic/TimeBand.swift` — pure time-of-day bucketing (morning/afternoon/evening).
- Create `Sources/MustardKit/Logic/TimelineSpine.swift` — pure spine builder: `SpineDay`, `SpineDayLabel`, `build(...)`, `isPast(...)`.
- Create `Sources/MustardKit/Views/TimelineSpineView.swift` — renders `[SpineDay]` as the rail; contains `SpineItemRow`.
- Modify `Sources/MustardKit/Logic/Theme.swift` — add `Palette.now` + `Palette.nowLine` coral tokens.
- Modify `Sources/MustardKit/Views/TodayView.swift` — replace the flat scheduled `LazyVStack` with `TimelineSpineView`; add the summary line.
- Modify `docs/adr/0005-things3-calm-design.md` — note the sanctioned "now"-line colour exception.
- Create `Tests/MustardTests/TimeBandTests.swift`
- Create `Tests/MustardTests/TimelineSpineTests.swift`

Reused as-is (do not modify): `DayPlanner.agenda` / `AgendaItem` (per-day tasks+events merge), `RitualPlanner.focused` (FOCUS set), `TimelineRow` (kept for FOCUS band), `QuickCaptureField`, `DayPlanner.unscheduled` / `dayProgress` / `carryForward`.

---

## Task 1: `TimeBand` — pure time-of-day bucketing

**Files:**
- Create: `Sources/MustardKit/Logic/TimeBand.swift`
- Test: `Tests/MustardTests/TimeBandTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MustardTests/TimeBandTests.swift`:

```swift
import XCTest
@testable import MustardKit

final class TimeBandTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func test_of_bucketsByHour_atBoundaries() {
        XCTAssertEqual(TimeBand.of(at("2026-06-12T00:00:00Z"), calendar: cal), .morning)
        XCTAssertEqual(TimeBand.of(at("2026-06-12T11:59:00Z"), calendar: cal), .morning)
        XCTAssertEqual(TimeBand.of(at("2026-06-12T12:00:00Z"), calendar: cal), .afternoon)
        XCTAssertEqual(TimeBand.of(at("2026-06-12T16:59:00Z"), calendar: cal), .afternoon)
        XCTAssertEqual(TimeBand.of(at("2026-06-12T17:00:00Z"), calendar: cal), .evening)
        XCTAssertEqual(TimeBand.of(at("2026-06-12T23:30:00Z"), calendar: cal), .evening)
    }

    func test_of_nilForUntimed() {
        XCTAssertNil(TimeBand.of(nil, calendar: cal))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TimeBandTests`
Expected: FAIL — `cannot find 'TimeBand' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MustardKit/Logic/TimeBand.swift`:

```swift
import Foundation

/// Soft time-of-day grouping for the Today spine (Actions-style grouping, softened to
/// rail labels). Pure so it unit-tests with a pinned calendar. Boundaries: morning is
/// before 12:00, afternoon is 12:00–16:59, evening is 17:00 and later.
public enum TimeBand: String, CaseIterable, Equatable {
    case morning, afternoon, evening

    public var label: String {
        switch self {
        case .morning: "Morning"
        case .afternoon: "Afternoon"
        case .evening: "Evening"
        }
    }

    /// The band for a timed date; `nil` for an untimed (`nil`) item.
    public static func of(_ date: Date?, calendar: Calendar = .current) -> TimeBand? {
        guard let date else { return nil }
        switch calendar.component(.hour, from: date) {
        case ..<12: return .morning
        case 12..<17: return .afternoon
        default: return .evening
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TimeBandTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/TimeBand.swift Tests/MustardTests/TimeBandTests.swift
git commit -m "feat(today): add pure TimeBand time-of-day bucketing"
```

---

## Task 2: `TimelineSpine` — pure forward-flowing spine builder

**Files:**
- Create: `Sources/MustardKit/Logic/TimelineSpine.swift`
- Test: `Tests/MustardTests/TimelineSpineTests.swift`

Notes on the types being reused (already exist, do not redefine):
- `DayPlanner.agenda(tasks:events:day:calendar:) -> [AgendaItem]` merges a single day's tasks + events, timed-ascending then untimed. `AgendaItem.kind` is `.task(MustardTask)` or `.event(CalendarEvent)`; `AgendaItem.time` is `nil` for untimed tasks (task not `isTimed`) and all-day events.
- `RitualPlanner.focused(_:day:calendar:) -> [MustardTask]` returns tasks whose `focusOnDay` is that day.
- `MustardTask` has `uid`, `title`, `owner` (`.me`/`.agent`), `scheduledAt: Date?`, `isTimed: Bool`, `focusOnDay: Date?`.

- [ ] **Step 1: Write the failing test**

Create `Tests/MustardTests/TimelineSpineTests.swift`:

```swift
import XCTest
@testable import MustardKit

final class TimelineSpineTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// A timed task on the given day/time.
    private func timed(_ title: String, _ iso: String, owner: TaskOwner = .me) -> MustardTask {
        let t = MustardTask(title: title, owner: owner, scheduledAt: at(iso))
        t.isTimed = true
        return t
    }

    private let ref = "2026-06-12T10:00:00Z"   // today = 2026-06-12, now = 10:00

    func test_build_sectionsTodayTomorrowAndDatedDays_withLabels() {
        let tasks = [
            timed("today am", "2026-06-12T09:00:00Z"),
            timed("tomorrow", "2026-06-13T09:00:00Z"),
            timed("in three days", "2026-06-15T09:00:00Z"),
        ]
        let spine = TimelineSpine.build(tasks: tasks, events: [], reference: at(ref), calendar: cal)
        XCTAssertEqual(spine.map(\.label), [.today, .tomorrow, .other(at("2026-06-15T00:00:00Z"))])
        XCTAssertEqual(spine[0].items.map(\.title), ["today am"])
        XCTAssertEqual(spine[1].items.map(\.title), ["tomorrow"])
        XCTAssertEqual(spine[2].items.map(\.title), ["in three days"])
    }

    func test_build_alwaysKeepsToday_evenWhenEmpty_andCollapsesEmptyForwardDays() {
        let tasks = [timed("tomorrow only", "2026-06-13T09:00:00Z")]
        let spine = TimelineSpine.build(tasks: tasks, events: [], reference: at(ref), calendar: cal)
        XCTAssertEqual(spine.map(\.label), [.today, .tomorrow])
        XCTAssertTrue(spine[0].items.isEmpty)   // today kept for its empty state
    }

    func test_build_respectsHorizonCutoff() {
        let tasks = [
            timed("in horizon", "2026-06-18T09:00:00Z"),   // +6 days
            timed("beyond horizon", "2026-06-22T09:00:00Z"), // +10 days
        ]
        let spine = TimelineSpine.build(tasks: tasks, events: [], reference: at(ref),
                                        horizonDays: 7, calendar: cal)
        let titles = spine.flatMap { $0.items.map(\.title) }
        XCTAssertTrue(titles.contains("in horizon"))
        XCTAssertFalse(titles.contains("beyond horizon"))
    }

    func test_build_excludesFocusPinnedTasksFromToday_only() {
        let pinned = timed("pinned", "2026-06-12T09:00:00Z")
        pinned.focusOnDay = at("2026-06-12T00:00:00Z")
        let normal = timed("normal", "2026-06-12T11:00:00Z")
        let spine = TimelineSpine.build(tasks: [pinned, normal], events: [],
                                        reference: at(ref), calendar: cal)
        XCTAssertEqual(spine[0].items.map(\.title), ["normal"])   // pinned excluded from today
    }

    func test_build_interleavesEventsAndTasksByTime() {
        let task = timed("standup task", "2026-06-12T09:30:00Z")
        let event = CalendarEvent(); event.title = "9am meeting"
        event.start = at("2026-06-12T09:00:00Z"); event.end = at("2026-06-12T09:30:00Z")
        let spine = TimelineSpine.build(tasks: [task], events: [event],
                                        reference: at(ref), calendar: cal)
        XCTAssertEqual(spine[0].items.map(\.title), ["9am meeting", "standup task"])
    }

    func test_isPast_splitsAroundReference() {
        let past = timed("past", "2026-06-12T09:00:00Z")
        let future = timed("future", "2026-06-12T15:00:00Z")
        let spine = TimelineSpine.build(tasks: [past, future], events: [],
                                        reference: at(ref), calendar: cal)
        let items = spine[0].items
        XCTAssertTrue(TimelineSpine.isPast(items[0], relativeTo: at(ref)))
        XCTAssertFalse(TimelineSpine.isPast(items[1], relativeTo: at(ref)))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TimelineSpineTests`
Expected: FAIL — `cannot find 'TimelineSpine' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/MustardKit/Logic/TimelineSpine.swift`:

```swift
import Foundation

/// One day on the Today spine: its start-of-day date, a display label, and the merged
/// chronological agenda (tasks + events) for that day, reusing `DayPlanner.agenda`.
public struct SpineDay: Identifiable {
    public let day: Date
    public let label: SpineDayLabel
    public let items: [AgendaItem]
    public var id: Date { day }
}

/// How a spine day's header reads. `.other` carries the date so the VIEW does the
/// locale/timezone formatting — the builder stays timezone-agnostic and testable.
public enum SpineDayLabel: Equatable {
    case today
    case tomorrow
    case other(Date)
}

/// Pure builder for the forward-flowing Today spine. No SwiftData, no views.
public enum TimelineSpine {
    /// Today (always present, even empty — it carries Today's empty state) plus each of
    /// the next `horizonDays` days that hold at least one item. Each day is a merged
    /// tasks+events agenda. FOCUS-pinned tasks are excluded from TODAY only, so a pinned
    /// task shows once in the FOCUS band above the spine (mirrors `RitualPlanner.timeline`
    /// / BAK-247).
    public static func build(
        tasks: [MustardTask],
        events: [CalendarEvent],
        reference: Date,
        horizonDays: Int = 7,
        calendar: Calendar = .current
    ) -> [SpineDay] {
        let startOfToday = calendar.startOfDay(for: reference)
        let focusUIDs = Set(
            RitualPlanner.focused(tasks, day: startOfToday, calendar: calendar).map(\.uid)
        )

        var days: [SpineDay] = []
        for offset in 0...max(0, horizonDays) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday)
            else { continue }

            var items = DayPlanner.agenda(tasks: tasks, events: events, day: day, calendar: calendar)
            if offset == 0 {
                items = items.filter { item in
                    if case let .task(t) = item.kind { return !focusUIDs.contains(t.uid) }
                    return true
                }
            }
            // Today always renders; later days only when they carry something.
            guard offset == 0 || !items.isEmpty else { continue }
            days.append(SpineDay(day: day, label: label(offset: offset, day: day), items: items))
        }
        return days
    }

    static func label(offset: Int, day: Date) -> SpineDayLabel {
        switch offset {
        case 0: return .today
        case 1: return .tomorrow
        default: return .other(day)
        }
    }

    /// Whether a timed item lies before `reference` — used to dim TODAY's elapsed items.
    /// Untimed items are never past.
    public static func isPast(_ item: AgendaItem, relativeTo reference: Date) -> Bool {
        guard let time = item.time else { return false }
        return time < reference
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TimelineSpineTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/TimelineSpine.swift Tests/MustardTests/TimelineSpineTests.swift
git commit -m "feat(today): add pure TimelineSpine forward-flow builder"
```

---

## Task 3: Add `now` palette tokens + ADR note

**Files:**
- Modify: `Sources/MustardKit/Logic/Theme.swift` (in `enum Palette`, after the `error` token near line 81)
- Modify: `docs/adr/0005-things3-calm-design.md` (append a note)

No test — this is a design token + documentation. Verified by `swift build` in the next task.

- [ ] **Step 1: Add the tokens**

In `Sources/MustardKit/Logic/Theme.swift`, immediately after the `error` token (`public static let error = Color(hex: "#D85A30")`), add:

```swift
        // "Now" marker for the Today spine. A warm coral that is neither accent-blue nor
        // agent-purple, so "the present moment" never competes with an owner colour.
        // Sanctioned single-accent exception (see ADR-0005), like the notch's dark surface.
        public static let now = Color(hex: "#D85A30")       // now dot + label
        public static let nowLine = Color(hex: "#F0997B")   // lighter now rule
```

- [ ] **Step 2: Note the exception in the ADR**

Append to the end of `docs/adr/0005-things3-calm-design.md`:

```markdown

## Amendment (2026-07-24): the Today spine "now" line

The Today timeline spine introduces one warm coral marker (`Theme.Palette.now` /
`nowLine`) for the live "now" line. This is a deliberate, single, sanctioned exception to
the single-accent rule — in the same spirit as the notch's dark surface — because the
present-moment marker must not read as either a *you* (blue) or *agent* (purple) item.
No other coral is introduced.
```

- [ ] **Step 3: Verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/MustardKit/Logic/Theme.swift docs/adr/0005-things3-calm-design.md
git commit -m "feat(today): add coral now-line palette tokens; note ADR-0005 exception"
```

---

## Task 4: `TimelineSpineView` — render the rail

**Files:**
- Create: `Sources/MustardKit/Views/TimelineSpineView.swift`

View work — verified by `swift build` and Leon's eye-check (no UI unit tests, per CLAUDE.md). Write the complete view below; spacing/refinements come at eye-check.

- [ ] **Step 1: Create the view**

Create `Sources/MustardKit/Views/TimelineSpineView.swift`:

```swift
import SwiftUI

/// Renders the Today spine: days flowing forward, each a merged chronological agenda on
/// a continuous rail. Ownership is carried by dot colour (grey event / blue you / purple
/// agent); today's elapsed items dim; a coral "now" line marks the present. Tapping a
/// task opens the detail drawer; the dot toggles a task's done state.
public struct TimelineSpineView: View {
    private let days: [SpineDay]
    private let now: Date
    private let onToggleDone: (MustardTask) -> Void
    private let onOpen: (MustardTask) -> Void

    public init(days: [SpineDay], now: Date,
                onToggleDone: @escaping (MustardTask) -> Void,
                onOpen: @escaping (MustardTask) -> Void) {
        self.days = days
        self.now = now
        self.onToggleDone = onToggleDone
        self.onOpen = onOpen
    }

    /// A single rendered line of the spine: a band marker, the now line, or an item.
    private enum Row: Identifiable {
        case band(TimeBand)
        case now
        case item(AgendaItem)
        var id: String {
            switch self {
            case .band(let b): "band:\(b.rawValue)"
            case .now: "now"
            case .item(let i): "item:\(i.id)"
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: 0) {
                    Text(headerText(day.label))
                        .font(Theme.Fonts.label)
                        .tracking(0.6)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.bottom, 10)
                    ForEach(rows(for: day)) { row in
                        rowView(row, isToday: day.label == .today)
                    }
                }
            }
        }
    }

    // MARK: Row assembly (presentation sequencing)

    /// Ordered rows for a day: soft band markers (TODAY only) when the band changes among
    /// timed items, and the coral now line inserted before the first still-upcoming item.
    private func rows(for day: SpineDay) -> [Row] {
        let isToday = day.label == .today
        var out: [Row] = []
        var lastBand: TimeBand?
        var nowInserted = false
        for item in day.items {
            if isToday, !nowInserted, let t = item.time, t >= now {
                out.append(.now)
                nowInserted = true
            }
            if isToday, let band = TimeBand.of(item.time), band != lastBand {
                out.append(.band(band))
                lastBand = band
            }
            out.append(.item(item))
        }
        return out
    }

    @ViewBuilder private func rowView(_ row: Row, isToday: Bool) -> some View {
        switch row {
        case .band(let band):
            Text(band.label.uppercased())
                .font(Theme.Fonts.caption)
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.textFaint)
                .padding(.leading, 58)
                .padding(.top, 6)
                .padding(.bottom, 8)
        case .now:
            HStack(spacing: 6) {
                Text(now.formatted(.dateTime.hour().minute()))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.now)
                    .frame(width: 44, alignment: .trailing)
                Circle().fill(Theme.Palette.now).frame(width: 7, height: 7)
                Rectangle().fill(Theme.Palette.nowLine).frame(height: 1)
            }
            .padding(.vertical, 4)
        case .item(let item):
            SpineItemRow(
                item: item,
                isPast: isToday && TimelineSpine.isPast(item, relativeTo: now),
                onToggleDone: onToggleDone,
                onOpen: onOpen
            )
        }
    }

    private func headerText(_ label: SpineDayLabel) -> String {
        switch label {
        case .today: "TODAY"
        case .tomorrow: "TOMORROW"
        case .other(let d): d.formatted(.dateTime.weekday(.abbreviated).day()).uppercased()
        }
    }
}

/// One item on the spine: time gutter · coloured dot (a done-toggle for tasks) · title
/// with an agent-stage suffix and optional area tag.
private struct SpineItemRow: View {
    let item: AgendaItem
    let isPast: Bool
    let onToggleDone: (MustardTask) -> Void
    let onOpen: (MustardTask) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timeText)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 2)

            dot.padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(item.isDone ? Theme.Palette.textMuted : Theme.Palette.textPrimary)
                        .strikethrough(item.isDone, color: Theme.Palette.strikethrough)
                    if let suffix = agentSuffix {
                        Text("· \(suffix)")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(Theme.Palette.agentText)
                    }
                }
                if let tag = item.tagLabel {
                    Text(tag)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(isPast ? 0.5 : 1)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if case let .task(t) = item.kind { onOpen(t) }
        }
    }

    private var timeText: String {
        guard let time = item.time else { return "" }
        return time.formatted(.dateTime.hour().minute())
    }

    @ViewBuilder private var dot: some View {
        switch item.kind {
        case .event:
            Circle().fill(Theme.Palette.textTertiary).frame(width: 8, height: 8)
        case .task(let t):
            Button {
                onToggleDone(t)
            } label: {
                Image(systemName: item.isDone ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isDone ? Theme.Palette.done
                                     : (t.owner == .agent ? Theme.Palette.agent : Theme.Palette.accent))
            }
            .buttonStyle(.plain)
        }
    }

    /// Short agent-stage suffix for an agent-owned task (mirrors `DelegationBadge`).
    private var agentSuffix: String? {
        guard case let .task(t) = item.kind, t.owner == .agent else { return nil }
        switch t.stage {
        case .forAgent: return "for agent"
        case .needsApproval: return "approve"
        case .queued: return "queued"
        case .inProgress: return "working"
        case .needsInput: return "reply"
        case .needsReview: return "review"
        default: return nil
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/MustardKit/Views/TimelineSpineView.swift
git commit -m "feat(today): add TimelineSpineView rail rendering"
```

---

## Task 5: Recompose `TodayView` around the spine

**Files:**
- Modify: `Sources/MustardKit/Views/TodayView.swift`

Replace the flat scheduled list (current lines ~40–91: the `scheduled` computed property usage, its `LazyVStack`, and the `scheduled.isEmpty` empty-state guard) with the spine. Keep header, `progressBar`, `ritualBanner`, `agentNudge`, `focusSection`, `QuickCaptureField`, and the `UNSCHEDULED` inbox exactly as they are. Add a calm summary line under the header.

- [ ] **Step 1: Replace the `scheduled` computed property with a spine builder**

In `TodayView`, replace:

```swift
    /// The chronological timeline, minus tasks already pinned in FOCUS (BAK-247) so a
    /// starred task isn't shown twice. FOCUS is the single home for pinned tasks.
    private var scheduled: [MustardTask] { RitualPlanner.timeline(allTasks, day: today) }
    private var unscheduled: [MustardTask] { DayPlanner.unscheduled(allTasks) }
```

with:

```swift
    /// The forward-flowing spine: today (always shown) plus upcoming days that carry
    /// items. Events are empty until Google OAuth is wired; the rail then lights up with
    /// no further view work. FOCUS-pinned tasks are excluded from today (BAK-247).
    private var spine: [SpineDay] {
        TimelineSpine.build(tasks: allTasks, events: [], reference: today)
    }
    /// Today's item count is used for the empty-state guard and the summary line.
    private var todayItems: [AgendaItem] { spine.first(where: { $0.label == .today })?.items ?? [] }
    private var unscheduled: [MustardTask] { DayPlanner.unscheduled(allTasks) }
```

- [ ] **Step 2: Swap the scheduled list for the spine in `body`**

In `body`, replace this block:

```swift
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(scheduled) { task in
                        TimelineRow(task: task, onToggleDone: { toggle(task) }, onOpen: { selectedTask = task })
                        Divider().overlay(Theme.Palette.hairline)
                    }
                }
                if scheduled.isEmpty && focusTasks.isEmpty {
```

with:

```swift
                TimelineSpineView(
                    days: spine,
                    now: today,
                    onToggleDone: { toggle($0) },
                    onOpen: { selectedTask = $0 }
                )
                if todayItems.isEmpty && focusTasks.isEmpty {
```

(The warm empty-state `VStack` and `QuickCaptureField` that follow stay unchanged.)

- [ ] **Step 3: Add the summary line under the header**

In `body`, immediately after `header` and before `progressBar`, insert:

```swift
                summaryLine
```

Then add this computed property to `TodayView` (next to `progressBar`):

```swift
    /// Calm one-liner under the header: "N tasks · agent on M" (events appended once the
    /// calendar source is wired). Zero parts are omitted; nothing shows on an empty day.
    @ViewBuilder private var summaryLine: some View {
        let items = todayItems
        let taskCount = items.filter { if case .task = $0.kind { return true }; return false }.count
        let agentCount = items.filter {
            if case let .task(t) = $0.kind { return t.owner == .agent }; return false
        }.count
        var parts: [String] = []
        if taskCount > 0 { parts.append("\(taskCount) task\(taskCount == 1 ? "" : "s")") }
        if agentCount > 0 { parts.append("agent on \(agentCount)") }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.bottom, 10)
        }
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `swift build`
Expected: builds with no errors. (If the compiler flags `scheduled` as still referenced anywhere else in the file, remove that reference — it is replaced by `spine`/`todayItems`.)

- [ ] **Step 5: Run the full suite**

Run: `swift test`
Expected: PASS — existing suite plus the new `TimeBandTests` and `TimelineSpineTests`. No regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/MustardKit/Views/TodayView.swift
git commit -m "feat(today): recompose Today around the timeline spine"
```

---

## Task 6: Verify + hand off for eye-check

**Files:** none (verification only).

- [ ] **Step 1: Full build + test**

Run: `swift build && swift test`
Expected: build succeeds; whole suite green.

- [ ] **Step 2: Assemble the app**

Run: `./build-app.sh`
Expected: `build/Mustard.app` produced (ad-hoc signed).

- [ ] **Step 3: Hand off to Leon for eye-check**

Views cannot be screenshotted from the session (no Screen Recording/TCC — CLAUDE.md). State that it builds and the suite passes, and ask Leon to open `build/Mustard.app` and confirm on the Today surface:
- days flow forward with `TODAY` / `TOMORROW` / dated headers;
- dots read grey (event) / blue (you) / purple (agent), the coral now line sits at the right spot, and elapsed items dim;
- soft `MORNING` / `AFTERNOON` / `EVENING` markers appear on today only;
- FOCUS, the ritual banner, agent nudge, progress bar, quick capture, and the `UNSCHEDULED` inbox all still work;
- it holds up at iPhone width (parity), if checking the iOS companion.

---

## Self-Review

**Spec coverage:**
- Single interleaved rail, owner dot colours, past-dim → Task 4 (`SpineItemRow.dot`, `isPast`).
- Forward flow + day headers → Task 2 (`build`, labels) + Task 4 (`headerText`).
- Soft time-of-day markers (today only) → Task 1 (`TimeBand`) + Task 4 (`rows(for:)`).
- Coral now line + ADR exception → Task 3 + Task 4 (`.now` row).
- FOCUS exclusion preserved → Task 2 (`focusUIDs`) + test.
- Summary line (counts only, no free-time hint) → Task 5 (`summaryLine`).
- Preserve ritual/nudge/progress/capture/inbox → Task 5 (explicitly untouched).
- Calendar events built + tested, passed `[]` for now → Task 2 test `test_build_interleavesEventsAndTasksByTime`; Task 5 passes `events: []`.
- Pure logic TDD with pinned UTC calendar → Tasks 1–2 tests.

**Placeholder scan:** none — every code step shows complete code; every run step gives the command and expected result.

**Type consistency:** `TimeBand.of` / `.label`; `TimelineSpine.build` / `.isPast` / `label(offset:day:)`; `SpineDay {day,label,items,id}`; `SpineDayLabel {.today,.tomorrow,.other(Date)}`; `AgendaItem` fields (`id`, `kind`, `time`, `title`, `isDone`, `tagLabel`) used consistently across Tasks 2, 4, 5. `TimelineSpineView(days:now:onToggleDone:onOpen:)` matches its call in Task 5. `Theme.Palette.now`/`nowLine` defined in Task 3, used in Task 4.

**Out of scope (not built here):** NL quick-capture parser, free-time/gap hint, dual-lane, month heatmap, iOS swipe gestures, live Google Calendar fetch.
