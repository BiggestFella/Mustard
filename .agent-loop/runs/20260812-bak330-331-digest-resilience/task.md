# BAK-330 + BAK-331: digest resilience — partial degradation and failure surfacing

## Issue summary

`MeetingDigestService.digest` (BAK-299, hardened by BAK-328/BAK-329) maps the
transcript into context-budget chunks, generates one digest per chunk, then
reduces. Before this change, a single failed chunk — anywhere in a long
meeting — aborted the ENTIRE digest, discarding every chunk that DID
generate successfully. Separately, `MeetingRecord.digestStatus == .failed`
carried no information about WHY: the coordinator discarded the typed
`MeetingDigestFailure`/`LocalModelFailure` the instant it hit `.failure` in
the `switch`, so `MeetingReviewView` could only ever show one generic line
("The on-device digest failed…") regardless of cause, and offered "Retry
digest" even for permanent-cause failures where retrying can never help
(e.g. `.deviceNotEligible`).

BAK-330 and BAK-331 were built together in one pass since they share the
same seam (`MeetingDigestService.digest`'s Result, `MeetingCaptureCoordinator`'s
digest-landing code, `MeetingReviewView.digestSection`) and the model schema
change (two new optional `MeetingRecord` fields + one new `MeetingDigestStatus`
case) is small enough that splitting them into separate runs would have meant
re-deriving the same context twice.

## Design decisions (given, followed as specified)

### BAK-330 — partial digest instead of all-or-nothing

1. `MeetingDigest` gains `public var omittedSpans: [ClosedRange<Double>] = []`
   — start–end seconds (offset into the meeting) of transcript spans whose
   chunk generation failed. Added via a custom memberwise `init` (the struct
   already needed one so `omittedSpans` could default) in
   `Sources/MustardKit/Logic/MeetingDigestChunker.swift`.
2. `MeetingDigestService.digest`'s map loop no longer returns `.failure` on
   the first failed chunk: it records `chunk.first!.startSeconds...chunk.last!.endSeconds`
   into `omittedSpans` (via `if let` on `chunk.first`/`chunk.last`, which are
   never nil — the chunker never emits an empty chunk) and continues to the
   next chunk. Hard failures are unchanged: `.missingPrompt` and the
   capabilities-probe failure still short-circuit before any chunk is
   attempted.
   - If every chunk that existed failed (`partials.isEmpty` AND
     `!chunks.isEmpty`), the digest still fails — with the LAST chunk's
     failure. Zero usable output is not a partial digest.
   - An empty transcript (zero chunks — `chunks.isEmpty`) is unaffected:
     `partials.isEmpty` there falls through to the pre-existing
     empty-summary success path, not the new failure branch.
   - A reduce-phase failure (the partials merge step, when `partials.count > 1`)
     still fails the whole digest — a **documented known limitation**:
     partial-chunk collection only covers the map phase, not the reduce.
3. `MeetingDigestStatus` gains `.partial` (`Sources/MustardKit/Models/MeetingRecord.swift`).
4. `MeetingRecord.digestOmissionNote: String?` — filled by a new pure
   formatter, `MeetingDigest.omissionNote(spans:) -> String?` (next to the
   digest value types in `MeetingDigestChunker.swift`): mm:ss offsets into
   the meeting (deliberately timezone-free — these are elapsed-seconds
   transcript timestamps, not wall-clock times), e.g.
   `"14:12–19:03 into the meeting could not be summarised."`; multiple spans
   joined with `"; "`; `nil` for an empty span list. Minutes roll past 60
   rather than wrapping into an hour component (e.g. `61:01`, not `1:01:01`).
5. `MeetingCaptureCoordinator.applyDigest` sets
   `digestStatus = omittedSpans.isEmpty ? .ready : .partial` and
   `digestOmissionNote = MeetingDigest.omissionNote(spans: digest.omittedSpans)`.
