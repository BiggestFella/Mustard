# Fresh-context review — BAK-334 transcriber domain lexicon

Branch `agent/bak-334-transcriber-lexicon`, diff base `origin/main`
(4 commits, 12 files, +1031/-12). Reviewed with no prior context; every
claim in `task.md`/`risk-report.md`/`verification.md` was checked against
source, not taken on faith.

## Standards Review — PASS

- Touched paths match the task's own directory restriction: `Logic/`,
  `Voice/`, `Meeting/`, `Capture/`, `Views/VoiceSetupView.swift`, `Tests/`.
  `Dictation/`, `ClaudeRunner`, `TrustPolicy` untouched (confirmed via
  `git diff --stat`).
- `VoiceLexicon.swift` is pure (no imports beyond `Foundation`, no
  SwiftData/Combine/AVFoundation). All SwiftData access isolated to the one
  fetch-assembly seam (`VoiceLexiconSource.swift`), matching the repo's
  `#Predicate`/in-memory-container test pattern used elsewhere
  (`CalendarSync.swift`, `AgentBridgeServiceTests.swift`).
- `VoiceSetupView`'s new "CUSTOM VOCABULARY" section is render/dispatch
  only: a `Text` caption, a `TextEditor` bound via `@AppStorage`, reuses the
  existing `sectionHeader(_:)` helper. Every color/font reference is a
  `Theme.Palette`/`Theme.Fonts` token (`textSecondary`, `body`,
  `textPrimary`, `surface`, `hairline`) — no hardcoded colors, no decision
  logic in the view.
- `VoiceTranscribing.setContext(_:)` is added with a default no-op
  extension — additive, not a breaking protocol change. Verified the two
  existing test-double `StubSession` types (`MeetingTranscriptMergeTests.swift`,
  `MeetingCaptureCoordinatorTests.swift`) compile unchanged and the full
  suite passes, confirming they fall through to the no-op default.
- No unrelated refactors found in the diff.

## Spec Review (BAK-334 acceptance criteria) — PASS, one flagged gap (non-blocking)

- **Terms supplied per session, refreshed from current data.** Confirmed
  both paths recompute at session start, not once at app launch:
  - Meeting: `MeetingCaptureCoordinator.confirmStart` calls
    `VoiceLexiconSource.fetch(...)` once per meeting start
    (`MeetingCaptureCoordinator.swift:117-118`), passed into
    `MeetingTranscriptionService.start(sources:lexicon:)`, which calls
    `try? await you.setContext(lexicon)` (line 58) **and**
    `try? await meeting.setContext(lexicon)` (line 71) — both the `you` and
    `meeting` sessions get it, each right after `makeSession()` and before
    that session's own `start(source:)`. This directly satisfies the "BOTH
    sessions" check in the task brief.
  - Push-to-talk: `VoiceTaskCaptureCoordinator`'s production init wires
    `lexicon: { VoiceLexiconSource.fetch(context: context, now: .now, ...) }`
    as a closure (not a captured array), and `MicrophoneFeed.begin()` calls
    `lexicon()` fresh on every hotkey press/release cycle
    (`VoiceTaskCaptureCoordinator.swift:591`), before `session.start(source:)`.
    Confirmed not a hardcoded array — it's a live `ModelContext` fetch.
- **Bounded, ranked list degrading sensibly.** `VoiceLexicon.terms` ranks
  userTerms → areas → taskLists → proposalOwners → title-derived, one
  dedup+bounds pass, cap defaults to 100. Verified via
  `test_cap_enforced` and `test_userTerms_surviveCap_evenWhenOtherCategoriesOverflow`
  (ran locally, both green) that user terms are copied into the kept list
  first and therefore survive truncation even when other categories alone
  would overflow the cap.
- **User-editable term list, merged with derived terms.** `VoiceSetupView`
  binds `@AppStorage(VoiceLexiconUserTerms.key)`; both capture paths load it
  via `VoiceLexiconUserTerms.load()` and pass it as `userTerms:` into
  `VoiceLexiconSource.fetch`, which ranks it first in `VoiceLexicon.terms`.
  Genuinely merged, not overridden.
