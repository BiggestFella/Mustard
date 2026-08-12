# Mustard — Agent Guide (CLAUDE.md)

Mustard is a native macOS command centre that plans **your day and your AI agents'
day together** — a hybrid of Blitz (always-on hover), boring-notch (ambient notch),
Sunsama/Akiflow (day/week planner), and Todoist/Things 3 (calm task management),
with a first-class surface for the work AI agents do for you.

This file orients an agent (or a new engineer) with zero prior context. Read it
before touching code.

## What it is / who it's for

A **personal, local-first** tool for one power user (Leon) who actively delegates
work to AI agents. Not multi-user — but the data layer is shaped so it *could*
generalise later (see ADR-0001). The wedge: every planner assumes *you* are the
only worker; Mustard plans your work and your agents' work on one surface, with a
triage → recommendation → approval → execution → review loop.

## Architecture (one paragraph)

Native **SwiftUI**, **SwiftData** persistence (CloudKit-shaped for later sync).
Code lives in a Swift Package: a **`MustardKit` library** (models, pure logic,
agent layer, views) plus a thin **`Mustard` executable** (`@main` app + window/
panel wiring). The single agent runs **on this Mac only**, shelling out to the
**`claude` CLI in headless `-p` mode** using Leon's Claude **subscription** (no API
key, no metered billing — see ADR-0003). The agent reads/writes an Obsidian vault;
structured app data (tasks, recommendations, outputs, events) lives in SwiftData.

```
┌─ macOS ─────────────────────────────────────────────┐
│  Mustard.app (SwiftUI)                                │
│   Today · Board · Week · Notes · Agent + Notch/Hover/⌘K│
│        │ @Query / @Bindable                           │
│        ▼                                              │
│  SwiftData (mustard.store)  ◀── AgentService ──▶ claude -p (subscription)
│   tasks · recommendations · outputs · events          │      in vault cwd
└───────────────────────────────────────────────────────┘
```

## Folder layout

