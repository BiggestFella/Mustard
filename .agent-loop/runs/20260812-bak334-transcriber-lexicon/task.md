# BAK-334: transcriber domain lexicon (contextual-vocabulary biasing)

## Problem (given)

Transcription is strong on prose, terrible on proper nouns — real standup
examples: Thales→"Talus", Sandvik→"Sandvic", Fahad→"the 2 for heart",
"location permission"→"vacation permission". Mustard already holds exactly
the vocabulary that would fix this (areas, task lists, task titles, meeting
action owners) but never hands it to the recognizer.

## Phase 0 — API probe (gates everything else)

### Verdict: the contextual-vocabulary API EXISTS, and Mustard already has
### half the wiring for it — just never called from production code.

**Read first:** `Sources/MustardKit/Voice/AppleSpeechSession.swift` already
contains, pre-existing (not written by this task):

- `SpeechAnalyzerDriving.setContext(_ terms: [String]) async throws` — a
  protocol requirement on the driver seam (line 42).
- `AppleSpeechSession.setContext(_:)` (lines 185-187) — forwards
  `VoiceContextVocabulary.normalized(terms)` to the driver. Already unit
  tested (`Tests/MustardTests/AppleSpeechSessionTests.swift:379`,
  `test_setContext_normalizesTermsBeforeForwarding`).
- `AppleSpeechAnalyzerDriver.setContext(_:)` (lines 351-357) and
  `applyContext(_:to:)` (lines 385-389) — the LIVE implementation:
  ```swift
  private static func applyContext(_ terms: [String], to analyzer: SpeechAnalyzer) async throws {
      let context = AnalysisContext()
      context.contextualStrings[.general] = terms
      try await analyzer.setContext(context)
  }
  ```
- `VoiceContextVocabulary.normalized(_:limit:)` (lines 82-98) — an existing
  64-term dedup/cap already applied at the session-forwarding boundary.

`grep -rn "setContext\|contextualStrings\|VoiceContextVocabulary" Sources/ Tests/`
confirmed **zero production call sites** for `session.setContext(...)` —
only the test above exercises it. So the API is real, live-wired, and
tested at the session level, but no capture coordinator or meeting service
had ever called it. That is precisely the gap this task closes.

### Compiler evidence (fresh, this run)

