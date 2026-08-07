# ADR-0011 — Voice capture: push-to-talk hotkey + queued agent cleanup

**Status:** Accepted (2026-07-22, spec approved by Leon).

## Context

Adding a task should be as fast as saying it. The ask: hold a global hotkey anywhere
on the Mac, speak, release — the words become a board task. Spoken captures are
natural language ("create a task for me to release the prep app to testing groups and
schedule it on the 9th of August", "I need you to check the design meeting I had
yesterday, and email the action points to Matt"), so raw transcripts want structuring:
a short title, the detail as description, a schedule date, and — sometimes — routing
into the agent process.

Constraints that shaped the design:

- The only LLM channel is headless `claude -p` on the subscription (ADR-0003): seconds
  of cold-start latency, one serial execution slot shared with sweeps and delegated
  tasks (`AgentExecutionGate`). It cannot sit on the capture path.
- Agent-owned tasks auto-execute: `AgentTaskCoordinator` picks up `For Agent`/`Queued`
  agent tasks within seconds. Auto-assigning `owner = .agent` from a speech
  transcription would bypass the triage → approval loop entirely.
- Email/Slack/ticket actions are always gated (`RecommendationAction.isGated`,
  ADR-0006) — "email Matt" off a possibly-misheard transcript must never fire itself.
- Agent tasks without a client area strand silently (BAK-90 area gate).
- The app is ad-hoc signed with no entitlements file (ADR-0004): the global hotkey
  must not require Accessibility/Input Monitoring TCC grants.

## Decision

A three-stage pipeline: **capture instantly, clean up asynchronously, route via the
existing recommendation loop.**

1. **Capture (no LLM, no network).** A Carbon `RegisterEventHotKey` push-to-talk
   hotkey (default ⌃⌥Space — pressed *and* released events, no TCC permission needed)
   drives on-device `SFSpeechRecognizer` transcription (`AVAudioEngine` mic tap,
   `requiresOnDeviceRecognition` where supported — audio never leaves the Mac). A
   non-activating floating pill (the `HoverPanel` pattern) shows the live transcript;
   it never steals focus. On release, the normalized transcript is inserted as a
   `MustardTask` in Inbox, `owner = .me`, `source = "voice"`, `captureState = .raw`,
   with the verbatim transcript preserved on `captureTranscript`. Holds under 300 ms
   or empty transcripts cancel. Nothing downstream can lose the capture.

2. **Cleanup queue (tier 1 — auto-applied, reversible).** Raw captures queue for a
   batched `claude -p` text-transform pass (≤5 per call, mirroring the sweep budget),
   run from the app's scheduler tick only when the execution gate is free. The prompt
   carries today's date/weekday/timezone so relative dates resolve. Per task it
   returns title, description, an optional schedule (date ± time), and an optional
   area — applied directly to the task (`PersonalBoard.normalizePlacement` keeps the
   scheduled-placement invariant). Failures back off 60/300/900 s, capped at 3
   attempts (the `AgentRetryPolicy` ladder), then park as `captureState = .failed` —
   the task stays usable with its raw title either way.

3. **Routing (tier 2 — proposed, never auto-applied).** When a capture is
   agent-shaped, the cleanup pass additionally emits a **`Recommendation`**
   (`source = "voice"`, with confidence/reasoning/draft and an allowed
   `action_type` of draft_email / draft_slack / ticket_write / vault_note), linked
   `rec.task = capturedTask`. It surfaces in the existing triage deck; approval
   promotes the *same* task through `AgentService.decide` → the ordinary gating,
   trust, area-stamping, and connected-worker bridge machinery. The cleanup pass
   never sets `owner = .agent` and never emits a `create_task` route (that case is
   simply tier 1).

## Consequences

- Release-to-task is instant and offline-safe; LLM quality arrives seconds-to-minutes
  later and is strictly additive. A dead CLI degrades to "raw transcript as title".
- The triage/trust/gating loop is preserved verbatim for voice-originated agent work —
  including the always-gated outward actions and the BAK-90 area gate at approval.
  Voice recs linked to a task are skipped by `applyTrust` (same rule as delegated
  recs), so routing always passes through your hands for now.
- Two new Info.plist usage strings (`NSMicrophoneUsageDescription`,
  `NSSpeechRecognitionUsageDescription`) in `build-app.sh`; macOS prompts once each.
- The hotkey/mic/speech layer is macOS-runtime-only and verified by eye; everything
  with a decision in it (capture outcome, queue picking, backoff, prompt, parser,
  schedule resolution, apply/routing) is pure and unit-tested.
- SwiftData schema stays CloudKit-additive (ADR-0001): four new optional/defaulted
  `MustardTask` columns, one new `SourceID` case.

## Addendum (2026-07-23) — area-less hand-offs reach the connected worker

First hands-on test surfaced the strand: approving a voice-routed `draft_email` rec
promotes the task to `.queued`/agent, but a voice capture frequently has **no client
area** ("Email Bree about Lottie animations" maps to no client). Both
`AgentTaskQueue.route` and `AgentService.exportWorkOrders` key on the task's area, so a
blank-area task never routes to a worker outbox and stalls in Queued forever (BAK-90).

**Decision (Leon, 2026-07-23): keep the connected-worker model (ADR-0010) and fix the
routing** — chosen over wiring native Gmail into the app. The cleanup pass still only
*infers* an area when the transcript makes it obvious and otherwise leaves it blank (the
displayed area stays blank). To unstrand the hand-off, a **configurable default agent
project/KB** (falling back to the meeting source's `Code Heroes` default) resolves at
route/export time whenever the task has no area — routing-only, it does not stamp the
task. The manual `delegate()` BAK-90 nudge ("give it a client area") stays for a person
dragging a card into the agent lane; the default only rescues programmatic hand-offs
(voice approval) that would otherwise strand. The worker (`drain-agent-queue`, in Leon's
sibling vault repo, never pushed here) owns the actual Gmail-connector call that creates
the real draft. Tracked as **F26**. The console/board attention-surface cleanup this
test also surfaced is **F27** (planning).