```
Mustard/
  Package.swift                  SPM manifest (macOS 26+, tools 6.2 w/ Swift-5 mode pin;
                                   MustardKit + Mustard + MustardTests)
  build-app.sh                   assembles a signed build/Mustard.app from the SPM binary
  CLAUDE.md                      this file
  README.md                      human-facing quickstart
  docs/
    architecture.md              the deep architecture reference
    build-order.md               the backlog / build sequence (tracker-as-markdown)
    adr/                         Architecture Decision Records (0001…)
  Sources/
    Mustard/                     executable: MustardApp.swift (@main, windows, panels, scheduler loop)
    MustardKit/
      Models/                    @Model types: Area, TaskList, MustardTask, Recommendation,
                                   OutputCard, CalendarEvent, NoteIndexEntry, Enums
      Logic/                     PURE, unit-tested: DayPlanner, WeekPlanner, PersonalBoard,
                                   NotchTicker, SweepScheduler, CommandBarEngine, TrustPolicy,
                                   RecommendationAction, Theme (design tokens incl. Elevation/
                                   Motion/Metrics + NS bridges); Notes Phase A: WikilinkSyntax,
                                   WikilinkIndex, MarkdownBlocks, NoteTree, NoteCreation,
                                   NoteReindexScheduler, BacklinkSnippets;
                                   morning ritual: RitualPrompt, RitualPlanner;
                                   Craft editor: NoteDecoration, SlashMenu, BlockReorder,
                                   NoteMetadata, WikilinkURL;
                                   notch shelf (2026-08-12): ClipClassifier, ClipStoreRules,
                                   NotchPinState, NotchTabModel/NotchPanelMetrics, NotchSearch
      Agent/                     ClaudeRunner (Process shell), VaultSweep (prompt+parser),
                                   AgentService (@Observable orchestrator), FileVaultIO
                                   (MeetingVaultIO + NoteVaultIO), NoteIndexService (notes reindex)
      Dictation/                  system-wide dictation (⌃⌥D, voice suite):
                                   AccessibilityFocusReader (AX focus snapshots, fail-closed),
                                   TextInserter + PasteboardSnapshot (direct AX insert or
                                   lossless verified ⌘V fallback), SystemDictationCoordinator
                                   (hold-epoch guarded; transcript never lost; final transcripts
                                   also land in clip history — secure fields excepted — per the
                                   2026-08-12 notch shelf spec)
      Meeting/                    meeting recorder (voice suite): MeetingAudioStore/-Writer
                                   (validated Recordings/<uid>/ layout, crash-recoverable),
                                   ScreenCaptureMeetingAudio + MeetingAudioCapture (two-source,
                                   consent-gated), MeetingTranscriptionService (dual-live or
                                   file fallback), MeetingDigestService (evidence-backed),
                                   MeetingCaptureCoordinator, MeetingAppSignals + suggestions,
                                   MeetingExportService; pure rules in Logic/ (MeetingRecordingState,
                                   MeetingTranscriptMerge, MeetingDigestChunker, MeetingDetection,
                                   MeetingActionApproval, MeetingRetention)
      Voice/                     shared Apple voice core (2026-07-29 voice suite):
                                   VoiceTypes/VoiceServices (contracts), AppleSpeechSession
                                   (SpeechAnalyzer adapter), VoiceAssetReadiness,
                                   OnDeviceLanguageService + PromptCatalog (Apple Intelligence),
                                   VoicePermissionStatus, VoiceTaskDraftGenerator (+ Prompts/)
      Capture/                   push-to-talk voice capture (ADR-0011 + voice suite):
                                   PushToTalkHotKey (Carbon, ⌃⌥Space, conflict surfaced),
                                   VoiceTaskCaptureCoordinator (hotkey→pill→raw Inbox task→
                                   on-device drafting→revision-gated merge),
                                   VoiceTaskQuickEditController (notch-adjacent card)
      Clipboard/                  notch shelf clipboard layer (2026-08-12 spec):
                                   ClipboardMonitor + LivePasteboard (changeCount polling,
                                   concealed/transient skip, own-write sweep); ClipStore
                                   (+ ClipboardServices box, ClipThumbnail — 200-item prune,
                                   5MB image cap); ClipPaster (⌘V via shared PasteKeystroke);
                                   ClipsHotKey (⌃⌥V, id 4 — shares the "MSTD" Carbon signature
                                   with capture id 1, dictation id 2, rewrite id 3)
      Calendar/                  GoogleOAuth (PKCE/URL/token), GoogleCalendarParser
      Views/                     SwiftUI screens + surfaces (Root, Today, Board, Week,
                                   AgentConsole, Hover, CommandBar, TaskDetail, rows;
                                   Notes, NoteEditor [live Craft editor — no Source/Preview
                                   toggle], MarkdownTextView (TextKit-1 surface), SlashMenuView,
                                   BlockGutterOverlay, MarkdownPreview, BacklinksPanel,
                                   MorningRitual, VoiceCapturePillView [push-to-talk pill],
                                   VoiceTaskQuickEditView [quick-edit card], VoiceSetupView);
                                   notch shelf (2026-08-12): NotchSurface is now the shell
                                   (controller + header/pills/banner/capture) with one file per
                                   tab — NotchTodayTab, NotchAgentTab, NotchMeetingsTab,
                                   NotchClipsTab, NotchShelfTab, NotchCollectionTab — plus the
                                   shared ClipCardView
      MustardContainer.swift     builds the on-disk ModelContainer
      PreviewData.swift          in-memory sample container for #Preview
  Tests/MustardTests/            XCTest — one file per Logic/Agent/Calendar unit
```

**Separation rule:** anything with a decision in it (sorting, bucketing, gating,
parsing, scheduling) goes in `Logic/` or as a pure function in `Agent`/`Calendar`
so it can be unit-tested. `Views/` only renders and dispatches. This is why the
suite covers the whole decision surface without UI tests.

## Design language — "Things 3 calm" (do not deviate)