- **Recognition improvement is a Leon eye-check, not unit-tested.** Grepped
  all new/touched test files for accuracy-style assertions
  (`accuracy`, `recognition`, or planted proper nouns being asserted as
  "transcribed correctly") — none found. Every `VoiceLexiconTests` test
  checks derivation/ranking logic, not recognizer output. No test pretends
  to validate the actual transcription improvement.
- **Flagged gap, not hidden:** `MeetingTranscriptionService.transcribeAudioFile`
  (the after-Stop fallback for the sequential `.liveYouThenMeetingFile` mode)
  creates its own `AppleSpeechSession.live()` and never receives the
  lexicon (`MeetingTranscriptionService.swift:183-196`, confirmed by
  reading — no `setContext` call anywhere in that function). The stated
  reason (avoiding a `transcribeFile` closure signature change exercised by
  6 call sites in `MeetingTranscriptMergeTests.swift` — verified: grep found
  exactly 6) is a legitimate, disclosed scope cut. The task brief named
  "push-to-talk" and "the meeting path" explicitly; this is a third,
  lower-frequency degraded path (only reached when dual-live session
  allocation fails) that still transcribes, just without biasing. Judged
  **non-blocking** — reasonable to leave as a documented follow-up rather
  than block this PR on it.

## Risk Review — PASS, matches `risk.yml`

- Highest touched path risk is `Sources/` → medium per `.agent-loop/risk.yml`
  path_risk; `Tests/` → low. No path matches a `high` pattern
  (`ClaudeRunner`, `TrustPolicy`, `RecommendationAction`, auth/secret/`.env`,
  `.github/workflows/`) — confirmed by grep against the actual diff, all
  absent.
- No outward action: no network call, no git tag/push/PR, no schema change.
  The only new persisted state is one `UserDefaults` string
  (`voice.lexicon.userTerms`) — not sensitive.
- Both `setContext` call sites use `try?`, so a biasing failure can never
  block starting a recording/capture — verified this is consistent with the
  existing pattern elsewhere in the touched files (recording integrity is
  never gated on an enhancement).
- Task's stated risk (medium) matches the actual diff. No irreversible
  outward action anywhere in this change.
- **Non-blocking scale note (scrutiny item 2):** `VoiceLexiconSource.fetch`
  has no `FetchDescriptor.fetchLimit` anywhere. `Area`/`TaskList` are
  naturally small; `MustardTask` is bounded by the 90-day window but not by
  count within it; `MeetingActionProposal` has **no bound at all** — it has
  no `createdAt`-equivalent field (confirmed via the `@Model` definition),
  so the fetch pulls the entire table every time. This runs synchronously
  on the `@MainActor` inside `MicrophoneFeed.begin()` — the push-to-talk
  hotkey's hot path — on every press. For a single-user local SQLite store
  this is unlikely to matter today, but there's no fetch ceiling or
  profiling evidence backing that assumption, and the table only grows.
  Worth a follow-up if meeting-action-proposal volume ever gets large
  (e.g. add a `fetchLimit` or sort-and-cap before the count check).
- `setContext` failures are swallowed via `try?` with no dedicated log line
  at either call site, but `voiceLog` calls do exist immediately
  surrounding both call sites in their enclosing functions
  (`MeetingCaptureCoordinator.swift` logs `"meeting: start failed"` if
  `transcription.start` throws outward; `VoiceTaskCaptureCoordinator.swift`
  has multiple `voiceLog.notice`/`.error` calls in the surrounding
  `beginCapture`/pump machinery) — a swallowed `setContext` failure
  specifically has no dedicated log line, so it would be silent. Confirmed
  non-blocking polish, matches the repo's existing "degrade enhancements
  gracefully, log at the boundary that matters" pattern; `MeetingTranscriptionService.swift`
  itself has no `Logger` usage anywhere in the file (not a regression —
  it never logged before this change either).

## Test Review — PASS

- **Phase-0 SDK probe claims verified independently against the actual
  swiftinterface**, not trusted from `task.md`:
  ```
  $ grep -n "AnalysisContext|contextualStrings" .../Speech.swiftmodule/arm64e-apple-macos.swiftinterface
  250:  final public var context: Speech::AnalysisContext { ... }
  253:  final public func setContext(_ newContext: Speech::AnalysisContext) async throws
  482:final public class AnalysisContext : Swift::Sendable {
  484:  final public var contextualStrings: ... { get set }
  497:  public static let general: ...
  ```
  Line numbers match `task.md` exactly. No numeric limit documented on
  `contextualStrings` anywhere in the interface — confirmed, matching the
  task's stated rationale for its own independent 100-term cap.
