# Mustard — Build Order / Backlog

The backlog as a checked-in file (no external tracker provisioned yet — that's a
gated outward action). Order reflects dependencies. Historical plan docs live in
the sibling Triage-tool repo under `docs/superpowers/plans/`.

## Done ✅

- [x] **F1 Foundation** — SPM package, SwiftData models (Area, TaskList, MustardTask),
      `DayPlanner`, Things-3-calm `Theme`, Today timeline + capture + carry-forward.
- [x] **F2 Agent loop (vault source)** — `ClaudeRunner`, `VaultSweep`, `AgentService`;
      recommend → decide → execute → OutputCard → review.
- [x] **F3 Hover panel** — ⌘⇧H, non-activating; current focus + next-up tasks.
- [x] **F4 Notch surface** — ⌘⇧N; idle rotation (focus → next meeting → waiting),
      hover-expand tray with today's meetings, recs, capture.
- [x] **F5 Scheduled sweeps** — `SweepScheduler`, 60s app loop, Auto-interval menu.
- [x] **F6 Command bar** — ⌘K; capture + navigation + sweep-now.
- [x] **F7 Trust & gating** — `TrustPolicy`, Manual/Supervised/Trusted/Autonomous,
      always-gated outbound actions, lock badges.
- [x] **F8 Personal Kanban board** — status columns, drag-drop, per-column add.
- [x] **F9 Week planner** — Mon–Sun grid, unscheduled rail, drag to (un)schedule.
- [x] **F10 Google Calendar data layer** — `CalendarEvent`, PKCE/OAuth helpers,
      events parser; meetings render on Week + notch.
- [x] **F11 Rich triage cards** — provenance, confidence meter, reasoning, re-bucket
      chips, editable draft, Comment/Snooze/Schedule/Reject; confidence × trust.
- [x] **F12 Task detail editor** — shared sheet (edit/status/owner/estimate/schedule,
      mark done, delete); tap-to-open from Today & Board.
- [x] **F13 Rich task properties** — priority, due, recurrence, tags, blocked-by,
      parent/subtasks (+ estimate); recurrence spawn, subtask cascade, blocked-aware
      next-up, cycle guard. See `task-properties-design.md`.
- [x] **F14 Week planner v2** — Sunsama/Akiflow/Morgen hybrid: per-day time axis
      (8am–6pm) where meetings + *timed* tasks anchor and size by duration
      (resize handle → `estimateMinutes`); untimed tasks list below; per-day
      quick-add; tap-to-detail, check-off, right-click menu; OVERDUE + UNSCHEDULED
      rail; agent tasks in purple. New `MustardTask.isTimed`. Plan:
      `docs/plans/2026-06-14-week-planner-v2.md`.
- [x] **F15 Agent feedback loop** — grounded, action-aware execution prompt
      (uses the proposed draft + action type + source context); a triage Comment is
      fed to the agent on the first run; `revise(card, feedback:)` re-runs with the
      feedback + prior output, producing a new OutputCard with version history.
      `AreaOrganizer`-style pure prompt builder in `VaultSweep`.
- [x] **F16 Areas/Lists organisation UI** — sidebar AREAS section (areas → nested
      lists with open-task counts, an Unfiled bucket), filtered `ListContentView`,
      inline create/rename/delete, **nullify** deletes (organising never loses
      tasks), area-grouped List picker in the detail sheet, list badges on rows.
      Pure `AreaOrganizer` logic.
- [x] **F17 Meeting task ingest** (was B1) — harvest curated `- [ ]` lines from the
      Meeting Sync vault notes into the inbox; two-way completion (tick → note
      checkbox, snapshot-first); vault→Area mapping. Pure `MeetingTaskParser` +
      `MeetingTaskSync` + `FileVaultIO`; provenance fields on `MustardTask`; wired into
      the 60s loop + `meetingVaultPath` Setting. Plan:
      `docs/plans/2026-06-16-meeting-task-ingest.md`.