All palette/type tokens live in `Logic/Theme.swift` (`Theme.Palette`, `Theme.Fonts`).
Use them — never hardcode colors in views. The look: warm off-white `#FBFAF7`,
hairline dividers, generous spacing, large readable type, **single blue accent**
`#2D7FF9`, agent purple `#7F77DD`, done green `#1D9E75`. Density comes from
hierarchy, not cramming. **One exception:** the notch surface (`NotchSurface.swift`)
is intentionally **dark** — it extends the physical hardware notch — so it uses
explicit dark hex, not `Theme`.

## Testing rules

- **Logic is TDD.** New behaviour in `Logic/`, `Agent` parsers, or `Calendar`
  parsers: write the failing XCTest first, then implement. One test file per unit.
- **Pin time and timezone.** Date logic tests use a fixed `Calendar` with
  `TimeZone(identifier: "UTC")` and ISO fixtures — never the ambient clock/zone
  (AEST shifts day boundaries and flakes otherwise). Inject `now:`/`reference:`.
- **Network/process is injected.** `AgentService` takes a `ClaudeRun` closure;
  tests pass a stub. `ClaudeRunner.run` (the real `Process`) is covered against a
  stub binary via the `MUSTARD_CLAUDE_BIN` env override.
- **Views are verified by build + eye**, not unit tests. `swift build` must pass;
  Leon visually confirms (the in-session shell has no Screen Recording/TCC, so the
  agent cannot screenshot the native app — never claim a view "looks right",
  state it builds and runs and ask Leon to confirm).
- Run: `swift test` (whole suite) or `swift test --filter <SuiteName>`.

## Build & run

```bash
swift test            # full suite (1,751 at the SDK-symbol-removal fix)
swift build           # compile check
./build-app.sh        # → build/Mustard.app (ad-hoc signed, double-clickable)
open build/Mustard.app
```

**Use the plain, selected toolchain — do NOT export `DEVELOPER_DIR`.** Older plan
docs tell you to point it at `~/Downloads/Xcode-beta.app` because two macOS 27-only
symbols (`Speech.AnalyzerInputConverter`, `FoundationModels.LanguageModelError`)
were unavailable elsewhere. **That is no longer true and following it is now the
wrong move.** Apple deleted both symbols in the macOS 28 SDK; the Voice code was
migrated off them (`AnalyzerInputResampler`, and `mappedFailure`'s single
`GenerationError` branch) and now builds under *either* SDK. Between the Xcode
upgrade and that migration, `swift build` failed on `main` for every branch, and
three separate dev-loop runs each rediscovered it and wrote it off as
"pre-existing, unrelated" — if `swift build` ever fails on a pristine `main`
again, fix it as the first order of business instead of routing around it.

There is one opt-in test, skipped by default, that exercises the real
`SpeechAnalyzer` end-to-end (assets + `say`-rendered audio, no microphone). It is
the only automated check that would have caught the removal above:

```bash
MUSTARD_LIVE_ANALYZER=1 swift test --filter LiveAnalyzerSmokeTests
```

`MustardApp` builds the container, owns the `AgentService`, the floating
`HoverPanel` (⌘⇧H), the `NotchController` (⌘⇧N), and a 60s scheduled-sweep loop.
The notch (2026-08-12 shelf redesign) is a tabbed command surface — hover peeks
it with a collapse grace period, click or ⌘⇧N pins it open, ⌃⌥V opens it
straight to Clips — with tabs Today · Agent · Meetings · Clips · Shelf · custom
collections (`NotchPinState`, `NotchTabModel`).
Data persists to `~/Library/Application Support/Mustard/mustard.store`.

## The agent / Claude subscription (critical)

The worker shells out to `claude -p "<prompt>" --output-format json` with a
**scrubbed environment** (all `ANTHROPIC_*` and `CLAUDE*` vars removed) and
**closed stdin** — both are load-bearing (see ADR-0003 and the comments in
`ClaudeRunner.swift`). It uses whatever subscription the `claude` CLI is logged
into on this machine. If runs 401, the CLI token expired: `/login` in a terminal,
or mint a long-lived one with `claude setup-token`. Run serially; this is anchored
to Leon's Mac (cannot move to a cloud server without re-introducing API billing).

