# Risk report — BAK-335

## Labels

- Feature (verbal-handoff speaker attribution for the meeting recorder's
  transcript; no new outward surface, no auth surface, no schema-breaking
  change)

## Touched paths

- `Sources/MustardKit/Logic/MeetingSpeakerAttribution.swift` — new file, under `Sources/`
- `Sources/MustardKit/Meeting/MeetingSpeakerCandidateSource.swift` — new file, under `Sources/`
- `Sources/MustardKit/Voice/VoiceTypes.swift` — under `Sources/`
- `Sources/MustardKit/Models/MeetingTranscriptSegment.swift` — under `Sources/`
- `Sources/MustardKit/Logic/MeetingUtteranceMerge.swift` — under `Sources/`
- `Sources/MustardKit/Meeting/MeetingDigestService.swift` — under `Sources/`
- `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift` — under `Sources/`
- `Sources/MustardKit/Views/MeetingTranscriptView.swift` — under `Sources/`
- `Tests/MustardTests/MeetingSpeakerAttributionTests.swift` — new file, under `Tests/`
- `Tests/MustardTests/MeetingSpeakerCandidateSourceTests.swift` — new file, under `Tests/`
- `Tests/MustardTests/MeetingUtteranceMergeTests.swift` — under `Tests/`
- `Tests/MustardTests/MeetingDigestServiceTests.swift` — under `Tests/`
- `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` — under `Tests/`
- `.agent-loop/runs/20260812-bak335-speaker-attribution/` — run artifacts

Per `.agent-loop/risk.yml` `path_risk`: `Sources/` → **medium**; `Tests/` →
**low**. No path matches any `high` pattern — `ClaudeRunner`, `TrustPolicy`,
`RecommendationAction`, `auth`, `oauth`, `.env`, `secret`, and
`.github/workflows/` are all untouched, confirmed by
`git diff --name-only origin/main...HEAD | grep -iE "Dictation/|ClaudeRunner|TrustPolicy|outbox|bridge"`
→ no matches. `Sources/MustardKit/Dictation/` (system-wide dictation) and
the agent-bridge code (`AgentTaskCoordinator`, `BridgeExport`,
outbox/results) were explicitly out of scope for this task and were not
touched.

## Risk class: medium

- **No new outward action, no auth surface, no destructive operation.**
  This feature reads data Mustard already persists (past
  `MeetingActionProposal.owner` strings, the existing
  `VoiceLexiconUserTerms` UserDefaults key) and writes a new optional field
  onto an existing model. Nothing leaves the Mac; no network call, no
  file-system write outside the existing SwiftData store, no new
  UserDefaults key.
- **Schema change is additive and optional.** `MeetingTranscriptSegment`
  gains `speaker: String?` with no explicit default beyond Swift's
  automatic `nil` for optionals — matching the exact style of the model's
  existing `correctedText`/`confidence` fields. This is a lightweight
  SwiftData migration: existing stores load with `speaker == nil`
  everywhere, no versioned schema, no data loss risk.
- **Protocol/struct change is additive by construction.**
  `VoiceTranscriptSegment` gained a new field (`speaker`) via a trailing
  DEFAULTED init parameter (`speaker: String? = nil`) — verified every
  existing call site across `Sources/` and `Tests/` (grepped and counted
  before making the change) compiles unchanged.
- **The core behavioral guarantee is the opposite of risky: it is a
  deliberate REFUSAL to act on uncertain input.** The entire feature is
  built around never guessing — an unmatched handoff name always degrades
  to `nil` rather than fabricating or carrying forward a speaker. This is
  the anti-pattern the task exists to avoid (the "Liam" fabrication in a
  competitor tool), so the risk profile here skews toward "did we correctly
  refuse" rather than "did we correctly act."
- **UI change is render-and-dispatch only.** `MeetingTranscriptView`'s new
  correction Menu writes directly to a persisted `MeetingTranscriptSegment`
  field the user already fully owns (same trust level as the existing
  `correctedText` editing already in that view) — no new permission
  surface, no new panel.
- **Digest prompt change is content-only, not format.** The `"<Speaker>:
  "` prefix changes what text the on-device model sees; it does not change
  evidence-id computation (`MeetingTranscriptMerge.persistentID` depends
  only on `source` + `id`, never `text`), so the existing evidence
  validation in `MeetingDigestService` continues to gate every proposal on
  a real transcript segment exactly as before. Verified explicitly by
  `test_attributedUtterance_evidenceIDIsUnaffectedByThePrefix`.

No path matches `high`; nothing here touches the agent execution loop,
trust/autonomy gating, or any credential/secret surface. **Risk class:
medium**, consistent with every other Sources/-touching feature task in
this run sequence (BAK-328 through BAK-334).
