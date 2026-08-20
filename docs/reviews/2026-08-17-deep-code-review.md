# Mustard — Deep code review (2026-08-17)

A full-repo review of Mustard as it stands on `main` (`0b77291`), covering
architecture, the agent loop, SwiftData, SwiftUI/AppKit surfaces, and the
voice / meeting / rewrite / clipboard stack. Granola had no Mustard-specific
notes in the last 30 days; findings are from code, ADRs, tests, and
`.agent-loop/digest.md`.

This PR also lands a **first wave of correctness fixes** (listed in §5).
Everything else is a backlog, ordered by leverage — not a commitment to build
it all next.

---

## 1. What's strong

Mustard is unusually disciplined for a personal app of this size (~273 Swift
sources, ~1,960 tests):

- **Logic lives in `Logic/`.** Queue selection, retry, trust, board placement,
  meeting freshness, clip prune, rewrite gate, and most parsers are pure and
  unit-tested. Views mostly dispatch.
- **The serial subscription slot is real.** `AgentExecutionGate` is shared by
  `AgentService` and `AgentTaskCoordinator`; tests prove they cannot both hold
  Claude. Env scrubbing + closed stdin in `ClaudeRunner` match ADR-0003.
- **Connected-worker isolation is careful.** `BridgeExport` only writes when
  `requiresConnectedWorker == true`. BAK-90 area gating and F26's area-less
  default route are documented and tested.
- **Runtime scars are encoded.** Panel content nesting, notch `applyFrame`
  animator, AVFAudio `MSTDCatchException`, rewrite gate-before-read, and
  dictation hold-epoch all exist because hardware found the bug. Keep that
  pattern.
- **Recent flood fix is the right shape.** Meeting-task identity + 7-day
  freshness + Do/Don't (#129/#130) attacked a live store problem, not a
  hypothetical.

The product thesis — plan *your* day and *the agent's* day on one surface —
is still the right wedge. The risk is orchestration seams and surface drift,
not a missing architecture.

---

## 2. Findings by severity

### High — correctness / trust

| ID | Issue | Status |
|----|--------|--------|
| H1 | **Unknown `action_type` failed open to `vault_note`.** `RecommendationAction.from` mapped typos to a non-gated vault update, so Supervised+ could auto-approve invented tokens. | **Fixed** — `parse` + `TrustPolicy.isGated` fail closed; `decide` refuses unknown and asks for a re-bucket. |
| H2 | **Triage UI forked `AgentService.decide`.** Schedule / I'll do it / Reject / Dismiss / console **X** mutated `decision` (and invented tasks) without area stamp, rec↔task link, or `SnoozeTargets`. Morning Ritual already called `decide`. | **Fixed** — all those buttons/keys go through `decide`. |
| H3 | **Week and Lists skipped recurrence.** They called `markDone()` instead of `TaskCompletion.complete`, so completing a repeating task from Week never spawned the next instance. Today / Board / Notch already used the choke-point. | **Fixed** — `TaskCompletion.toggle` is the single complete/reopen path. |
| H4 | **Today hid calendar events.** `TimelineSpine.build` was passed `events: []` with a stale "OAuth unwired" comment. Week and Notch Today already query `CalendarEvent`. Live `GoogleCalendarService` exists; Today was the odd one out. | **Fixed.** |
| H5 | **Hover "waiting" undercounted.** Sidebar / dock / Today use `AgentInbox.waitingCount` (pending recs + all three gate stages). Hover counted pending recs + **Needs Review only**, so Needs You / Needs Approval vanished from the Blitz strip. | **Fixed.** |
| H6 | **Meeting approval predicate disagreed.** Queue used `source.hasPrefix("meeting")`; grant/clear used `source == "meeting"`. A later hand-off of a `meeting-recording` task would sit in Queued forever. Ledger flood gate should only apply to vault-harvested `"meeting"` rows — recordings were already approved locally. | **Fixed** — `MeetingTaskSource.requiresAgentApproval`. |
| H7 | **Rewrite Accept on `AXWebArea` failed closed.** Snapshot admits Gmail/Slack web areas (`RewriteRoles.textual`); write-back reused dictation's `isStillFocused`, which excludes `AXWebArea`. Read succeeded, Accept said "lost focus". | **Fixed** — restorer passes rewrite roles. |
| H8 | **Approved `vault_note` can be stolen by the coordinator.** `runVaultNote` promotes to agent/Queued *then* tries the execution gate. If the gate is busy, nothing retries `runVaultNote`; the 2s coordinator tick runs a structured turn instead of `VaultSweep.executePrompt`. Success → Needs Review (not Done); failure uses retry policy. | Open — next wave. |
| H9 | **Gated approve still starts a local Claude turn.** Comment says outward actions "stage for the decoupled session, no claude run", but `requiresConnectedWorker` stays false until the model returns that token. Extra subscription burn, up to ~10 min before export, and a hallucinated `completed` can skip the connected worker. | Open — next wave. |
| H10 | **Dragging a running agent card between agent lanes does not cancel the turn.** Documented in `BoardView`; stage/owner can change under an in-flight `claude -p`. | Open — move drop policy into `PersonalBoard.applyDrop`. |