6. `MeetingReviewView.digestSection`: `.partial` renders the summary exactly
   like `.ready` (same `if let summary = meeting.summaryText` branch), plus
   an omission caption line (`Theme.Fonts.caption` / `Theme.Palette.textSecondary`
   — matches the existing failure-caption styling) when
   `meeting.digestOmissionNote` is set.

### BAK-331 — persist and surface WHY a digest failed

1. `MeetingDigestFailureReason: String, Codable, CaseIterable, Sendable` —
   next to `MeetingDigestFailure` in `MeetingDigestChunker.swift`. A plain
   rawValue enum with **no associated data** — `init(failure:)` deliberately
   drops `LocalModelFailure.unavailable(String)`'s detail string rather than
   persisting it, since that text could carry arbitrary/model-generated
   content.
   - `userMessage: String` — plain-language copy per the ticket's table
     (verbatim strings below).
   - `offersRetry: Bool` — **one deliberate deviation** from a strict
     "known permanent cause → no retry" table: `appleIntelligenceDisabled`
     offers retry, because once Leon flips the System Settings switch,
     retrying is exactly the fix. `modelNotReady` and `unavailable` also
     offer retry (transient causes). `contextOverflow`, `deviceNotEligible`,
     `unsupportedLocale`, `missingPrompt` do not (retrying cannot change
     the outcome).
2. `MeetingRecord.digestFailureReasonRaw: String?` with typed accessor
   `digestFailureReason: MeetingDigestFailureReason?` — same get/set pattern
   as the existing `digestStatus` property, `flatMap`ping an unrecognised
   raw value to `nil` (forward-compat: a future/older-client case never
   crashes the getter).
3. `MeetingCaptureCoordinator`: both digest call sites (the finalize path in
   `stop()` and `retryDigest(for:)`) now route `.failure` through a new
   `applyDigestFailure(_:to:)` helper that maps the typed failure to
   `MeetingDigestFailureReason`, persists it, sets `digestStatus = .failed`,
   and logs `voiceLog.error("meeting: digest failed reason=<rawValue>")` —
   the reason's rawValue only, never the raw model error string or any
   transcript content. `applyDigest` (the success path) clears
   `digestFailureReason = nil` unconditionally, so a stale reason from a
   previous failed attempt never survives a later success.
4. `MeetingReviewView.digestSection`'s `.failed` case shows
   `meeting.digestFailureReason?.userMessage` (falling back to the
   pre-existing generic line for legacy records with no persisted reason —
   `digestFailureReasonRaw` is a new optional field, so anything digested
   before this change decodes with `digestFailureReason == nil`), and hides
   the Retry button when `reason?.offersRetry == false`. `.pending` keeps
   its unconditional "Generate digest" button (there's never a reason to
   gate the FIRST attempt).

### Copy table (verbatim, from the ticket)

| Failure | userMessage | offersRetry |
|---|---|---|
| `contextOverflow` | "This meeting is too long for the on-device model to summarise in one pass." | false |
| `appleIntelligenceDisabled` | "Apple Intelligence is turned off — enable it in System Settings, then retry." | **true** (deviation) |
| `deviceNotEligible` | "This Mac's hardware can't run the on-device model." | false |
| `modelNotReady` | "The on-device model is still downloading. Try again shortly." | true |
| `unsupportedLocale` | "The on-device model doesn't support this language." | false |
| `missingPrompt` | "Mustard's digest prompt is missing from this build." | false |
| `unavailable` | "The on-device model was unavailable. Try again." | true |

## Files touched (all pre-approved, none extra)

- `Sources/MustardKit/Logic/MeetingDigestChunker.swift` — `MeetingDigest.omittedSpans`
  + custom `init`, `omissionNote(spans:)`, `MeetingDigestFailureReason`.
- `Sources/MustardKit/Meeting/MeetingDigestService.swift` — partial-collecting
  map loop, `omittedSpans` threaded into the returned `MeetingDigest`.
- `Sources/MustardKit/Models/MeetingRecord.swift` — `MeetingDigestStatus.partial`,
  `digestOmissionNote`, `digestFailureReasonRaw` + `digestFailureReason` accessor.
