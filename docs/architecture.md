# Mustard — Architecture

Deep reference for how Mustard is put together. For the quick orientation see
[`CLAUDE.md`](../CLAUDE.md); for decisions and their rationale see [`adr/`](adr/).
A 2026-08-17 deep review (findings + first-wave fixes) lives in
[`docs/reviews/2026-08-17-deep-code-review.md`](reviews/2026-08-17-deep-code-review.md).

## 1. Shape

- **Native SwiftUI**, macOS 26+, Swift 6 toolchain (language mode 5).
- **Swift Package** (not an `.xcodeproj` yet — ADR-0002):
  - `MustardKit` (library): all models, logic, agent, calendar, views.
  - `Mustard` (executable): `@main` app, window/scene, floating panel + notch
    controllers, the scheduled-sweep loop.
  - `MustardTests`: XCTest target.
  - `MustardMobile`: iOS sample target (separate; CI is macOS SPM today).
- **SwiftData** for persistence; **CloudKit-shaped schema** so iCloud sync is a
  later capability flip, not a migration (ADR-0001). The schema is still
  unversioned — additive fields lightweight-migrate; removals would brick launch.
- The **agent** is a single worker bound to this Mac, shelling out to the `claude`
  CLI under Leon's subscription (ADR-0003).

## 2. Layered modules

```
Views   ─────────────▶ depend on Logic + Agent + Capture + Models
Agent   ─────────────▶ depend on Logic + Models   (AgentService, ClaudeRunner, VaultSweep, AgentTaskCoordinator)
Capture ─────────────▶ depend on Logic + Models   (push-to-talk: hotkey, SpeechAnalyzer, coordinator — macOS-only)
Voice / Dictation / Meeting / Rewrite / Clipboard
                    ─▶ depend on Logic + Models   (on-device Apple stack)
Calendar ────────────▶ depend on Models           (GoogleOAuth, GoogleCalendarService, parser)
Logic   ─────────────▶ depend on Models only      (pure, fully unit-tested)
Models  ─────────────▶ SwiftData @Model + enums
```

The dependency arrow only points down. **All branching logic lives in `Logic/` or
in pure parsers**, so it is testable without SwiftUI or a network. Views are thin.

## 3. Data model (SwiftData)

CloudKit rules observed everywhere: every relationship optional, every stored
property has a default or is optional, **no `@Attribute(.unique)`**. Several
relationships still lack inverses (`blockedByTask`, `MeetingRecord.calendarEvent`,
`MeetingActionProposal.createdTask`) — those block a CloudKit flip; see the review.