- [x] **F18 Source-ingestion foundation + triage provenance** — per-source/project
      `SourceSettings`, `InboxIngest` (local `_recs/`), `SourceDedupe`; inert FYI +
      curated-KB `InboxLog`, `originalSource` provenance, `SourceBadge` pill,
      `SourceGrouping` fan-out, `create_task` → real inbox task (PR #13). Specs:
      `docs/specs/2026-06-15-source-ingestion-foundation.md`,
      `docs/specs/2026-06-19-triage-provenance-fyi-and-fanout-design.md`.
      *(The cloud email **scout** that feeds this remains deferred — see N3 / the
      mac-independence spec.)*
- [x] **F19 You → agent delegation** (was I1 ⭐) — "Ask agent to do this" (detail
      sheet + Today/Board/Week context menu) → classify `claude -p` routed by client
      Area (`AreaRouter`) → linked `Recommendation` (`MustardTask.delegation`); trust
      gates run-now (Trusted+) vs queue (`TrustPolicy.shouldAutoRunDelegation`); Accept
      → task done + output appended to Notes; agent may decline; `DelegationPhase`
      status badge. Plan: `docs/plans/2026-06-22-you-agent-delegation.md`.
      *On `feat/you-agent-delegation` — pending merge + Leon's eye-check of the surfaces.*
- [x] **F20 Notes Phase A (BAK-145)** — vault-backed markdown notes: whole-vault
      scanner (`NoteVaultIO`), `WikilinkIndex` link graph, `NoteIndexEntry` SwiftData
      mirror on a 5-min reindex, Notes tab (project sidebar, folder tree, filter),
      raw+preview editor with snapshot-guarded save, backlinks panel, wikilink
      navigation + create-from-unresolved, "+" note creation. Spec:
      `docs/specs/2026-07-05-notes-vault-backlinks-design.md`; plan:
      `docs/superpowers/plans/2026-07-05-notes-phase-a.md`. Phase B (attach to
      tasks/areas, BAK-154) and Phase C (search/tags/rich editor, BAK-155) deferred.
- [x] **F21 Morning ritual (was I5 ⭐, BAK-50 morning half)** — four-step "Plan your
      day" wizard: rollover review (carry-forward now stamps what it moved), inline
      agent standup, pick-today with capacity line, 1–3 focus stars (`focusOnDay`,
      auto-expiring) pinned atop Today + in the notch rotation. Gentle-prompt entry
      (Today banner · notch line · ⌘K), all gated by one pure `RitualPrompt` rule.
      Spec: `docs/specs/2026-07-06-morning-ritual-design.md`; plan:
      `docs/superpowers/plans/2026-07-06-morning-ritual.md`. Evening shutdown
      deliberately deferred (fast-follow once the morning habit sticks).
- [x] **F22 Craft pass — Theme depth/motion + live Notes editor (Notes Phase C)** —
      `Theme.Elevation/Motion/Metrics` + editorial type (with NS bridges), surface
      polish (markdown-rendered task-notes preview, card depth + hover lift, warmer
      empty states), and the live Craft-style editor replacing the Source/Preview
      toggle: TextKit-1 `MarkdownTextView` styling-as-you-type over pure
      `NoteDecoration` spans (no rewrite API — markdown on disk stays truth),
      slash menu (`SlashMenu`), block drag-reorder (`BlockReorder`, byte-pinned),
      hover gutter, subpage cards. Spec:
      `docs/specs/2026-07-06-craft-inspired-notes-and-daily-note-design.md`; plans:
      `docs/superpowers/plans/2026-07-06-craft-pass-phase0-1.md` +
      `…-craft-editor-phase2.md`. Daily Note (spec Phase 3) pinned/deferred.

## Next — buildable, unblocked 🟢 (queued 2026-07-12)

- [ ] **F26 Voice hand-off reaches the connected worker (real Gmail draft)**
      *(direction: Leon picked "connected worker, fix routing" 2026-07-23 — see ADR-0011
      addendum)*. Today an approved voice-routed outward task (`draft_email` etc.)
      promotes to `.queued`/agent but **strands** when it has no client area:
      `AgentTaskQueue.route` and `AgentService.exportWorkOrders` both key on the task's
      area, so a blank-area capture never routes to a worker outbox (BAK-90). Fix so the
      voice → agent → **real Gmail draft** → Needs Review loop completes:
      - **Default route for area-less agent tasks.** Introduce a configurable default
        agent project/KB (fallback to the meeting source's `Code Heroes` default). Pure
        `AgentTaskQueue.route` + `BridgeExport`/`exportWorkOrders` resolve it at route/
        export time when `task.list?.area == nil`. Keep the task's displayed area blank
        (per Leon) — the fallback is routing-only. TDD (extend `AgentTaskQueueTests`,
        `BridgeExportTests`).
      - **Keep `delegate()`'s BAK-90 entry nudge for MANUAL drags** (a person dragging a
        card to the agent lane still gets "give it a client area"); the default only
        rescues programmatic hand-offs (voice approval) that would otherwise strand.
      - **Worker side (Leon's sibling repo, out of this repo):** `drain-agent-queue` must
        actually call the Gmail connector to create the draft (not just write a draft
        artifact). Guided change in the `Codeheroes work` vault skill — never pushed here.
      - Acceptance: approve the "Email Bree" voice rec → card moves Queued → (worker) →
        Needs Review with a live Gmail draft link.

- [ ] **F27 Console/board attention consolidation** *(planning — raised by Leon
      2026-07-23)*. The Agent Console left column stacks three visually-similar things:
      **NEEDS YOU** (tasks with a question), **NEEDS REVIEW** (completed agent work
      awaiting accept/reject), and the **RECOMMENDATIONS** triage deck (proposals not yet
      started). The first two are tasks mid-execution and *also* appear in their board
      columns; the third is pre-execution proposals. Same card treatment blurs the phases
      and double-surfaces review work. Decide: (a) a visually distinct card for
      review/approval tasks vs. proposal cards, and (b) which surface (console vs. board)
      is canonical for each phase. **Spec/design first, no code yet.** Handover /
      starting context: `docs/specs/2026-07-23-console-board-attention-consolidation-design.md`.

## Done (2026-07-12) ✅

- [x] **F23 Craft editor — full markdown hiding + menu system** — five-phase follow-on
      to F22: shared `BlockKind` model (foundation), fully-hidden markdown syntax
      (Craft-style focus reveal, not just dimming), expanded insert (`/`) menu
      (headings 1-4, quote, lists, code, divider, table, image, sub-page), a "turn
      into" + block-actions context menu, and a floating inline-formatting toolbar
      (bold/italic/strikethrough/code/highlight/link). Color/Indentation/Alignment/
      Page-Card block types/embeds/Mermaid/inline-image-preview explicitly deferred
      (no clean markdown representation). Spec:
      `docs/specs/2026-07-12-craft-editor-menus-design.md`. Linear epic **BAK-248**
      (sub-issues BAK-249..253, phases 0-4) — **all five phases merged 2026-07-12**
      (PRs #91-#95, suite 696 → 835); follow-ups in BAK-254; Leon eye-check pending.

## Done (2026-07-13) ✅

- [x] **F24 Resumable agent task sessions (core MVP)** — Mustard automatically picks up
      delegated tasks, pauses for human answers without blocking the queue, resumes the
      same Claude session, and sends every result to a unified **Needs Review** flow.
      Durable `AgentRun`/`AgentMessage` conversation; provider-neutral `AgentRuntime` with
      the resumable `ClaudeTaskRuntime`; one serial `AgentTaskCoordinator`; pure
      `AgentTaskQueue`/`AgentTaskTransition`/`AgentRetryPolicy`; **Needs You** stage;
      structured worker contract (drafts-only, no send); the file bridge is now reserved
      for explicit `requiresConnectedWorker` fallback only. Task conversation + review UI
      in Task Detail and the Agent Console attention queue. Specs:
      `docs/specs/2026-07-13-agent-task-sessions-design.md`,
      `docs/superpowers/plans/2026-07-13-agent-task-sessions-core.md`. Branch
      `codex/agent-task-sessions-implementation` (suite → 984); **awaiting Leon's hands-on
      test before merge**. Remaining fast-follows: the learning loop
      (`.../2026-07-13-agent-learning-loop.md`), a Codex runtime adapter, parallel
      execution, live token streaming, automatic connected-session launch, and the
      pre-existing iOS shared-view-atom build break (unrelated; tracked separately).

## Next — needs Leon ⛔

- [ ] **N1 Live Google Calendar** — `GoogleAuthSession` (loopback + ASWebAuth) +
      `GoogleCalendarService` (connect/refresh/fetch → upsert) + Keychain + Settings.
      *Blocked on:* Leon's Google Cloud **OAuth client id** (Desktop app).
- [ ] **N2 CloudKit sync + iOS target** — migrate SPM → Xcode project, iCloud
      entitlement, iOS app sharing `MustardKit`. *Blocked on:* Apple Developer
      account / entitlements (Leon).
- [ ] **N3 More sources** — email / Slack as triage sources, via the
      `claude` CLI's MCP config. *Blocked on:* confirming MCP availability + scope.
      *(Meetings split out to B1 — handled by vault-harvest, not MCP.)*

## Next — buildable, unblocked 🟢

- [x] **F25 Voice capture** *(✅ BUILT — v1 capture shipped in PR #98; the v2
      claude-based cleanup queue and v3 routing were REPLACED 2026-07-29 by the
      Voice Suite's on-device drafting — see below. Automatic delegation from a
      voice task is now explicitly out of scope per the capture spec.)*
- [ ] **F27 Mustard Voice Suite** *(specs + plans approved 2026-07-29 —
      `docs/superpowers/{specs,plans}/2026-07-29-*`; Linear BAK-271…303; PR #101)*.
      Four workstreams on the modern Apple stack (SpeechAnalyzer + Foundation
      Models, fully on-device; macOS 26 floor, Xcode 27 beta):
      - **✅ Voice Core (BAK-271, Tasks 1–6):** toolchain + floor, shared
        contracts, asset readiness, `AppleSpeechSession`, on-device language
        service, Voice Setup surface.
      - **✅ Voice-task capture (BAK-272 Tasks 1–5):** `VoiceTaskDrafting`
        validation/merge, `VoiceTaskDraftGenerator` (Apple Intelligence guided
        drafting), `VoiceTaskCaptureCoordinator` (segment stream, revision-gated
        merge), notch-adjacent quick-edit card, legacy SFSpeech engine + claude
        cleanup queue removed. Remaining: Task 6 macOS 27 acceptance pass (BAK-286).
      - **✅ Dictation (BAK-273 Tasks 1–5):** AX focus snapshots, direct/verified-
        paste insertion, hold-⌃⌥D coordinator, nonactivating pill with recovery.
        Remaining: cross-app matrix (BAK-292, Leon).
      - **✅ Meeting recorder (BAK-274 Tasks 1–10):** consent-gated two-source
        capture, crash-recoverable storage, merged transcripts, evidence-backed
        digests, review/approval, suggestions, retention/Trash/export.
        Remaining: real-call matrix (BAK-303, Leon). A 25-agent adversarial
        review confirmed 20 findings mid-suite; all fixed (`c4ebabc`).

      **MERGED to `main` 2026-08-05 as `0c06e1a` (PR #101).** All three surfaces
      verified on hardware: capture, dictation (incl. the password-field refusal),
      and a two-channel meeting recording (44 "you" + 34 "meeting" segments merged,
      tracks finalized, digest generated). Live testing found **eleven runtime bugs
      the 1,443-test suite could not reach** — every one in the layer that only
      exists at runtime (Carbon handler chaining, `CGEventSource.keyState` lying
      about a claimed hotkey's own key, `SpeechTranscriber` needing `.fastResults`,
      ad-hoc signing invalidating TCC grants on every rebuild, Chromium apps
      returning `.success` from an AX write they discard, a starved SpeechAnalyzer
      session never returning from `finish()`). Lesson recorded: **instrument the
      runtime layer before attempting the first fix** — three speculative hotkey
      fixes made things worse; an `os_log` trace found each cause in one pass.

- [ ] **F28 Voice Suite hardening & meeting quality** *(drafted 2026-08-05 from
      hardware verification of F27; file B before A — B removes the false
      positives A would otherwise scan for)*:
      - [ ] **B Clean up recording intermediates** — `recovery.json` and both
        `.partial.caf` sources are retained after a successful export (~22 MB/min;
        an hour-long call leaves ~1.3 GB). Delete them only once the m4a export
        **and** the mix have both succeeded; on any failure leave everything
        untouched, since the partials are then the only copy of the audio.
      - [ ] **A Crash-recovery scan at launch, offering Resume** — the recovery
        machinery is fully built and unit-tested (manifest checkpointed with safe
        byte offsets, `.partial → .recover` transition) but **never read**, so
        interrupted recordings strand forever. Scan at launch, truncate each
        partial at `safeByteOffset`, and offer **Resume recording** (primary),
        **Finalize what was captured**, or **Discard**. Never auto-resume or
        auto-discard. *UX decided by Leon 2026-08-05: offer to resume.*
      - [ ] **C Verify meeting action-proposal extraction** — the verification
        recording produced zero proposals. Possibly correct for that clip, but
        extraction has never been shown to work. Pin it with a fixture-driven test
        over a canned transcript containing commitments, then confirm on real audio;
        no proposal may exist without a transcript-attributable evidence span.
      - [ ] **D Reduce transcript fragmentation** — 78 segments in 37 s (~2/sec),
        sentences chopped into two-word pieces, which also degrades the digest.
        Coalesce adjacent same-source finals into sentence-level segments in a pure
        `Logic/` unit before persistence, leaving `MeetingTranscriptMerge`'s
        cross-source ordering intact. Existing meetings are not retro-coalesced.
        Measure against a baseline tool by feeding both the **saved**
        `playback.m4a` — never run two transcribers live, which compares
        recordings rather than transcribers. *(Separately: over speakers the mic
        picks up system audio, so words land on both channels and the merge
        interleaves duplicates. Retest with headphones before treating it as a
        bug — it may be purely acoustic.)*

*(Previous: B1 shipped as **F17**, the multi-source foundation as **F18**, and I1
delegation as **F19**. Other unblocked candidate: **I2 Trust that earns itself** —
design locked 2026-06-16, still needs a plan.)*

## Later — autonomous, unblocked 🔓

- [ ] Gate tuning after real use (`autoConfidenceThreshold`, `isGated`).

## Ideas — brainstormed 2026-06-15, not yet planned 💡

Captured from a brainstorm; each needs its own spec + plan before building.
⭐ = highest-leverage (most advances the "plan your work + your agents' work" wedge).
Intended for Linear later — kept here for now.

**A. Deepen the agent loop**
- [x] **I1 ⭐ You → agent delegation** *(✅ BUILT — shipped as F19, see Done)* — hand a task to the agent from Board/Today
      ("Ask agent to do this"); it enters the existing recommend → approve → execute
      → review pipeline. Completes the currently one-way (agent → you) loop — the
      core of the product thesis.
      *Design decided 2026-06-16 (ready to spec):*
      - **Trigger** is an explicit "Ask agent to do this" action (detail sheet +
        Board/Today right-click) — *not* the assignee toggle.
      - **Classify pass:** delegating fires one `claude -p` that reads the task
        (+ vault) and proposes a Recommendation (`action_type`, draft, confidence,
        reasoning) — same shape as a sweep. Keeps gating honest and yields a draft to
        review/edit. The agent may **decline** ("this needs you") instead of faking output.
      - **Assignee** (`owner`) flips to `.agent` on delegate, back to `.me` on
        reject/discard; otherwise stays a manual label.
      - **Run timing:** trust decides — Manual/Supervised queue the proposal for
        approval; Trusted/Autonomous run immediately; email/Slack/ticket always gated.
      - **Loop close:** execute → OutputCard → **Accept** marks the task done + saves
        output to notes; **Revise** re-runs (F15 feedback loop); **Reject/Discard**
        returns it to you.
      - **Task status** shows *Agent working… → Awaiting review → done*, derived from
        the linked recommendation.
      - **New model bit:** a `MustardTask ↔ Recommendation` link.
- [ ] **I2 ⭐ Trust that earns itself** — track accept/revise/reject history per
      action type; surface the hit-rate ("vault notes: 9/10 accepted") and nudge to
      raise the trust level. Makes the trust ladder feel earned, not static.
      *Design decided 2026-06-16 (ready to spec):*
      - **Metric:** first-pass accept rate per action type (accepted with no revision
        ÷ executed), derived from existing Recommendations/OutputCards — no schema
        change. New pure `TrustCalibration` unit.
      - **Two-stage graduation, user-confirmed + reversible:** Stage 1 = auto-run
        (output still reviewed); Stage 2 = hands-off / auto-accept after a strong
        track record *while* auto-running — but **always still produces an OutputCard**
        (auto-marked accepted, never silent completion).
      - **Guardrails:** min sample (~5) before any nudge; confidence floor still
        applies at both stages; gated types (email/Slack/ticket) never graduate
        (track-record shown but informational).
      - **Symmetric pullback:** accept-rate slips below a floor → nudge to de-graduate.
      - **Override:** a graduated type runs even under Manual/Supervised; the global
        trust level is just the default for un-graduated types.
      - **State:** per-type stage stored in settings, passed into the pure
        `TrustPolicy`/`TrustCalibration` (kept testable).
      - **Surfaced:** "agent track record" strip + nudge banner in the Agent console.
- [ ] **I3 Multi-step agent plans** — agent proposes a stepwise plan, executes with
      checkpoints, one OutputCard per step. For larger delegations.
- [ ] **I4 Diff view on vault edits** — OutputCard shows a before/after diff for note
      changes, not just prose, so you can accept with confidence.

**B. Planning rituals (Sunsama/Akiflow DNA)**
- [ ] **I5 ⭐ Evening shutdown / morning planning** — guided flow: review what got
      done, roll over unfinished, plan tomorrow, set 1–3 intentions — and fold in the
      agent's overnight output + pending reviews. The human+agent daily standup.
- [ ] **I6 Capacity awareness** — sum today's `estimateMinutes` vs available hours;
      gently flag overcommit. (Deferred from the week planner.)
- [ ] **I7 Weekly objectives** — set a few goals for the week, link tasks to them,
      surface on the Week view. Gives the planner a "why". (Deferred from week planner.)

**C. Calm UX refinements**
- [ ] **I8 Natural-language capture** — ⌘K parses "email Sam re: BLE Thursday 2pm"
      into a scheduled task (and could suggest it as an agent draft-email).
- [ ] **I9 Tag filtering / saved smart lists** — tags exist (F13) but aren't
      filterable yet; add filtering + saved views.
- [ ] **I10 Focus mode** — "start" a task → live timer in the notch/hover, everything
      else dims.