- `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift` — `applyDigest`
  sets `.partial`/omission note and clears the failure reason;
  new `applyDigestFailure` persists the mapped reason + logs its rawValue;
  both digest call sites route through it.
- `Sources/MustardKit/Views/MeetingReviewView.swift` — **forced into the same
  commit as the model change**: adding `MeetingDigestStatus.partial` makes
  the pre-existing `switch meeting.digestStatus` in `digestSection`
  non-exhaustive, so the compiler would not build with the model change
  alone. Grepped the whole `Sources/` tree for `MeetingDigestStatus` and
  `digestStatus` switches/usages first — this is the ONLY switch over the
  enum in the codebase, so no other file needed touching for exhaustiveness.
- `Tests/MustardTests/MeetingDigestFailureReasonTests.swift` — new file (one
  file per unit, per repo convention): every `MeetingDigestFailure` → reason
  mapping, `userMessage`/`offersRetry` per case, `omissionNote` formatting
  (single span, multiple spans, empty → nil, mm:ss rollover past one hour).
- `Tests/MustardTests/MeetingDigestServiceTests.swift` — extended: partial
  degradation (middle chunk fails, last chunk fails, all chunks fail, reduce
  failure), plus a `failures: [Int: LocalModelFailure]` extension to the
  existing `StubGenerating` test double so specific `generate()` calls can
  throw.
- `Tests/MustardTests/MeetingRecordModelTests.swift` — extended: defaults for
  the two new fields, `digestStatus` round-trip through `.partial`,
  `digestFailureReason` round-trip + unknown-raw-value → nil.
- `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` — extended:
  failure-reason persistence on finalize AND retry, a differently-failing
  retry updates the persisted reason, a successful retry clears a stale
  reason, an omitted-spans digest persists `.partial` + the formatted note,
  a clean digest persists `.ready` with no note.
- `.agent-loop/runs/20260812-bak330-331-digest-resilience/` — this run's
  artifacts.

## Acceptance criteria checklist

- [x] `MeetingDigest.omittedSpans` added; existing construction sites
      (service, `MeetingCaptureCoordinatorTests.digestResult`) unaffected —
      it defaults to `[]`.
- [x] Map loop degrades instead of aborting; zero survivors still fails
      (last chunk's failure); empty-transcript success path untouched;
      reduce failure still fails (documented limitation).
- [x] `MeetingDigestStatus.partial` added; the one switch over it in
      `Sources/` (`MeetingReviewView.digestSection`) updated to be exhaustive
      and render `.partial` sensibly (like `.ready`, plus the caption).
- [x] `MeetingDigest.omissionNote(spans:)` — mm:ss, multi-span join,
      nil-for-empty, hour rollover — all unit-tested.
- [x] `MeetingDigestFailureReason` — every `MeetingDigestFailure` case
      covered, `userMessage`/`offersRetry` match the copy table, the
      `appleIntelligenceDisabled` deviation is explicit in code comments and
      tests.
- [x] `MeetingRecord.digestFailureReasonRaw` + typed accessor, same
      get/set pattern as `digestStatus`, unknown raw value → nil.
- [x] Coordinator persists the mapped reason on every digest-failure path
      (finalize + retry), logs only the rawValue, clears the reason on
      success.
- [x] View: `.failed` shows the mapped message (generic fallback for legacy
      records), Retry gated on `offersRetry`; `.pending` keeps its
      unconditional Generate button; `.partial` shows the summary + note.
- [x] Failing tests written FIRST for every unit (chunker/reason mapping,
      service partial collection, model fields, coordinator persistence) —
      confirmed red, then green; see `verification.md`.
- [x] `swift test` (beta toolchain) — full suite green.
- [x] `swift build` (beta toolchain) — exit 0.
- [x] No files touched outside the permitted set (`MeetingReviewView.swift`
      was already on the permitted list; no additional file was forced).
- [x] No push, no PR — stopped after local commits for orchestrator review.