| Model | Purpose | Notable fields |
|-------|---------|----------------|
| `Area` | top-level grouping | name, colorHex, → lists |
| `TaskList` | list within an area | name, → area, → tasks |
| `MustardTask` | a task (mine or agent's) | `uid` (drag id), title, notes, `stageRaw`/`ownerRaw` (typed accessors; `statusRaw` is a launch-backfill leftover), `scheduledAt`, `estimateMinutes`, `completedAt`; voice: `captureStateRaw` (`raw`/`cleaned`), `captureTranscript` |
| `Recommendation` | an agent proposal (pre-execution) | title, body, `proposedActionType`, `confidence`, `reasoning`, `draft`, `source`/`sourceContext`/`sourceURL`, `comment`, `snoozedUntil`, `decisionRaw`, `executionStateRaw`, → task |
| `AgentRun` | one delegated-task conversation | `provider`, `state`, `providerSessionID`, `requiresConnectedWorker`, `nextAttemptAt`, `autoRetryCount`, → task, → messages |
| `AgentMessage` | one ordered turn in a run | `sequence`, `role`, `kind`, `content`, `links`, → run |
| `AgentDraft` | a file-backed draft the agent produced | `kind`, `title`, `relativePath` (under `_agent/drafts/`), → run. Body lives in the vault file, not the store |
| `CalendarEvent` | a Google Calendar meeting | externalId, calendarId, title, start, end, isAllDay, joinURL, location |
| `NoteIndexEntry` | vault note mirror for search/backlinks | project, relativePath, title, tags, contentSnapshot |
| `MeetingRecord` / segments / proposals | meeting recorder | uid, audio paths, digest, evidence-backed proposals |
| `ClipItem` / `ClipCollection` | notch clipboard shelf | uid, payload/imageData, pinnedToShelf |

> **ADR-0010:** delegated agent tasks carry an `AgentRun`/`AgentMessage` conversation
> and land in the board's **Needs Review** column. There is no `OutputCard` type —
> it was removed. Vault-note execution still uses `Recommendation.executionState`;
> review of delegated work is the board column, not a card on the recommendation.

Enums are stored as `…Raw` strings with computed typed accessors — primitives
persist cleanly in SwiftData/CloudKit while call sites stay type-safe. `SourceID`
gained a `voice` case (F25) so voice-originated recommendations badge their origin.

## 4. The agent loop

```
schedule (SweepScheduler) ─┐
manual "Sweep" ────────────┴▶ AgentService.sweep(vaultPath)
                                 │  claude -p (VaultSweep.prompt) in vault cwd
                                 ▼
                            parse → insert Recommendations (pending)
                                 │
                    applyTrust(level)  ── confidence × trust × !gated ──▶ auto-approve
                                 │
        user triage in AgentConsole / Notch ──▶ AgentService.decide
                                 ▼
              ┌─ vault_note  → headless claude → mark Done (or stay queued on failure)
              ├─ create_task → me / Inbox
              └─ gated (email/Slack/ticket) → agent / Queued
                    → AgentTaskCoordinator (serial local slot)
                    → Needs You (question) | Needs Review (always — no silent accept)
                    → requires_connected_worker → BridgeExport → drain-agent-queue
```

- `ClaudeRunner.run: ClaudeRun` spawns `Process`: scrubbed env (drops
  `ANTHROPIC_*`/`CLAUDE*`), stdin = `/dev/null`, parses `{result, is_error}` JSON,
  flags rate-limits. Overridable via `MUSTARD_CLAUDE_BIN` for tests.
- `AgentService` is `@MainActor @Observable`, serial via `AgentExecutionGate` —
  one `claude` at a time, subscription-friendly. Delegated work is picked up by
  `AgentTaskCoordinator` on a 2s tick.
- `TrustPolicy` (pure): `shouldAutoApprove(actionType:trust:confidence:)`,
  `isGated` (unknown tokens fail closed), `autoConfidenceThreshold = 0.7`.
  `shouldAutoAccept` is retained for tests but **not called** — ADR-0010 sends
  every completed delegated task to Needs Review.

## 4b. Voice capture (F25/F26 — ADR-0011)

Push-to-talk quick capture: hold a global hotkey anywhere, speak, release → a task.
Everything — transcription **and** structuring — runs on-device. There is no
claude call and no automatic delegation from a voice task.

```
⌃⌥Space (PushToTalkHotKey, Carbon) ─ press ─▶ AppleSpeechSession (SpeechAnalyzer)
                                    ─ release ─▶ VoiceCapture.outcome (pure)
                                                   │  commit (≥300ms hold, non-empty)
                                                   ▼
                              MustardTask(source:"voice", captureState:.raw, transcript kept) → Inbox
                                                   │
                    VoiceTaskDraftGenerator (Foundation Models, revision-gated merge)
                                                   ▼
                              title/notes/area/schedule applied only if the user hasn't edited
                              those fields; success → .cleaned; failure leaves .raw
```

- **Capture (no LLM, no network).** `PushToTalkHotKey` uses `RegisterEventHotKey`
  (press *and* release, no Accessibility/Input-Monitoring grant needed).
  `AppleSpeechSession` streams partials from SpeechAnalyzer / SpeechTranscriber
  over an `AVAudioEngine` mic tap. `VoiceTaskCaptureCoordinator` sequences
  hotkey → a non-activating pill (`VoiceCapturePillView`) → insert. Decisions
  live in pure `VoiceCapture` and `VoiceTaskDrafting`.
- **On-device drafting** replaced the Claude `CaptureCleanupQueue`. The generator
  may only pick areas from the supplied list and never invents URLs/people/dates.
- **Out of scope:** automatic delegation from a voice task. Manual "Ask agent"
  still goes through the ordinary area gate; F26's default route rescues
  *programmatic* area-less hand-offs only (`AgentTaskQueue.route` +
  `AgentService.exportAreaLessWork`).
- **Build note.** `build-app.sh`'s Info.plist carries `NSMicrophoneUsageDescription` +
  `NSSpeechRecognitionUsageDescription`. The hotkey/mic/speech/pill layer is
  macOS-runtime-only; everything with a decision is pure and unit-tested.
  Live SpeechAnalyzer needs macOS 27; on macOS 26 capture reports itself
  unavailable in the pill instead of failing silently.

## 5. Surfaces

| Surface | File | Behaviour |
|---------|------|-----------|
| Main window | `RootView` | calm sidebar → Today · Board · Week · Notes · Agent; ⌘K command bar overlay |
| Today | `TodayView` + `TimelineSpineView` | scheduled timeline (tasks **and** calendar events), capture, complete, carry-forward, tap → detail |
| Board | `BoardView` | Kanban by stage, drag-drop, per-column add, tap → detail |
| Week | `WeekView` | Mon–Sun grid + unscheduled rail, drag to (un)schedule, meetings interleaved |
| Notes | `NotesView` + `NoteEditorView` | vault-backed Craft editor, wikilinks, backlinks |
| Agent | `AgentConsoleView` | source picker, Sweep, Trust menu, recommendation detail, gate attention, single-key triage |
| Settings | `SettingsHome` | sources, calendar connect, rebindable hotkeys |
| Notch | `NotchSurface` | tabbed command shelf (Today · Agent · Meetings · Clips · Shelf · collections); hover peeks, click/⌘⇧N pins |
| Hover | `HoverPanel` | non-activating floating `NSPanel`; current focus + next-up tasks + waiting badge |
| Voice pill | `VoiceCapturePillView` | non-activating top-centre `NSPanel` shown while ⌃⌥Space is held |
| Task detail | `TaskDetailSheet` | edit title/notes/stage/owner/estimate/schedule, conversation, mark done, delete |

`NotchController` and `HoverPanel` own `NSPanel`s configured non-activating
(`.nonactivatingPanel`) so they never steal focus; `.canJoinAllSpaces`,
floating/status-bar level.

## 6. Calendar (live fetch built; connect blocked on client id)

- `GoogleOAuth`: PKCE (`verifier`/`challenge`, RFC 7636), `authorizationURL`,
  `parseTokenResponse` — all pure/tested. Flow = OAuth 2.0 desktop client + PKCE +
  loopback redirect.
- `GoogleCalendarParser.parseEvents`: Google `events.list` JSON → `[ParsedEvent]`,
  handling timed vs all-day, Meet links, cancelled-event skipping — pure/tested.
- **Built:** `GoogleAuthSession` (loopback + `ASWebAuthenticationSession`),
  `GoogleCalendarService` (connect/refresh/fetch → upsert `CalendarEvent`),
  Keychain token store, Settings UI. `MustardApp` pumps fetch from the 60s loop.
  **Blocked on:** Leon's Google Cloud OAuth client id (Desktop app). Until
  connected, `CalendarEvent` rows (if any) still render on Today, Week, and the
  notch.

## 7. Known constraints

- Agent is Mac-anchored (subscription auth on the logged-in CLI).
- Native app can't be screenshotted from the dev session (no TCC) — UI verified by
  build + Leon's eyes.
- Voice capture needs Microphone + Speech-Recognition permission (prompted at first
  launch); the hotkey/mic path only runs in a real signed build, not `swift test`.
- CloudKit + iOS require migrating SPM → Xcode project for entitlements (ADR-0004).
- Store open is `fatalError` on schema mismatch; introduce `VersionedSchema`
  before the next breaking model change.