## The agent loop & trust (the product's core)

Sweep (manual or scheduled) → Claude proposes ≤5 **Recommendations** (each with
`confidence`, `reasoning`, an editable `draft`, an `action_type`) → you triage in
the Agent console (Approve · Edit · Change action · Comment · Schedule · I'll do it
· Snooze · Reject) → approved items become delegated tasks that **execute** via `claude -p`
and land in the board's **Needs Review** column (no silent completion; output review lives
on the board, not `OutputCard` — ADR-0010) → you review (Accept · Request changes · Take
back). **Trust** (Manual/Supervised/Trusted/Autonomous) × **confidence**
decides auto-run; email/Slack/ticket actions are **always gated** regardless
(`TrustPolicy`, `RecommendationAction.isGated`). Tunable knobs:
`TrustPolicy.autoConfidenceThreshold` and `RecommendationAction.isGated`.

## Delegated agent tasks & the connected-worker fallback (READ THIS before debugging "stuck" agent cards)

A delegated task carries a durable **`AgentRun`** conversation (ordered **`AgentMessage`**s).
`AgentTaskCoordinator` owns **one serial local execution slot** (ADR-0003), automatically
picks up any `For Agent`/`Queued` agent-owned task, runs a **resumable** `claude -p` turn via
`ClaudeTaskRuntime`, and drives the lifecycle:

`For Agent`/`Queued` → **AgentTaskCoordinator** → Claude start/resume
→ **Needs You** (a question — the reply requeues and resumes the *same* provider session,
and the slot is released so the next task runs) │ **Needs Review** (Accept · Request changes ·
Take back). Every completed task lands in **Needs Review** — there is no silent completion.

Failures go through the pure **`AgentRetryPolicy`**: authentication pauses the runtime
globally; safe local failures back off (60/300/900s, capped at 3) then fail to review; a
timeout/process death on a ticket/draft action is **completion-uncertain** and goes to
review rather than retrying (idempotency: the task UID is binding creation metadata).

**The connected-worker fallback is the *only* path that uses the file bridge.** When a turn
returns `requires_connected_worker` (a capability headless `claude -p` can't reach —
Shortcut/Gmail/Slack/Chrome, ADR-0003), the run is flagged `requiresConnectedWorker` and
**only then** is the card exported to `<KB>/_agent/outbox/<uid>.json` (routed by area).
Ordinary local tasks are **never** exported — `BridgeExport` gates strictly on
`requiresConnectedWorker == true`, so the coordinator and the bridge never both claim the
same work. Export/ingest run on the app's ~10-min loop (`AgentService.exportWorkOrders` /
`ingestAgentResults`); ingest folds the result back into the run's conversation (ADR-0010).

**The worker is a skill: `drain-agent-queue`** — **not in this repo**; sibling `Codeheroes
work` vault repo at `.claude/skills/drain-agent-queue/SKILL.md` (local-only, **never pushed**,
that repo has tracked secrets). It runs in a **connected** Claude session, produces
**drafts/reversible artifacts only**, and writes `<KB>/_agent/results/<uid>.json`.

**Debugging "stuck" agent cards:**
- **An ordinary delegated task not moving** — it runs on the local serial slot, not the
  bridge. Check `AgentTaskCoordinator.lastError` / `authenticationRequired` (a paused runtime
  needs `claude /login` — the Agent Console shows one Retry banner). It will *not* appear in
  the outbox; only `requiresConnectedWorker` work is exported.
- **A connected-fallback card not advancing** — the worker hasn't run: a live
  `outbox/<uid>.json` with no matching `results/` file → run `drain-agent-queue` in a
  connected session.
