# Fresh-context review — BAK-335 speaker attribution

Branch `agent/bak-335-speaker-attribution`, diff base `origin/main` (8 commits,
17 files, ~1,294 insertions). No prior context; verified independently.

## Standards Review — PASS

- Architecture boundaries respected: pure detection/attribution logic lives in
  `Sources/MustardKit/Logic/MeetingSpeakerAttribution.swift` and
  `MeetingUtteranceMerge.swift`; the one impure fetch helper is isolated in
  `Sources/MustardKit/Meeting/MeetingSpeakerCandidateSource.swift`, matching
  `VoiceLexiconSource`'s existing fetch-helper pattern.
- `MeetingTranscriptView.swift` is render-and-dispatch only — the correction
  `Menu` writes straight to `segment.speaker` (`setSpeaker`, lines 150-153); no
  decision logic in the view. Uses `Theme.Palette`/existing font-size
  convention already present in this file (unchanged style).
- No unrelated refactors. Explicitly-out-of-scope paths (`Dictation/`,
  `ClaudeRunner`, `TrustPolicy`, agent-bridge) are untouched — confirmed via
  `git diff --name-only origin/main...HEAD | grep -iE "Dictation/|ClaudeRunner|TrustPolicy|outbox|bridge"`
  → no matches.
- Digest threading (scrutiny item 3) is correct: `MeetingDigestService.swift`
  lines 120-128 build a throwaway `chunkSegments` list with the same `id` as
  `utterance.asSegment` — evidence ids are untouched (confirmed by
  `test_attributedUtterance_evidenceIDIsUnaffectedByThePrefix`, passing).
  `MeetingUtteranceMerge.swift`'s speaker-boundary break (lines 96-97) extends
  a run only on `sameSource && sameSpeaker && withinPause`; segments are never
  reordered (`for segment in segments.dropFirst()`, `current + [segment]`).
- Persistence (scrutiny item 4): `speaker: String?` is additive on both
  `VoiceTranscriptSegment` (`Voice/VoiceTypes.swift:31,41`, defaulted `= nil`)
  and `MeetingTranscriptSegment` (`Models/MeetingTranscriptSegment.swift:32`,
  optional/nil by default — lightweight SwiftData migration, no versioned
  schema). `git grep` plus the full green suite confirm no call site needed
  to change. `MeetingCaptureCoordinator.attributedSpeakers` (lines 447-464)
  filters strictly to `source == .meeting`; the `result` map only ever gets
  entries for meeting-channel ids, so `persisted.speaker` on `you`-channel
  rows is always `nil` from the map lookup — the you-channel is never
  stamped, confirmed by `test_finalize_stampsSpeakersOnMeetingChannelRows_fromScriptedHandoffs`.

## Spec Review — BLOCKED

The acceptance criteria's non-negotiable rule is **"unattributed is a
first-class state — never guess a name to fill a gap."** Two confirmed
defects violate this rule by producing an actual (not merely lossy-to-nil)
misattribution to a real candidate name.

### BLOCKING — bare "over to" false-positives on ordinary speech, and the multi-token capture lets it misattribute to a real candidate

`Sources/MustardKit/Logic/MeetingSpeakerAttribution.swift:49` includes `over
to` as an unqualified alternative with no requirement that it introduce an
actual handoff. Concretely verified against the real implementation (not
mental trace):

```swift
MeetingSpeakerAttribution.detectHandoffs(texts: ["we went over to the office"])
// → [Handoff(segmentIndex: 0, name: "the office")]   -- false positive on ordinary speech

MeetingSpeakerAttribution.attribute(
    texts: ["let's move over to Sam's slide for revenue", "next update"],
    candidates: ["Sam"])
// → [nil, "Sam"]    -- WRONG: the second segment is misattributed to "Sam",
//                      who never spoke and to whom nothing was handed off.
```

