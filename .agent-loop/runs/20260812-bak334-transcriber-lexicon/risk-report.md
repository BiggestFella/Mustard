# Risk report — BAK-334

## Labels

- Feature (contextual-vocabulary biasing for on-device transcription;
  no new outward surface, no schema change)

## Touched paths

- `Sources/MustardKit/Logic/VoiceLexicon.swift` — new file, under `Sources/`
- `Sources/MustardKit/Voice/VoiceLexiconSource.swift` — new file, under `Sources/`
- `Sources/MustardKit/Voice/VoiceServices.swift` — under `Sources/`
- `Sources/MustardKit/Meeting/MeetingTranscriptionService.swift` — under `Sources/`
- `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift` — under `Sources/`
- `Sources/MustardKit/Capture/VoiceTaskCaptureCoordinator.swift` — under `Sources/`
- `Sources/MustardKit/Views/VoiceSetupView.swift` — under `Sources/`
- `Tests/MustardTests/VoiceLexiconTests.swift` — new file, under `Tests/`
- `.agent-loop/runs/20260812-bak334-transcriber-lexicon/` — run artifacts

Per `.agent-loop/risk.yml` path_risk: `Sources/` → **medium**; `Tests/` →
**low**. No path matches any `high` pattern — `ClaudeRunner`, `TrustPolicy`,
`RecommendationAction`, `auth`, `oauth`, `.env`, `secret`, and
`.github/workflows/` are all untouched. `Dictation/` (system-wide dictation)
was explicitly out of scope for this task and was not touched.

## Risk class: medium

- **No new outward action, no schema change, no auth surface.** This
  feature reads data Mustard already persists (`Area`, `TaskList`,
  `MustardTask`, `MeetingActionProposal` — all existing fields, no new
  `@Model` field anywhere) and hands derived strings to an on-device
  recognizer. Nothing leaves the Mac; nothing is written that wasn't
  already being written (the new `UserDefaults` key
  `voice.lexicon.userTerms` is the only new persisted state, and it's a
  single user-typed text field, not sensitive).
- **Protocol change is additive by construction.** `VoiceTranscribing`
  gained a new requirement (`setContext(_:)`), but a default no-op
  extension means every existing conformer — including the two test-double
  `StubSession` classes in `MeetingTranscriptMergeTests.swift` and
  `MeetingCaptureCoordinatorTests.swift` — compiles unchanged and behaves
  exactly as before (a no-op) unless it opts in. `AppleSpeechSession`'s
  pre-existing `setContext` method (untouched by this task) is the only
  conformer that actually overrides the default.
- **Biasing failures are non-fatal by design.** Both call sites
  (`MeetingTranscriptionService.start`, `MicrophoneFeed.begin`) apply the
  lexicon via `try? await session.setContext(...)` — a failure to bias
  never blocks starting a recording or a capture. This mirrors the
  existing pattern in this codebase of degrading enhancements gracefully
  without degrading the primary recording/capture guarantee.
- **The one real behavior change: a network-free, on-device recognizer now
  receives extra strings it didn't before.** `AnalysisContext
  .contextualStrings[.general]` is Apple's own supported vocabulary-biasing
  hook (verified against the beta SDK's swiftinterface, not assumed — see
  `task.md`'s Phase-0 section) and stays entirely on-device — no new
  network call, no new data leaving the Mac. Worst case if the derivation
  is somehow wrong: transcription biases toward the wrong words, which is a
  quality regression a user can fix by clearing "Custom vocabulary" or
  editing their areas/lists — it cannot corrupt data, leak anything, or
  block any existing flow, since every call site swallows a `setContext`
  failure and the underlying `start`/`append`/`finish` lifecycle is
  unchanged.
- **Derivation is pure and fully unit-tested (18 tests).** The one
  SwiftData-touching function (`VoiceLexiconSource.fetch`) is a straight
  `FetchDescriptor` read with no writes, tested against an in-memory
  container.

Nothing here rises to `high`: no auth/secret/deployment surface, no money,
no irreversible effect, no change to autonomous-run gating (`TrustPolicy`
untouched), no change to outward/connector action routing
(`RecommendationAction` untouched).

## Outward actions

None. No git tags, releases, remote-ref deletions, secret rotation, or force
pushes. No network calls — the biasing hook and every fetch in this change
are local (SwiftData + on-device `Speech` framework). Branch not pushed, no
PR opened, per the task's explicit instruction.

## Notes for reviewer

- **Recognition-accuracy improvement is NOT verified by automated tests**
  (this is by the task's own design — "No recognition-accuracy tests…the
  recognition improvement is a Leon eye-check", matching this repo's
  standing rule that live SpeechAnalyzer behavior can only be verified by
  ear on real hardware). What IS verified: the SDK API is real (compiler
  evidence in `task.md`), the derivation logic is correct (18 tests), and
  the wiring reaches the session (protocol default-implementation +
  explicit call-site reading, confirmed by a full-package build).
- **One scoped gap, flagged not hidden:** the after-Stop fallback file
  transcription path (`MeetingTranscriptionService.transcribeAudioFile`)
  does not receive the lexicon — see `task.md`'s Deviations section for
  why (avoiding test churn across 6 existing call sites for a closure
  signature change). This means the sequential-fallback mode's *second*
  channel (transcribed after Stop, from the recorded file) misses biasing
  that the two live sessions get. Low severity: this fallback only
  triggers when the analyzer stack can't run two live sessions
  simultaneously, and the channel still transcribes — just without the
  vocabulary boost.
