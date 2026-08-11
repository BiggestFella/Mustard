# Risk report — BAK-329

## Labels

- Feature

## Touched paths

- `Sources/MustardKit/Logic/MeetingUtteranceMerge.swift` — new file, under `Sources/`
- `Sources/MustardKit/Meeting/MeetingDigestService.swift` — under `Sources/`
- `Tests/MustardTests/MeetingUtteranceMergeTests.swift` — new file, under `Tests/`
- `Tests/MustardTests/MeetingDigestServiceTests.swift` — under `Tests/`
- `.agent-loop/runs/20260812-bak329-utterance-merge/` — run artifacts

Per `.agent-loop/risk.yml` path_risk: `Sources/` → **medium**; `Tests/` →
**low**. No path matches any `high` pattern (no `auth`/`oauth`/`secret`, no
`ClaudeRunner`, no `TrustPolicy`, no `RecommendationAction`, no
`.github/workflows/`, no `.env`).

## Risk class: medium

Normal feature work with a narrow, well-understood blast radius: one new
pure `Logic/` unit (`MeetingUtteranceMerge`) and a two-line change to its
single caller (`MeetingDigestService.digest`) that swaps what feeds the
already-existing chunker/prompt path. No UI touched, no persistence schema
touched, no agent trust/gating logic touched. The persisted transcript
(`VoiceTranscriptSegment` storage) is never modified — the merge is a pure,
read-only view computed at digest time. Evidence validation (`validIDs`)
deliberately still keys off the original, unmerged `segments` parameter, so
the safety property "no digest action survives without a real persisted
segment behind it" is unchanged.

## Outward actions

None. No git tags, releases, remote-ref deletions, secret rotation, or force
pushes. No network calls, no email/Slack/ticket actions. This branch was not
pushed and no PR was opened, per the task's explicit instruction — the
orchestrator reviews the diff first.

## Notes

- `ClaudeRunner`, `TrustPolicy`, and `RecommendationAction` were not
  touched, as instructed.
- No colors/UI were touched; `Views/` was not touched.
- `retryDigest` in the meeting coordinator was deliberately left untouched
  per the task spec — it already passes persisted segments into
  `MeetingDigestService.digest`, and merging now happens inside the service,
  so no caller-side change was needed or made.