**Failure scenario:** in a real standup, any ordinary sentence containing
"over to" near a real attendee's name — "let's move over to Priya's board",
"switch over to Alex's screen", "come over to Fahad's desk after" — silently
reassigns the following span (and therefore digest action ownership, per
`MeetingDigestService`'s `"<Speaker>: "` prefix) to a real person who did not
say it. This is worse than the "Liam" case the spec is explicitly guarding
against: it doesn't fabricate a name from nothing, it assigns real words to
the wrong real person, which is exactly the kind of confidently-wrong
attribution the non-negotiable rule exists to prevent.

Root cause is two-part, both in this file:
1. `over to` (line 49) has no requirement that what follows look like a
   standalone name — it also captures a second token
   (`extractedName`, lines 128-142) whenever punctuation doesn't intervene.
2. `fuzzyMatches` (lines 116-124) then lets a captured multi-word string
   satisfy `extracted.hasPrefix(firstName)` merely because the FIRST token
   happens to equal a candidate's first name — "sam's slide".hasPrefix("sam")
   is `true` regardless of what "slide" is. The symmetric-prefix rule was
   designed for truncated single-token mishearings ("Fah" → "Fahad"); it was
   not guarded against a genuine two-token capture where only the first
   token is the real name and the second is incidental trailing speech.

Not tested: `test_detectHandoffs_excludesTooFuzzyPhrasing` only excludes the
three named fuzzy idioms ("if you've got a sec" / "you want to
drive/do") — it does not cover "over to" appearing in ordinary non-handoff
sentences, which is the exact case the review brief flagged ("I'll hand over
to the team the docs" / "we went over to the office"). No test exercises the
misattribution path shown above.

### BLOCKING — ambiguous candidate match silently picks the first candidate in list order

`matchedCandidate` (lines 108-110):
```swift
private static func matchedCandidate(for name: String, in candidates: [String]) -> String? {
    candidates.first { fuzzyMatches(name, candidate: $0) }
}
```
Confirmed against the real implementation:
```swift
MeetingSpeakerAttribution.attribute(
    texts: ["over to Ali", "next"], candidates: ["Alina", "Alison"])
// → [nil, "Alina"]   -- picked arbitrarily by list order, not by any
//                        stronger match; "Alison" is an equally valid
//                        3-char-prefix match and was silently discarded.
```
`candidates` comes from `MeetingSpeakerCandidateSource.fetch` — a union of
past `MeetingActionProposal.owner` strings and free-text user terms, in
fetch/append order, not sorted or otherwise meaningfully ordered. Two
candidates sharing a name prefix (a plausible real roster: "Alina"/"Alison",
"Jerome"/"Jerry", "Alex"/"Alexa") is not an edge case unique to contrived
tests. This directly contradicts "never guess" — an ambiguous match has, by
definition, no evidence for which candidate is correct, and the correct
behavior per the spec's own principle is to treat it exactly like the "Liam"
case (unattributed), not to pick one.

Not tested: no test in `MeetingSpeakerAttributionTests.swift` constructs two
candidates that both fuzzy-match the same captured name.

### Everything else in-scope: correctly implemented

- Handoff-segment-stays-with-previous-speaker, back-to-back handoffs (both
  across segments and two-in-one-segment "last wins"), the exact five
  patterns, case-insensitivity, multi-token names bounded by punctuation, and
  the >=3-char prefix floor are all correctly implemented and covered by
  passing tests (`MeetingSpeakerAttributionTests.swift`, 29/29).
- `"over to you, Jerry"` (scrutiny item 1's specific example): confirmed the
  captured name is `"you"`, not `"Jerry"` — `back to you,? X` is patterned
  explicitly to skip "you", but the bare `over to` alternative is not. This
  degrades to an unattributed span (no candidate is plausibly named "you"),
  which is lossy but NOT a misattribution — **non-blocking** per the review
  brief's own framing, though worth a follow-up to extend the "skip you,"
  handling to the bare `over to` pattern for parity with `back to you`.
- Review UI, persistence/migration, and digest-threading axes (scrutiny items
  3-5) all check out — see Standards Review above.

## Risk Review — class matches, but the report's core safety claim is false

`risk-report.md` classifies this **medium** (Sources/-touching feature, no
outward action, additive schema) — the classification itself is reasonable
and consistent with BAK-328..334. However, the report's central risk
argument (lines 56-62) —

> "The core behavioral guarantee is the opposite of risky: it is a
> deliberate REFUSAL to act on uncertain input... an unmatched handoff name
> always degrades to nil rather than fabricating or carrying forward a
> speaker."

— is **not accurate as shipped**: the two Spec-Review findings above are
concrete cases where the code does NOT refuse on uncertain input; it
attributes to a real candidate despite having no real evidence. This doesn't
change the risk *class* (still no outward action, still additive/reversible —
a Leon correction in the UI fixes any bad stamp), but the safety narrative
the risk report leans on to justify medium-not-high is weaker than claimed.
No irreversible outward action; no auth/secret/bridge surface touched —
confirmed by the same grep in the risk report, independently re-run here with
the same (empty) result.

## Test Review — mostly strong, with a coverage gap that tracks the Spec findings

- Filter runs match claimed counts exactly (see Verification below).
- Tests cover observable behavior through the public `detectHandoffs`/
  `attribute` functions, not internals — good.
- Red-first discipline is evident and documented in `verification.md` (stub
  swap-outs, compile-failure reds) — matches the TDD rule in `CLAUDE.md`.
- **Gap:** no test constructs an ordinary (non-handoff) sentence containing
  "over to" near a real candidate name, and no test constructs two
  candidates that both fuzzy-match one captured name. Both are exactly the
  scenarios this review's scrutiny items called out, and both reveal real
  bugs when exercised (see Spec Review). This is a missing-test-seam finding
  that should have caught the two blocking defects before merge.

## Verification — commands run

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingSpeakerAttributionTests
  → Executed 29 tests, 0 failures. Exit 0.
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingSpeakerCandidateSourceTests
  → Executed 5 tests, 0 failures. Exit 0.
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingUtteranceMergeTests
  → Executed 17 tests, 0 failures. Exit 0.
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingDigestServiceTests
  → Executed 15 tests, 0 failures. Exit 0.
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingCaptureCoordinatorTests
  → Executed 23 tests, 0 failures. Exit 0.
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test   (full suite)
  → Executed 1622 tests, 1 test skipped, 0 failures. Exit 0. Matches claimed 1622/1/0.
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build
  → Build complete. Exit 0.
```

Additionally, to verify the Spec-Review findings against the real
implementation (not a mental regex trace), three temporary scratch test cases
were added to a throwaway file, run, and removed before this report was
written (never committed — confirmed clean `git status --short` afterward):
`MeetingSpeakerAttribution.detectHandoffs`/`.attribute` invoked directly with
the "went over to the office" / "move over to Sam's slide" / ambiguous
"Ali" vs. `["Alina","Alison"]` inputs shown inline above; outputs shown are
the actual printed results from that run, not predicted ones.

## VERDICT: blocked

Two blocking Spec-Review findings (bare "over to" + multi-token capture
enabling real misattribution to a genuine candidate; ambiguous-match silent
first-pick) both violate the feature's own non-negotiable acceptance
criterion — "never guess a name to fill a gap" — with concrete, reproduced
failing inputs, not contrived edge cases. Everything else (Standards,
persistence/migration, digest threading, view, and the bulk of the
attribution algorithm) is correctly implemented and well-tested. Recommend:
tighten the bare `over to` alternative (e.g. require it end the utterance /
be followed by exactly one name token with no further trailing content) and
make `matchedCandidate` return `nil` on a multi-candidate tie instead of
`.first`, then re-run the full suite plus new adversarial tests for both
scenarios above.

## Re-review after fixes (commits bc28d05, a757a5e, 97c3bfc)

Scope of the delta, confirmed via `git diff f466fe0..97c3bfc --stat`: exactly
`Sources/MustardKit/Logic/MeetingSpeakerAttribution.swift`,
`Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift`, the two
corresponding test files, and run artifacts (`task.md`/`verification.md`/
`trace.jsonl`, append-only). Nothing outside the two Logic functions + the
coordinator's attribution path + tests + artifacts changed — no scope creep.

### Finding 1 (bare "over to" misattribution) — FIXED, verified

`MeetingSpeakerAttribution.swift` now tags the bare `over to` alternative
with its own capture group (`bareOverToGroup`) and, only for that
alternative, requires `isClauseEnding` — everything after the match to the
end of the text must be whitespace/punctuation only. A captured name ending
in a possessive `'s` is rejected outright (`extractedName`, new guard).
Re-ran the exact repro from the original review, live against the fixed
code, via a throwaway test file (added, run, then deleted — confirmed
`git status --short` clean immediately after):

```
attribute(texts: ["let's move over to Sam's slide for revenue", "next update"],
          candidates: ["Sam"])
// → [nil, nil]   (was [nil, "Sam"] before the fix)
```

### Finding 2 (ambiguous candidate silently picked) — FIXED, verified

`matchedCandidate` now filters to every fuzzy-matching candidate and returns
a name only when exactly one matches; 2+ matches degrade to `nil` instead of
`.first`. Re-ran the exact repro live, same throwaway-file method:

```
attribute(texts: ["over to Ali", "next"], candidates: ["Alina", "Alison"])
// → [nil, nil]   (was [nil, "Alina"] before the fix)
```

### No over-tightening

`"Over to Alin."` still fires and still attributes — confirmed by the
committed tests at `MeetingSpeakerAttributionTests.swift:242-243` (bare
`detectHandoffs`) and `:247-249` (full `attribute`, `candidates: ["Alin"]` →
`[nil, "Alin"]`), both green. A companion committed test
(`MeetingSpeakerAttributionTests.swift:283-297`, "the reviewer's exact
reproduction") locks in both the ambiguous-tie-to-nil behavior AND the
non-ambiguous case (`candidates: ["Alina", "Bob"]` → `[nil, "Alina"]`,
exactly one match) still resolving normally — confirms the fix rejects only
genuine ties, not every multi-candidate list.

### Third fix, beyond what was asked: utterance-level attribution

`MeetingCaptureCoordinator.attributedSpeakers` now merges meeting-channel
segments into utterances (`MeetingUtteranceMerge`, same same-source/pause
rule already used for digest chunking) *before* running handoff detection,
then stamps every constituent segment of an attributed utterance rather than
just the segment `attribute` operated on. This addresses a real gap I hadn't
flagged: real transcriber output is near-word-level (~15 chars/segment), so
a five-plus-word handoff phrase routinely spans 2-3 raw segments and would
never appear intact in any single segment's `text` — attribution over raw
segments would have silently matched nothing on live audio. The fix is
scoped correctly (only the coordinator's assembly of `texts:`/the stamping
loop changed;  `MeetingSpeakerAttribution` itself is untouched by this part)
and is covered by two new/extended coordinator tests exercising the
multi-segment-phrase case, both green.

### Verification re-run

```
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingSpeakerAttributionTests
  → Executed 40 tests, 0 failures. Exit 0.
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test --filter MeetingCaptureCoordinatorTests
  → Executed 24 tests, 0 failures. Exit 0.
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift test   (full suite)
  → Executed 1634 tests, 1 test skipped, 0 failures. Exit 0. Matches claimed 1634/1/0
    (1622 + 12 new tests across the two files).
DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer swift build
  → Build complete. Exit 0.
```

Both original blocking reproductions now yield the required `nil`
attribution against the real (not stubbed) implementation, the anti-
over-tightening check (`"Over to Alin."`) still fires, the delta touched
nothing outside the intended surface, and every requested check is green.

## VERDICT: mergeable