1. **swiftinterface grep** — the beta SDK's own type signatures, no
   ambiguity about what exists:
   ```
   $ DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer
   $ SDK=$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
   $ grep -n "AnalysisContext|contextualStrings" \
       "$SDK/System/Library/Frameworks/Speech.framework/Versions/A/Modules/Speech.swiftmodule/arm64e-apple-macos.swiftinterface"
   ```
   ```
   250:  final public var context: Speech::AnalysisContext { ... }
   253:  final public func setContext(_ newContext: Speech::AnalysisContext) async throws
   482:final public class AnalysisContext : Swift::Sendable {
   484:  final public var contextualStrings: [Speech::AnalysisContext.Speech::ContextualStringsTag : [Swift::String]] { get set }
   497:  public static let general: Speech::AnalysisContext.Speech::ContextualStringsTag
   ```
   `AnalysisContext` is `@available(anyAppleOS 26, *)`. **No documented
   numeric limit** on `contextualStrings` anywhere in the interface (no doc
   comments ship in `.swiftinterface`, and there is no companion constant).
   No `SFCustomLanguageModelData`-style API exists on `SpeechAnalyzer`/
   `SpeechTranscriber` in this SDK — `contextualStrings` is the only
   per-session vocabulary hook found. (The classic `SFSpeechRecognitionRequest
   .contextualStrings: [String]` is a *different*, older, UIKit-era API tied
   to `SFSpeechRecognizer` — Mustard's ADR already forbids that engine.)

2. **Throwaway compile probe** — a temporary file,
   `Sources/MustardKit/Voice/_BAK334Probe.swift`, exercising exactly the
   surface above against the real SDK, then deleted before any commit:
   ```swift
   @available(macOS 27.0, *)
   func _bak334Probe(_ terms: [String]) async throws {
       let context = AnalysisContext()
       context.contextualStrings[.general] = terms
       let transcriber = SpeechTranscriber(locale: .current, preset: .progressiveTranscription)
       let analyzer = SpeechAnalyzer(modules: [transcriber])
       _ = await analyzer.context
       try await analyzer.setContext(context)
   }
   ```
   `DEVELOPER_DIR=... swift build` → `Build complete! (5.52 sec)` (only the
   pre-existing, unrelated `MustardApp.swift:176` Sendable-closure warning).
   File deleted; a follow-up `swift build` reconfirmed `Build complete!`
   with the identical pre-existing warning and nothing else — the probe
   left no residue.

### Consequence for the design

Because the API and the session-level plumbing both already exist and
compile, this task does **not** need the "ignore at the seam with a TODO"
fallback path — the lexicon is REAL contextual biasing, wired end to end
through `AnalysisContext.contextualStrings[.general]`. The only missing
piece was: nobody ever called `session.setContext(...)` from a capture
path, and nothing ever computed a lexicon to pass it.

## Design decisions

1. **Pure derivation — `Sources/MustardKit/Logic/VoiceLexicon.swift`.**
   `VoiceLexicon.terms(areas:taskLists:taskTitles:proposalOwners:userTerms:cap:)`.
   Rank order (userTerms → areas → taskLists → proposalOwners → title-derived)
   feeds one dedup+bounds pass: case-insensitive dedup (first occurrence's
   casing wins), length bounds (2-40 chars), then truncate to `cap`
   (default 100). Because userTerms is concatenated first, it is always
   copied into the kept list before any other category can fill the cap.
   - `defaultCap = 100`: the SDK does not document a numeric limit on
     `contextualStrings` (see probe above), so 100 is Mustard's own
     deterministic bound, independent of the pre-existing
     `VoiceContextVocabulary.defaultLimit = 64` that still applies at the
     session-forwarding boundary (two independent truncation layers, not a
     contradiction — the second one was already shipped code, untouched).
   - Title heuristic (`titleDerivedTerms`, deterministic): tokenize on
     non-alphanumerics, keeping internal hyphens (`iOS-style` stays one
     token; punctuation like `permission,` never sticks). A token is kept
     if (a) it has an uppercase letter after position 0 (`DLA`, `CDSB`) —
     kept unconditionally, even as a singleton — or (b) its first letter is
     uppercase, it appears ≥2 times across all titles, and it is not in the
     stopword list (`the, a, an, and, for, with, this, that, new, fix,
     fixed, fixes, add, added, adds, update, updated, updates, remove,
     removed, removes, bug, task, feature, support, improve, improved,
     refactor, refactored, review, docs, test, tests, testing, on, in, of,
     to, at, from, by, as, is, are, was, were, be, it, its, our, your, my,
     not, no, yes, all, some, any, one, two, three` — kept in
     `VoiceLexicon.titleStopwords`).
   - `VoiceLexicon.parseUserTerms(_:)`: splits the persisted custom-
     vocabulary string on commas/newlines, trims, drops empties.

2. **User-terms persistence — followed the existing pattern.** Looked at
   `Sources/MustardKit/Logic/BoardSettings.swift` (plain `UserDefaults`
   get/set, no new SwiftData model for a settings value) and the
   `@AppStorage` usages already in `VoiceSetupView.swift`/other views.
   `VoiceLexiconUserTerms` (in `Voice/VoiceLexiconSource.swift`) is a thin
   `UserDefaults` wrapper: key `voice.lexicon.userTerms`, `load(_:)` parses
   the raw string via `VoiceLexicon.parseUserTerms`. `VoiceSetupView` binds
   the raw string directly via `@AppStorage(VoiceLexiconUserTerms.key)` — a
   new "CUSTOM VOCABULARY" section with a caption and a `TextEditor`, Theme
   tokens only (`Theme.Palette.surface`/`.hairline`/`.textPrimary`/
   `.textSecondary`, `Theme.Fonts.body`), no decisions in the view.

3. **Fetch-assembly seam — `Sources/MustardKit/Voice/VoiceLexiconSource.swift`.**
   The ONE place this feature touches `ModelContext`/`FetchDescriptor`
   (matching the `#Predicate` style in `Sources/MustardKit/Calendar/
   CalendarSync.swift`, and the multi-model in-memory `ModelContainer(for:)`
   test pattern from `Tests/MustardTests/AgentBridgeServiceTests.swift` /
   `CalendarSyncTests.swift`). `VoiceLexiconSource.fetch(context:now:
   userTerms:cap:)` gathers: `Area` names, `TaskList` names, `MustardTask`
   titles with `createdAt >= now - 90 days` (a plain `Date` subtraction, not
   a `Calendar` — this is a rolling lookback window, not day-boundary logic,
   so the CLAUDE.md timezone-pinning rule for *day-boundary* date logic
   doesn't apply; `now` is still injected, never the ambient clock), and
   `MeetingActionProposal.owner` strings (confirmed via
   `Sources/MustardKit/Meeting/MeetingDigestService.swift:173-176` and
   `Sources/MustardKit/Models/MeetingActionProposal.swift` that `owner` is
   genuinely free text drawn from the transcript by the on-device digest
   model — e.g. "Fahad" — not the stale doc-comment's claimed `"me"/"agent"`
   enum; this repo's own memory notes that `build-order.md`-style comments
   lag the code, and this is one more instance of that). This directory
   was chosen for the fetch helper — not `Agent/` — because the task's hard
   rule restricts touched directories to `Meeting/`, `Capture/`, `Voice/`,
   `Logic/`, `VoiceSetupView`, and it is shared by both capture paths.

4. **Session wiring — computed once per capture/meeting start.**
   - `VoiceTranscribing` (`Voice/VoiceServices.swift`) gained a
     `setContext(_ terms: [String]) async throws` protocol requirement with
     a **default no-op extension** — every existing conformer (test stubs
     in `MeetingTranscriptMergeTests.swift`, `MeetingCaptureCoordinatorTests
     .swift`) satisfies it for free; only `AppleSpeechSession`'s own
     pre-existing method (unchanged) overrides it with the real forward.
   - `MeetingTranscriptionService.start(sources:lexicon:)` — new `lexicon:
     [String] = []` parameter. Applies it via `try? await
     session.setContext(lexicon)` right after creating EACH session (`you`
     and, when dual-live, `meeting`) and before that session's own
     `start(source:)`. `try?` — a biasing failure must never block a
     meeting from recording (matches the existing "no silent degradation
     of the recording, but graceful degradation of enhancements" pattern
     elsewhere in this file). `MeetingCaptureCoordinator.confirmStart`
     computes the lexicon ONCE (`VoiceLexiconSource.fetch(context:now:
     startedAt, userTerms: VoiceLexiconUserTerms.load())`) and passes it
     into that one `transcription.start(sources:lexicon:)` call — not
     recomputed per buffer.
   - Push-to-talk: `VoiceTaskCaptureCoordinator.Speech.liveMicrophone(
     makeSession:lexicon:)` gained a `lexicon: @MainActor () -> [String] =
     { [] }` closure, threaded into `MicrophoneFeed.init(makeSession:
     lexicon:)`. `MicrophoneFeed.begin()` — which runs once per hotkey
     press/release cycle — calls `lexicon()` fresh and applies it via
     `try? await session.setContext(lexicon())` right after `makeSession()`
     and before `session.start(source:)`. A closure (not a plain array) was
     required here specifically because `VoiceTaskCaptureCoordinator` is a
     long-lived, app-launch-constructed object — a plain array captured at
     construction would go stale as areas/tasks change over the session;
     recomputing at each `begin()` keeps it current. The production
     convenience init wires `lexicon: { VoiceLexiconSource.fetch(context:
     context, now: .now, userTerms: VoiceLexiconUserTerms.load()) }`.

## Files touched

- `Sources/MustardKit/Logic/VoiceLexicon.swift` — new, pure.
- `Sources/MustardKit/Voice/VoiceLexiconSource.swift` — new: SwiftData/
  UserDefaults fetch-assembly (`VoiceLexiconSource.fetch`) +
  `VoiceLexiconUserTerms` (UserDefaults key + `load()`).
- `Sources/MustardKit/Voice/VoiceServices.swift` — `VoiceTranscribing`
  gained `setContext(_:)` + default no-op extension.
- `Sources/MustardKit/Meeting/MeetingTranscriptionService.swift` —
  `start(sources:lexicon:)`; applies lexicon to each session before that
  session starts.
- `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift` —
  `confirmStart` computes the lexicon once and passes it to
  `transcription.start`.
- `Sources/MustardKit/Capture/VoiceTaskCaptureCoordinator.swift` —
  `Speech.liveMicrophone(makeSession:lexicon:)`, `MicrophoneFeed(makeSession:
  lexicon:)`, applied in `begin()`; production convenience init wired to
  `VoiceLexiconSource.fetch`.
- `Sources/MustardKit/Views/VoiceSetupView.swift` — "CUSTOM VOCABULARY"
  section, `@AppStorage(VoiceLexiconUserTerms.key)`.
- `Tests/MustardTests/VoiceLexiconTests.swift` — new, 18 tests.
- `.agent-loop/runs/20260812-bak334-transcriber-lexicon/` — this run's
  artifacts.
- `Sources/MustardKit/Voice/_BAK334Probe.swift` — Phase-0 throwaway,
  written, built successfully, then **deleted** before any commit (not in
  the final tree).

## Acceptance criteria checklist

- [x] Phase-0 probe run FIRST, verdict documented with verbatim
      swiftinterface grep + a fresh compiling probe file (built, then
      deleted).
- [x] `VoiceLexicon.terms` pure, red-first (compile failure before the type
      existed), then green: rank order, case-insensitive dedup (first
      wins), title-heuristic positives (`DLA`, `CDSB`, repeated `Thales`)
      and negatives (sentence-initial stopword `Fix`, other stopwords,
      singleton capitalized word `Priya`), length bounds, cap enforcement,
      user terms surviving the cap, empty inputs.
- [x] User-terms persistence follows the existing `UserDefaults`/
      `@AppStorage` pattern; Voice Setup editor added, Theme tokens only,
      no decisions in the view.
- [x] Fetch-assembly seam (`VoiceLexiconSource.fetch`) tested against an
      in-memory `ModelContainer`: gathers areas/lists/recent titles/owners,
      excludes a >90-day-old task's title, ranks user terms first.
- [x] Both capture paths (push-to-talk, meeting) call
      `session.setContext(...)` with a lexicon computed once at
      capture/meeting start, not per buffer.
- [x] Real contextual biasing wired (not a stub) — the existing, tested
      `AppleSpeechAnalyzerDriver.applyContext` → `AnalysisContext
      .contextualStrings[.general]` path is now actually reachable from
      production capture code.
- [x] `swift test` full suite green, `swift build` exit 0.
- [x] No push, no PR. Probe scratch file deleted before final commit.
- [x] Untouched: `Dictation/`, `ClaudeRunner`, `TrustPolicy`.

## Deviations / uncertainties (flagged for Leon)

1. **The after-Stop fallback file-transcription path does not get the
   lexicon.** `MeetingTranscriptionService.transcribeAudioFile(_:)` (the
   sequential-fallback's second half, run when `mode == .liveYouThenMeetingFile`
   after Stop) creates its own `AppleSpeechSession.live()` and never receives
   the meeting's lexicon — threading it through would require changing the
   injected `transcribeFile: @MainActor (URL) async throws -> [...]` closure's
   signature, which is exercised directly by 6 call sites across
   `MeetingTranscriptMergeTests.swift`, causing exactly the kind of test
   churn the brief said to avoid. The two capture paths the brief explicitly
   named (push-to-talk, "the meeting path") both get real biasing; this one
   post-hoc fallback transcription pass does not. Flagging this as a scoped
   gap rather than doing it silently — happy to wire it in a follow-up if
   wanted.
2. **`MeetingActionProposal.owner`'s doc comment** ("Suggested owner
   ('me'/'agent'), advisory only until approval") reads as if it's an enum,
   but the actual generation path (`MeetingDigestService.swift`) treats it
   as free text from the transcript. Verified by reading the digest
   generation code directly rather than trusting the comment; used the
   actual (free-text-name) behavior since that's what makes it useful
   lexicon input. Did not edit that stale comment — out of this task's
   scope.
3. **`setContext` failures are swallowed (`try?`) at both call sites.**
   Matches the existing pattern of degrading enhancements gracefully
   without blocking the primary capture, but means a persistent biasing
   failure would be silent. Not logged separately from the pre-existing
   `voiceLog` calls already surrounding these call sites; a dedicated log
   line could be added if Leon wants visibility here.
4. **Recognition-accuracy improvement itself is not verified by this run**
   (per the task's own instruction: "No recognition-accuracy tests — the
   recognition improvement is a Leon eye-check"). Everything here is
   verified as: the API is real (compiler evidence), the derivation is
   correct (18 unit tests), and the wiring reaches the session (protocol
   default + explicit call sites, verified by reading, not by a live mic
   test). Whether Thales/Sandvik/Fahad actually transcribe better needs
   Leon's ear on real hardware running macOS 27.