- **The card has no client area.** Export filters strictly by area
  (`AgentService.exportWorkOrders` → `BridgeExport`; the `PersonalBoard.canHandOffToAgent`
  gate, BAK-90). A manually-delegated area-less card is **silently never exported** and
  strands forever — every path that can *manually* put a card in an agent lane goes
  through the area gate (`PersonalBoard.isAgentLane` / `newTaskPlacement`, the single
  source of truth). Give it a client-area list to unstick it. **Exception (F26):**
  *programmatic* hand-offs that can't carry an area — voice-routed captures — are rescued
  by an injected **default route** (the meeting vault, under `Code Heroes`) via
  `AgentTaskQueue.route(…, defaultRoute:)` + `AgentService.exportAreaLessWork`, so they
  reach the connected worker instead of stranding. The manual `delegate()` nudge is
  unchanged; the default only applies to area-*less* tasks.

## Voice capture (voice suite 2026-07-29 — ADR-0011 + specs)

Push-to-talk quick capture: hold **⌃⌥Space** anywhere, speak, release → an Inbox task
plus a notch-adjacent quick-edit card. Everything — transcription AND structuring —
runs on-device; there is no claude call and no network in this path.

- **Capture (no network).** `Capture/PushToTalkHotKey` (Carbon `RegisterEventHotKey`,
  press+release, no TCC grant; a chord conflict returns `.conflict`, never silent) →
  `Voice/AppleSpeechSession` (SpeechAnalyzer/SpeechTranscriber, one fresh session per
  capture, mic-fed via `MicrophoneFeed`) → `Capture/VoiceTaskCaptureCoordinator`
  sequences hotkey → the floating `VoiceCapturePillView` (live segments) → insert.
  Decisions live in pure, tested units (`Logic/VoiceCapture` outcome/segment mapping,
  `Logic/VoiceTaskDrafting` validation/merge). The task is born `source = "voice"`,
  `captureState = .raw`, owner `.me`, verbatim transcript on `captureTranscript`.
- **On-device drafting (replaces the old claude cleanup queue).** After commit the
  coordinator asks `Voice/VoiceTaskDraftGenerator` (Foundation Models guided
  generation, banded prompts in `Voice/Prompts/`) for title/notes/area/schedule/URLs;
  output passes `VoiceTaskDrafting.validated` and merges **only into fields whose
  revision counter is unchanged since the request began** — a user edit always wins.
  Success marks `.cleaned`; any failure leaves the task `.raw` and retryable. The
  model may only pick areas from the supplied list and never invents URLs/people/
  dates/completion.
- **Quick editor.** `Capture/VoiceTaskQuickEditController` owns one activating card
  below the `NotchScreenPicker` display; `VoiceTaskQuickEditState` holds the draft +
  revisions (Return in notes = newline; title Return/⌘Return/outside click = commit;
  Escape keeps the task; Open Fully → `NotchNavigation.pendingTask`).
- **Out of scope by spec:** automatic delegation/outward execution from a voice task
  (the old F25 v3 routing tier was removed with the cleanup queue). The F26 area-less
  rescue in the "stuck agent cards" section still applies to manually delegated work.
- **Build:** `build-app.sh`'s Info.plist carries `NSMicrophoneUsageDescription` +
  `NSSpeechRecognitionUsageDescription`. The hotkey/mic/panel layer is
  macOS-runtime-only (verified by eye); all decision logic is pure and unit-tested.
  The live SpeechAnalyzer driver needs macOS 27; on macOS 26 capture reports itself
  unavailable in the pill instead of failing silently.

## Git / PR conventions

- Work on a branch; never commit straight to `main` for feature work.
- Commit messages: `type(scope): summary`, end with the Co-Authored-By trailer.
  Commit in bite-sized, test-passing steps.
- A change is "done" only when `swift test` passes and `swift build` succeeds —
  state the evidence, don't assert success without it.
- Plans live in the sibling Triage-tool repo under
  `docs/superpowers/plans/` (historical) and now `docs/build-order.md` here.

## Finish the loop — do not park work (READ THIS BEFORE ENDING A SESSION)