- **Pre-existing plumbing claim verified**: `AppleSpeechSession.swift` and
  `AppleSpeechSessionTests.swift` both show **zero diff** against
  `origin/main` (`git diff --stat` empty for both) — the `setContext`
  protocol requirement, the live driver's `applyContext`/
  `contextualStrings[.general]` path, and the existing
  `test_setContext_normalizesTermsBeforeForwarding` test at line 379 are
  all genuinely pre-existing, not authored by this task, exactly as
  claimed.
- **`MeetingActionProposal.owner` free-text claim verified**: read
  `MeetingDigestService.swift:172-176` directly — `owner` is trimmed
  free text from the digest model's `action.owner`, not a `"me"/"agent"`
  enum as the model's stale doc comment implies. The task correctly used
  actual behavior over the comment and left the stale comment alone
  (accurately out of scope).
  - Probe scratch file (`_BAK334Probe.swift`) confirmed absent from the
  working tree and from all of git history (`find` + `git log --all -- "*Probe*"`
  both empty) — genuinely never committed.
- Ran independently, not just re-read from `verification.md`:
  - `swift test --filter VoiceLexiconTests` → 18/18 pass, exit 0.
  - `swift test --filter MeetingCaptureCoordinatorTests` → 21/21 pass, exit 0.
  - `swift test --filter VoiceTaskCaptureCoordinatorTests` → 16/16 pass, exit 0.
  - Full suite `swift test` → **1577 tests, 1 skipped, 0 failures**, exit 0.
    Matches the claimed baseline exactly (1559 + 18 new = 1577).
  - `swift build` → `Build complete!`, exit 0.
- Test coverage is through public interfaces (`VoiceLexicon.terms`,
  `VoiceLexicon.parseUserTerms`, `VoiceLexiconSource.fetch`), not internals.
  Rank order, case-insensitive dedup (first-wins), title-heuristic positives
  (`DLA` singleton acronym, `CDSB`, repeated `Thales`) and negatives
  (sentence-initial stopword `Fix`, common stopwords, singleton
  non-acronym `Priya`), length bounds, cap enforcement + user-term
  cap-survival, empty inputs, and the fetch-assembly 90-day exclusion are
  all covered — no gaps found in the derivation logic itself.

## Findings summary

No BLOCKING findings.

Non-blocking, for Leon's awareness / optional follow-up:
1. `VoiceLexiconSource.fetch` has no fetch limit on `MeetingActionProposal`
   (unbounded table scan) or on `MustardTask` within its 90-day window;
   runs synchronously on the main actor on every push-to-talk hotkey press.
   Low risk today at single-user scale, but no profiling backs that.
2. The after-Stop file-transcription fallback
   (`MeetingTranscriptionService.transcribeAudioFile`) does not receive the
   lexicon — a disclosed, reasonable scope cut to avoid touching 6 test
   call sites for a closure signature change.
3. `setContext` failures are silently swallowed (`try?`) with no dedicated
   log line, though `voiceLog` calls exist nearby in both call sites'
   enclosing functions.

## Commands run

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter VoiceLexiconTests
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingCaptureCoordinatorTests
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter VoiceTaskCaptureCoordinatorTests
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build
grep -n "AnalysisContext|contextualStrings" "$SDK/.../Speech.swiftmodule/arm64e-apple-macos.swiftinterface"
git diff origin/main..HEAD --stat
git diff origin/main..HEAD -- Sources/MustardKit/Meeting/MeetingTranscriptionService.swift Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift
git diff origin/main..HEAD -- Sources/MustardKit/Capture/VoiceTaskCaptureCoordinator.swift
git diff --stat origin/main..HEAD -- Tests/MustardTests/AppleSpeechSessionTests.swift Sources/MustardKit/Voice/AppleSpeechSession.swift
find Sources -iname "*Probe*"; git log --all --oneline -- "*Probe*"
```

VERDICT: mergeable