### High — runtime / privacy (voice & meetings)

| ID | Issue | Status |
|----|--------|--------|
| V1 | Meeting `confirmStart` failure does not tear down capture / transcription / writer. Partial start can leave SCStream + SpeechAnalyzer hot. | Open |
| V2 | `ScreenCaptureMeetingAudio.ensureStream` always enables mic **and** system audio, then drops unused channels. OS indicator and captured buffers exceed the consented set. | Open |
| V3 | Voice capture `abandon()` has no hold-epoch (dictation does). An in-flight finalize can still `commitCapture`. | Open |
| V4 | No mutual exclusion across capture, dictation, and meeting mic. Overlapping `AVAudioEngine` + SCStream is a known crash class. | Open |
| V5 | `stopAudio` / `removeTap` is not wrapped in `MSTDCatchException` (install path is). | Open |
| V6 | Dictation/rewrite pasteboard writes skip `ClipboardMonitor.expectOwnWrite`. Clips can ingest rewrite selections or duplicate dictation. | Open |

### Medium — design, performance, drift

- **Stacked unbounded `@Query`.** Root + Today + Board + Week + Hover + Notch shell **and** each notch tab materialize every `MustardTask` (and often every rec/event/clip). Fine at personal scale; the 2s coordinator fetch is a full table scan. Push predicates (`stage != done`, pending recs, today's window) before the store grows.
- **Note index is a full-vault body mirror** with delete-all + reinsert per project. Search loads every `contentSnapshot`. Upsert in place; consider truncating the search blob.
- **Unversioned schema + `fatalError` on open.** `OutputCard` was deleted with no `VersionedSchema`. Next breaking change bricks launch. Extract `MustardSchema.current` shared by app, previews, and tests. `PreviewData` currently omits `ClipItem` / `ClipCollection`.
- **CloudKit blockers (when N2 happens):** missing relationship inverses; `[String]` / `[TaskLink]` Transformable collections; mutable `uid` after insert.
- **Dual lifecycle `status` vs `stage`.** `markDone` writes both; almost every other path writes only `stage`. Uncomplete used to leave `statusRaw == done`. `TaskCompletion.reopen` now clears it; stop writing `status` elsewhere.
- **`shouldAutoAccept` / `shouldAutoRunDelegation` / `releasesSlot` are dead.** Trust blurbs claimed Trusted auto-accepts; ADR-0010 forbids silent completion. Blurbs updated in this PR; consider deleting or wiring the unused APIs.
- **Doc drift.** `architecture.md` still described OutputCard, CaptureCleanupQueue, and "calendar not built". Corrected in this PR. ADR-0011 body still specifies the Claude cleanup queue.
- **Hover panel never resizes.** Content expands on hover inside a fixed 264×60 `NSPanel`, so the expanded strip is clipped. Waiting-count is fixed; geometry is still open.
- **Today's date was frozen** at view init (overnight sessions stayed on yesterday). Now `@State` + `NSCalendarDayChanged`.
- **Board drop handler is a second placement engine** (logic in the view). Same class as H10.
- **Bridge IO uses `try?`.** Export failure looks like "stuck waiting for worker".
- **God files:** `MarkdownTextView.swift` (~1,525), `TaskDetailSheet`, `NotesView`, `NotchSurface` (controller + panel + view), `MustardApp` bootstrap. Split when touching them — don't do a drive-by extract.
- **Voice leftovers:** `captureAttempts` / `captureNextAttemptAt` / `CaptureState.failed` are unused by the on-device path. Drop in the next `VersionedSchema`. Board copy updated in this PR.

### Low

- Command bar `items[min(selected, count-1)]` would crash on an empty list (engine currently never returns empty). Guard added.
- Confidence meters: board `.rounded()` vs console `.rounded(.down)` — 0.90 can show 5 vs 4 segments.
- `Color(hex:)` is 6-digit only; 3/8-digit and junk become black. Area colours hit this.
- Heavy `onTapGesture` instead of `Button` (owner chips, sidebar rows) — VoiceOver gaps.
- Notch search field is visible on every tab but only Clips/Shelf/Collection filter.
- Click-away unpin uses a global monitor only — clicks in Mustard's own window don't unpin.

---

## 3. Feature improvements (product, not just code)

Ordered by how much they advance the "you + agents on one surface" wedge.
Each still needs a spec/plan before a large build; several are already in
`docs/build-order.md`.

### Do next (unblocked, high leverage)

1. **Close the agent-loop seams (H8–H10, H9).** Vault-note vs coordinator
   ownership; set `requiresConnectedWorker` at gated approve time; cancel-or-block
   in-flight drops. This is the "stuck cards" class the docs already warn about.
2. **F30 Voice Suite hardening** (already in build-order): crash-recovery Resume
   at launch, delete recording intermediates after a clean export, pin
   action-proposal extraction with a fixture, coalesce transcript fragments.
   Hardware verification found these; the suite cannot.
3. **I2 Trust that earns itself** (design locked 2026-06-16). Track first-pass
   accept rate per action type; nudge graduation. Makes the trust ladder feel
   earned. Gated types never graduate.
4. **Needs Review split** (Leon deferred after the meeting-task flood): "Drafts
   for you" (blocking) vs "Findings" (batched digest), plus a structured
   `AgentRun` outcome so "nothing left to do" can auto-close instead of being
   sniffed from prose.
5. **Faster connected-worker loop.** Export/ingest when the flag flips, not on
   the 10-minute inbox cadence, and not blocked behind a local Claude turn.
   Surface a "Waiting on connected worker" badge so Queued isn't ambiguous.

### Planner (Sunsama/Akiflow DNA)

6. **I5 Evening shutdown** — the missing half of the morning ritual: review
   done, roll unfinished, fold in overnight agent output.
7. **I6 Capacity awareness** — sum `estimateMinutes` vs available hours; gentle
   overcommit on Today / Week (Week already has a Balance chrome).
8. **I8 Natural-language capture in ⌘K** — "email Sam re: BLE Thursday 2pm"
   → scheduled task, optionally an agent draft-email suggestion.
9. **I9 Tag filtering / saved smart lists** — tags exist (F13) but aren't a
   surface.

### Voice / notch (complete the family)

10. **Rewrite phase 2/3** — voice profile from the vault; live Mustard context.
    Phase 1 is built; the cross-app matrix is Leon-only (`docs/rewrite-acceptance-checklist.md`).
11. **Hover as a real Blitz strip** — resize on expand; click focus → Today;
    waiting numeral → Agent console (Notch already deep-links).
12. **Shared `TaskRow`** — Today inbox, lists, week list, and notch agenda have
    drifted (locks, completion path, agent-stage copy). One condensed row,
    parameterized by density/chrome.
13. **Audio session gate** — one owner for mic (V4); refuse overlapping capture
    / dictation / meeting with a pill reason.

### Later / blocked on Leon

- **N1** Connect live Google Calendar (OAuth client id). Code is built; Today
  now displays events once they exist.
- **N2** CloudKit + iOS — do the inverse/Transformable/`VersionedSchema` work
  *before* flipping the entitlement, or the first sync will fail.
- **N3** Email/Slack as sweep sources via Claude MCP.
- Hardware matrices: dictation (BAK-292), rewrite (BAK-327), meetings (BAK-303).

---

## 4. Suggested implementation waves

| Wave | Scope | Risk |
|------|--------|------|
| **0 (this PR)** | Fail-closed actions, single `decide` path, recurrence toggle, Today events, Hover count, meeting-source helper, rewrite focus roles, architecture drift | Low |
| **1** | H8 vault-note ownership; H9 gated → connected worker immediately; H10 `PersonalBoard.applyDrop`; Hover panel resize | Medium |
| **2** | `@Query` predicates + coordinator fetch; note-index upsert; `MustardSchema` + recover-on-open | Medium |
| **3** | F30 meeting recovery / cleanup / proposal fixtures / utterance coalesce | Medium (runtime) |
| **4** | V1–V6 audio teardown, SCStream consent, capture epoch, clipboard own-write, Carbon hotkey unify | High (runtime) |
| **5** | I2 trust calibration (spec already locked) | Medium |
| **6** | Needs Review split + structured `AgentRun` outcome | Medium (product) |

Do not start Wave 5–6 without a spec refresh. Wave 1–2 are code-only and
unblocked.

---

## 5. What this PR changes

Code, with tests:

- `RecommendationAction.parse` + unknown tokens gated; `decide` refuses them.
- `TaskCompletion.toggle` / `reopen`; Week, Lists, Today, Notch Today use it.
- `AgentService.decide` is the only Schedule / I'll-do-it / Reject / Ignore path
  (detail pane + console **X**).
- Today queries `CalendarEvent` and refreshes its day on midnight.
- Hover waiting count = `AgentInbox.waitingCount`.
- `MeetingTaskSource.requiresAgentApproval` — ledger only, not recordings.
- Rewrite `isStillFocused(..., roles: RewriteRoles.textual)`.
- Trust blurbs match ADR-0010 (no silent auto-accept).
- Voice pill copy no longer promises a Claude cleanup pass.
- `architecture.md` brought in line with the running system.

**Not in this PR (intentionally):** vault-note/coordinator race, connected-worker
at approve time, Hover geometry, `@Query` predicates, meeting start teardown,
schema versioning.

### Checks

This environment is Linux and cannot run `swift test` / `swift build` (macOS 26
SDK, SwiftUI/AppKit). CI on the self-hosted Mac runner is the source of truth:
`swift test` and `swift build` from `.agent-loop/checks.yml`.

### Eye-check (Leon)

- Agent console: Schedule / I'll do it / Reject / **X** should stamp area and
  link the rec the same way Approve does.
- Week: complete a daily repeating task — the next instance should appear.
- Today: with any `CalendarEvent` in the store, meetings should show on the spine
  (same as Notch Today).
- Hover badge should match the sidebar Agent count (Needs You included).
- Gmail/Slack rewrite Accept should replace the selection (was "lost focus").
