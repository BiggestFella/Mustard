# Risk report — BAK-332

## Labels

- Bug (data-loss incident: a source's audio could vanish entirely while the
  meeting still reported `status = ready`, `audioFinalized = true`, with no
  user-visible sign anything was wrong)

## Touched paths

- `Sources/MustardKit/Logic/MeetingSourceParity.swift` — new file, under `Sources/`
- `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift` — under `Sources/`
- `Tests/MustardTests/MeetingSourceParityTests.swift` — new file, under `Tests/`
- `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` — under `Tests/`
- `.agent-loop/runs/20260812-bak332-audio-source-parity/` — run artifacts

Per `.agent-loop/risk.yml` path_risk: `Sources/` → **medium**; `Tests/` →
**low**. No path matches any `high` pattern — `ClaudeRunner`, `TrustPolicy`,
`RecommendationAction`, `auth`, `oauth`, `.env`, `secret`, and
`.github/workflows/` are all untouched.

## Risk class: medium

- **Behavior change, additive and narrow.** `MeetingSourceParity` is a new,
  pure, side-effect-free type — it cannot regress anything by existing.
  `MeetingCaptureCoordinator`'s change is two additions, both non-destructive:
  (1) the route closure now logs a failed writer-append once per channel
  instead of swallowing it via bare `try?` — the append's control flow
  (still `try`/best-effort, still routes to transcription regardless) is
  unchanged, only the failure is now observable; (2) `stop()` gained one new
  call, `applySourceParity(segments:to:)`, which only ever sets
  `record.errorMessage` — `status`, `audioFinalized`, the persisted
  transcript, and the finalized audio files are never touched by it.
- **No schema change.** `MeetingRecord.errorMessage: String?` already existed
  (used by `interrupt()` and export-failure paths) — this reuses it rather
  than adding a field. `MeetingSourceParity` is Logic-layer only, not a
  `@Model`.
- **Deliberate rejection of the more "obvious" fix.** Setting
  `status = .partial` on a mismatch was considered and rejected — read in
  `MeetingReviewView.statusBadge` (Views/MeetingReviewView.swift:128-137)
  before deciding: `.partial` renders as **"Interrupted"** (warning color)
  and `digestSection` gates both "Generate digest" and "Retry digest" on
  `status == .ready` (MeetingReviewView.swift:331, 342) — degrading status
  would have hidden digest actions on a meeting whose transcript and digest
  both succeeded, which is a worse regression than the one being fixed. No
  view file was touched; `errorMessage` already renders unconditionally in
  the existing header.
- **No persistence/trust/gating logic touched.** `TrustPolicy`,
  `RecommendationAction`, `ClaudeRunner`, and the agent bridge/export paths
  are untouched. The new log lines
  (`voiceLog.error("meeting: writer append failed channel=...")` and
  `voiceLog.error("meeting: source parity mismatch missing=...")`) log only
  channel names/error descriptions — never transcript content.
- **Recovery semantics unchanged.** `MeetingRecoveryManifest`,
  `checkpoint()`, and `recoverOnLaunch()` are byte-for-byte unchanged (per
  the brief's hard rule) — Phase 1 investigation concluded the manifest
  already lists exactly the sources that successfully opened a file; the fix
  is surfacing the loss, not changing what the manifest records.

Nothing here rises to `high`: no auth/secret/deployment surface, no money, no
irreversible effect, no change to autonomous-run gating.

## Outward actions

None. No git tags, releases, remote-ref deletions, secret rotation, or force
pushes. No network calls; this fix is entirely local (SwiftData +
AVFoundation writer/coordinator logic). Branch not pushed, no PR opened, per
the task's explicit instruction.

## Notes

- The status-vs-errorMessage design decision (the one place this task asked
  for judgment rather than mechanical implementation) is documented in
  `task.md` under "Design decisions" with the exact view-code evidence that
  drove it, and is flagged here again for reviewer attention.
- `MeetingSegmentSource`/`MeetingAudioSource` display-name mapping
  (`Sources/MustardKit/Logic/MeetingSourceParity.swift`, `displayName`) is
  new product copy ("Microphone" / "System Audio") — grepped `Sources/` first
  to confirm no existing `MeetingAudioSource` extension or display-name
  helper already existed to reuse.