On 2026-08-07 five finished branches were found sitting unmerged for up to six weeks.
None was blocked. Each had ended with "awaiting Leon's eye-check" written into a file
Leon never opened, so the handoff was invisible and the work silently rotted while
`main` moved 16k lines underneath it. Do not recreate that.

**Default: take work all the way to merged.** Build → full `swift test` green (verified
by **exit code**, never by grepping output) → push → PR → merge. A branch left unmerged
at end of session is the exception and must be justified out loud, not assumed.

**Eye-checks are the one thing only Leon can do — so ask him in chat, in your final
message, and say exactly what to look at.** Never leave a needed eye-check only in a
doc, a digest entry, or a Linear comment; those are records, not notifications. If Leon
is not around, merge anyway when tests are green and give him the `git revert <sha>`
line — reverting is cheap, rot is not ([[.agent-loop/digest.md]] carries a revert line
per merge for exactly this reason).

**Never leave a branch parked "pending review" without saying so in chat.** If you truly
must stop mid-flight, say in your final message: what is done, what is left, which
branch, and what unblocks it.

**One session, one job.** Do not start a second branch for work another session already
owns — check `git branch` and open PRs first. Two sessions on one feature produced a
duplicate PR (#100, closed) that had to be thrown away.

**Merged-or-not is not obvious — test it properly.** This repo squash-merges, so
`git cherry` and three-dot diffs both report already-merged branches as unmerged. To
check whether a branch's work is in `main`, reverse-apply its own contribution:
`git diff origin/main...<branch> | git apply --reverse --check -` — clean means merged.

## Workflow gates (project-bootstrap discipline)

| Gate | Who | When |
|------|-----|------|
| Spec approved | Leon | before any feature code |
| Plan approved | Leon | before implementation |
| PR reviewed | Leon | before merge |
| Outward actions confirmed | Leon | creating remote repo / tracker / backend / push |

## Out of scope (YAGNI) — deliberately not built

Multi-user/auth/billing; a hosted backend (no Supabase/Node — see ADR-0001);
web app; per-token API usage; email/Slack/meeting *sources* (only the vault source
exists — fields are modelled, not wired); live Google Calendar fetch (data layer
done, awaits Leon's OAuth client id); CloudKit sync + iOS target (schema is ready;
needs an Xcode project for entitlements — see ADR-0004).

## Agent Loop Workflows

This repo uses Leon's `dev-loop` plugin for autonomous development.

### Human Role

Leon sets product direction at kickoff and accepts the risk of irreversible outward
actions. Leon is NOT the engineering reviewer and is NOT a per-PR gate.

### Workflow Files

Read before running dev-loop workflows:

- `.agent-loop/project.yml` — repo identity, PR target, autonomy kill-switch
- `.agent-loop/checks.yml` — required verification commands (`swift test`, `swift build`)
- `.agent-loop/risk.yml` — task-label / path risk + irreversible outward actions
- `.agent-loop/review-rubric.md` — fresh-context review requirements
- `.agent-loop/done-criteria.md` — what must exist before merge

### How Work Lands

- Builders create branches, commits, PRs, and merges autonomously.
- Required checks from `.agent-loop/checks.yml` must pass.
- A fresh-context review (separate session) must pass before merge.
- Low/medium-risk changes auto-merge.
- High-risk changes auto-merge only after the `deep-review` adversarial panel passes;
  if the panel finds a blocker, the merge is held and logged to the digest.
- Irreversible outward actions (publish release, delete remote data, rotate secrets,
  force push) stop for Leon's explicit yes/no — the only human gate.
- Every merge or hold is appended to `.agent-loop/digest.md` with a ready `git revert`
  line, so Leon can scan and undo anything after the fact.

### Runtime Artifacts

Each run writes under `.agent-loop/runs/<run-id>/`: at minimum `trace.jsonl`,
`verification.md`, review reports, `risk-report.md`, `deep-review-report.md` (high
risk), and `pr-body.md`.
