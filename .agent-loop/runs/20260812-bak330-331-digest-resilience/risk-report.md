# Risk report — BAK-330 + BAK-331

## Labels

- Feature
- Bug (BAK-330 fixes a real data-loss bug: one bad chunk previously
  discarded every chunk that DID summarise successfully)

## Touched paths

- `Sources/MustardKit/Logic/MeetingDigestChunker.swift` — under `Sources/`
- `Sources/MustardKit/Meeting/MeetingDigestService.swift` — under `Sources/`
- `Sources/MustardKit/Models/MeetingRecord.swift` — under `Sources/`
- `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift` — under `Sources/`
- `Sources/MustardKit/Views/MeetingReviewView.swift` — under `Sources/`
- `Tests/MustardTests/MeetingDigestFailureReasonTests.swift` — new file, under `Tests/`
- `Tests/MustardTests/MeetingDigestServiceTests.swift` — under `Tests/`
- `Tests/MustardTests/MeetingRecordModelTests.swift` — under `Tests/`
- `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` — under `Tests/`
- `.agent-loop/runs/20260812-bak330-331-digest-resilience/` — run artifacts

Per `.agent-loop/risk.yml` path_risk: `Sources/` → **medium**; `Tests/` →
**low**. No path matches any `high` pattern — no `.github/workflows/`,
`.env`, `secret`, `auth`, `oauth`, `ClaudeRunner`, `TrustPolicy`, or
`RecommendationAction` touched anywhere in this change.

## Risk class: medium

Normal feature/bugfix work with a well-understood blast radius, entirely
inside the meeting-digest subsystem:

- **Behavior change, contained.** `MeetingDigestService.digest`'s map loop
  now collects partial failures instead of aborting on the first one. The
  change is additive to the `Result` type (`MeetingDigest.omittedSpans`, new
  field defaulting to `[]`) and preserves every existing failure path
  exactly (capabilities/missing-prompt short-circuit unchanged; all-chunks-fail
  still fails; reduce failure still fails). No other caller of
  `MeetingDigestService` exists besides `MeetingCaptureCoordinator`.
- **Schema addition, not a schema change.** `MeetingRecord` gains two
  OPTIONAL fields (`digestOmissionNote: String?`, `digestFailureReasonRaw:
  String?`) and `MeetingDigestStatus` gains one new case (`.partial`). Per
  SwiftData's lightweight-migration rules, adding optional stored properties
  to an existing `@Model` and adding a case to a String-backed enum are both
  additive and non-destructive — no existing `mustard.store` row needs
  rewriting, and no existing row's `digestStatusRaw`/`digestFailureReasonRaw`
  values become invalid (both accessors already treat an unrecognised raw
  value as a safe default/`nil`, which is exactly what a pre-migration row
  with a missing `digestFailureReasonRaw` decodes to).
- **View change, forced by the compiler, not by choice.** Adding
  `MeetingDigestStatus.partial` made the existing `switch meeting.digestStatus`
  in `MeetingReviewView.digestSection` non-exhaustive; it was updated in the
  same commit as the model change (see `task.md`). Grepped `Sources/` for
  every `MeetingDigestStatus`/`digestStatus` reference first — this is the
  only switch over the enum in the codebase, so no other view or module
  needed touching.
- **No persistence/trust/gating logic touched.** `TrustPolicy`,
  `RecommendationAction`, `ClaudeRunner`, and the agent bridge/export paths
  are untouched. The digest failure log line
  (`voiceLog.error("meeting: digest failed reason=<rawValue>")`) logs only
  the mapped enum's rawValue — never the raw model error string or any
  transcript content — consistent with the repo's existing privacy posture
  for this log category.
- **No UI colors/tokens invented.** `MeetingReviewView`'s new caption text
  reuses the exact `Theme.Fonts.caption` / `Theme.Palette.textSecondary`
  styling already used by the pre-existing failure caption — no new design
  tokens, no hardcoded colors.

Nothing here rises to `high`: no auth/secret/deployment surface, no money,
no irreversible effect, and no change to what the agent is trusted to do
autonomously.

## Outward actions

None. No git tags, releases, remote-ref deletions, secret rotation, or force
pushes. No network calls, no email/Slack/ticket actions — digest generation
is entirely on-device (`OnDeviceGenerating`/Foundation Models), unchanged by
this work. This branch was not pushed and no PR was opened, per the task's
explicit instruction — the orchestrator reviews the diff first.

## Notes

- `ClaudeRunner`, `TrustPolicy`, and `RecommendationAction` were not
  touched, as instructed.
- The one intentional deviation from the ticket's failure-copy table
  (`appleIntelligenceDisabled` offers retry, unlike the ticket's default
  no-retry suggestion for "known permanent causes") is documented in code
  comments (`MeetingDigestFailureReason.offersRetry`), in
  `MeetingDigestFailureReasonTests.test_appleIntelligenceDisabled_offersRetry_deliberateDeviation`,
  and in `task.md` — flagged here explicitly for reviewer attention since it
  is a product-copy judgment call, not a mechanical implementation of the
  ticket.
