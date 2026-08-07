# Today Redesign — Timeline Spine — Design

- **Status:** Proposed — awaiting Leon's approval before a plan is written
- **Date:** 2026-07-24
- **Origin:** Feature-mining Timepage (calendar) and Actions (tasks) by Moleskine Studio;
  Leon liked Timepage's timeline layout and Actions' task grouping, and chose to land the
  timeline spine inside a redesigned Today view.
- **Depends on:** nothing hard. Calendar events on the rail light up only once Google OAuth
  is wired (data layer done, awaits Leon's client id) — the spine renders tasks + agent work
  without it.
- **Branch:** TBD

## Problem

Today is where the day starts, but the current `TodayView` is a **flat, single-day list**:
a header, a progress bar, two conditional banners (morning ritual + agent nudge), a FOCUS
pinned section, then `RitualPlanner.timeline(_:day:)` rendered as divider-separated
`TimelineRow`s, quick capture, and an unscheduled INBOX. There is **no time rail, no
grouping, and the day stops at midnight** — there is no sense of *where you are in the day*
or *what's coming next*. It also under-sells Mustard's wedge: your work and your agents' work
are not shown flowing together on one time axis, which is the whole product thesis.

## Goal

Rebuild Today around a single **timeline spine** — one continuous, forward-flowing rail that
interleaves calendar events, your scheduled tasks, and agent work in chronological order,
from now through the coming days — while preserving every load-bearing behaviour the current
Today already has. Calm first (Things-3 discipline, ADR-0005): the spine orients, it does not
add density.

## Approach

Keep Today as the home surface; replace its flat scheduled list with a **spine** rendered from
a new **pure feed builder** (`TimelineSpine`, `Logic/`). The builder takes tasks (and later
events), a `reference` "now", and a forward horizon, and returns an ordered, day-sectioned feed
with soft time-of-day bands and a "now" position. The view layer (`TimelineSpineView`) only
draws the rail, dots, time gutter, day headers, and the now-line, placing the existing
condensed task row inside each item. All sorting/sectioning/bucketing/past-future decisions
live in the pure builder so they are unit-tested with a pinned clock and timezone (CLAUDE.md
testing rule).

### Single interleaved rail (chosen)

One rail, chronological. Ownership is carried by **dot colour**, not by splitting the timeline
(the dual-lane alternative was rejected: striking on desktop, but it hops the eye across time
and gets cramped at iPhone width, and Mustard keeps desktop/iOS at parity). Colours:

- **grey dot** — calendar event (neutral; not "owned")
- **blue dot** — your task (`owner == .me`), the single accent
- **purple dot** — agent task (`owner == .agent`), agent purple

Past items today dim and strike through so the eye lands on what's next.

## Components

### 1. `TimelineSpine` (pure logic, `Logic/TimelineSpine.swift`) — TDD

The heart of the feature. Pure, no SwiftUI, fully unit-tested.

- Input: `tasks: [MustardTask]`, `events: [CalendarEvent]` (empty until OAuth), a
  `reference: Date` (now), a `horizonDays: Int` (default 7), and an injected `Calendar`.
- Output: `Spine { sections: [DaySection], now: Date }` where
  `DaySection { day: Date, label: DayLabel, items: [SpineItem] }` and
  `SpineItem { id, time: Date?, title, kind: SpineItemKind, badge: AgentStageBadge?, isPast: Bool, band: TimeBand }`.
- `SpineItemKind = .event | .youTask | .agentTask` (drives dot colour + row variant).
- `DayLabel = .today | .tomorrow | .dated(String)` — "TODAY", "TOMORROW · Fri 25", else the
  weekday+day.
- Rules:
  - Items sorted by time within a day; untimed scheduled items sort after timed ones.
  - **Days with no items collapse** — only days carrying at least one item get a header, up to
    `horizonDays` forward. Today always renders (even empty, for its empty-state).
  - `isPast` = item time strictly before `reference` (today only; future days never past).
  - **FOCUS exclusion preserved:** starred tasks pinned in the FOCUS band are excluded from the
    spine so nothing shows twice (mirrors today's `RitualPlanner.timeline` / BAK-247).

### 2. `TimeBand` (pure) — TDD

Buckets a `Date` into `.morning` (< 12:00), `.afternoon` (12:00–17:00), `.evening` (≥ 17:00),
thresholds configurable. Used to emit the faint `MORNING / AFTERNOON / EVENING` rail markers
**within the current day only** (Actions' grouping, softened to labels — not hard sections).
Future days use the day header alone.

### 3. `TimelineSpineView` (`Views/TimelineSpineView.swift`)

Renders one `Spine`. Left gutter shows the time; a 2px rail runs the section; each item gets a
coloured dot. Day headers and band markers are faint uppercase labels on the rail. Reuses the
existing condensed `TimelineRow` for task items (blue/purple by owner) and adds a light
**event row** variant for `.event` items. Tapping an item opens the existing task detail
drawer (`taskDetailDrawer`); event rows are non-interactive until calendar is wired.

### 4. The "now" line (`Views/`, + one Theme token)

A live horizontal marker at the current time's position in TODAY, labelled `now · HH:mm`, in a
warm **coral** that is neither you-blue nor agent-purple — so "the present moment" never
competes with an owner colour. This introduces `Theme.Palette.now` (coral) as a **sanctioned
exception** to the single-accent rule (ADR-0005), in the same spirit as the notch's dark
surface. ADR-0005 gets a one-line amendment noting the exception.

### 5. `TodayView` recomposition

Top-to-bottom, preserving all existing behaviour:

- **Header** — "Today" + date + `✦ Plan with agent` (unchanged).
- **Summary line** (new, calm) — `4 events · 4 tasks · agent on 2`, muted, single line. Counts
  only; no free-time hint (that is the gap-finder, out of scope — see below).
- **Progress bar** — unchanged (`DayPlanner.dayProgress`).
- **Morning-ritual banner** — unchanged (`RitualPrompt` gating).
- **Agent nudge** — unchanged (dismissible, opens console).
- **FOCUS band** — unchanged, above the spine (`RitualPlanner.focused`).
- **The spine** — `TimelineSpineView`, replacing the flat scheduled `LazyVStack`.
- **Empty state** — when TODAY has no items and FOCUS is empty; forward days may still show.
- **Quick capture** — unchanged (`QuickCaptureField`, scheduling onto today). Placeholder copy
  hints at natural language but no parsing is added here (fast-follow).
- **UNSCHEDULED inbox** — unchanged, at the bottom (`DayPlanner.unscheduled`).

`carryForward` on appear is retained.

### 6. Calendar gating

The builder accepts `events` but callers pass `[]` until Google OAuth is wired. The `.event`
path (row variant, grey dot) is built and tested with fixtures now, so events appear with no
further view work once the calendar source lands.

## Testing

- `TimelineSpineTests` (pinned UTC `Calendar` + ISO fixtures, injected `reference`): intra-day
  ordering; untimed-after-timed; day sectioning + labels (today/tomorrow/dated); empty-day
  collapse; horizon cutoff; `isPast` split around `reference`; owner → `SpineItemKind`
  classification; FOCUS exclusion; events interleaved with tasks by time.
- `TimeBandTests`: boundary cases at 11:59/12:00 and 16:59/17:00; configurable thresholds.
- Views verified by `swift build` + Leon's eye-check (no UI tests; the agent cannot screenshot
  the native app — CLAUDE.md).

## Out of scope (deliberate — keep this slice structural)

- **Natural-language quick capture** (`CommandBarEngine` parser) — fast-follow, own slice.
- **Free-time / gap "helpful hints"** (Timepage) — separate feature; not on the rail here.
- **Dual-lane spine** — rejected for parity/calm reasons above.
- **Month load heatmap**, **swipe gestures (iOS)**, **weather**, **deep theming** — other
  mined patterns, not this slice.
- **Live Google Calendar fetch** — awaits Leon's OAuth client id.

## Parity

All new logic and views live in `MustardKit`, so the iOS companion inherits the spine
automatically (desktop/mobile parity rule). The single-rail choice is partly *because* it
survives narrow width; the spine layout must be verified at iPhone width during eye-check.

## Risk

Medium — this reshapes `TodayView`, a core daily surface. Mitigation: the redesign is additive
at the logic layer (new pure builder + tests) and every existing Today behaviour is explicitly
preserved and enumerated above, so regressions are visible in review against this list.
