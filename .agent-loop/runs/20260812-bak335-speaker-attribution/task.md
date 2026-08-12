# BAK-335: speaker attribution (approach A+C)

## Problem (given)

Mustard's meeting channel is one anonymous wall — a 23-minute 8-person
standup is unusable as a record, and the digest can't give actions a real
owner. The recurring meeting (standup) has a rigid verbal handoff protocol
("over to Fahad", "I shall pass it back to Alex", "back to you, Jerry").
Detect handoffs, attribute the span between them, never guess.

**Non-negotiable principle:** unattributed is a first-class state. Where
Notion-style tools invent people (it fabricated a "Liam" on this exact
meeting), Mustard must never guess: a handoff name that doesn't match a
known candidate is recorded as NO attribution for the following span. All
decisions pure + unit-tested.

## Setup

- `git fetch origin main` (HEAD `852a08d`); `git checkout -b
  agent/bak-335-speaker-attribution origin/main`.
- Checked for prior BAK-335 work: `git branch -a | grep -i 335` and
  `git log --all --oneline | grep -i "335\|speaker"` — nothing. No prior
  session owns this.
- Baseline: `DEVELOPER_DIR=$HOME/Downloads/Xcode-beta.app/Contents/Developer
  swift test` → 1577 pass / 1 skip / 0 failures, exit 0. Matches the stated
  baseline exactly (confirmed before any change).

## CalendarEvent-attendees verdict (gates candidate assembly design)

**Read first, as instructed:** `Sources/MustardKit/Models/CalendarEvent.swift`.

```swift
@Model
public final class CalendarEvent {
    public var externalId: String = ""
    public var calendarId: String = "primary"
    public var title: String = ""
    public var start: Date = Date.now
    public var end: Date = Date.now
    public var isAllDay: Bool = false
    public var joinURL: String?
    public var location: String?
    public var updatedAt: Date = Date.now
    ...
}
```

**Verdict: `CalendarEvent` does NOT model attendees.** There is no
participant/invitee list, no attendee array, no attendee-adjacent field of
any kind — only event metadata (id, title, time, join URL, location).
`MeetingRecord.calendarEvent: CalendarEvent?` links a meeting to one of
these, but following that link would still yield nothing to attribute
against.

Per the design brief's own fallback ("if it models attendees, use the
linked event's attendees. Whatever it has, ALSO union..."), since it has
nothing, the candidate list falls through entirely to the two remaining
sources:

1. **`MeetingActionProposal.owner` strings from past meetings** — genuine
   free-text names the digest model has assigned as action owners before
   (confirmed via `VoiceLexiconSource.fetch`, which already does exactly
   this for the transcription lexicon at
   `Sources/MustardKit/Voice/VoiceLexiconSource.swift:38-39`).
2. **`VoiceLexiconUserTerms.load()`** — the user's custom vocabulary
   setting (BAK-334), a flat comma/newline-separated string parsed by
   `VoiceLexicon.parseUserTerms`.

`MeetingSpeakerCandidateSource.fetch(context:userTerms:)` (new,
`Sources/MustardKit/Meeting/MeetingSpeakerCandidateSource.swift`) unions
these two, de-duplicated case-insensitively, following
`VoiceLexiconSource`'s fetch-helper pattern (the one place this feature
touches `ModelContext`/`FetchDescriptor`). No `now:` parameter — neither
source is date-gated (unlike `VoiceLexiconSource`'s 90-day task lookback),
so injecting one would be unused complexity.

**If `CalendarEvent` ever gains attendees**, the doc comment on
`MeetingSpeakerCandidateSource` names it as the one place to wire them in.

## Design decisions made while implementing

### Handoff patterns (exactly the five specified, no more)

`Sources/MustardKit/Logic/MeetingSpeakerAttribution.swift` ships exactly:
`over to X`, `pass it (back )?to X`, `pass (it|that) over to X`,
`back to you,? X`, `hand(ing)? (it )?over to X` — one combined
case-insensitive `NSRegularExpression` alternation. Explicitly excluded (too
fuzzy, would invite false positives): "X, if you've got a sec" / "you want
to (drive|do)". A dedicated test
(`test_detectHandoffs_excludesTooFuzzyPhrasing`) proves these never fire.

Name capture: 1–2 word tokens (`[A-Za-z][A-Za-z'-]*`, so "O'Brien" and
"Jean-Luc" survive), matched regardless of case — the live transcriber may
lowercase everything, so the phrase match and the name capture are
deliberately case-insensitive; judging the name's plausibility is left
entirely to candidate fuzzy-matching, not to capitalization. A second token
capture only fires when directly followed by whitespace + another name
token, so punctuation ("Fahad. Can you...") naturally bounds the name to
one token without special-casing it. Trailing non-letter characters are
stripped defensively as a second guard.

Overlap: "pass it over to X" contains "over to X" as a literal substring.
Because `NSRegularExpression.enumerateMatches` scans left-to-right and only
resumes searching after each match's end, the longer phrase — which starts
earlier in the string — is what matches, and the substring is never
separately (re-)matched. Verified by `test_detectHandoffs_passItOverTo` and
the five distinct-pattern tests all reporting exactly one `Handoff` each.

### Attribution algorithm

`attribute(texts:candidates:)` walks segment indices once, carrying
`currentSpeaker: String?`. For each index: (1) record `currentSpeaker` as
that line's speaker BEFORE applying any handoff that starts on this exact
line — this is what keeps the handoff line itself with the PREVIOUS
speaker (the person saying "over to Fahad" is not Fahad); (2) then apply
every handoff whose `segmentIndex == index`, in order, updating
`currentSpeaker` to the matched candidate's canonical form, or to `nil` if
the name matched no candidate. This naturally handles back-to-back
handoffs (in consecutive segments, or more than one handoff inside a
single segment) without special-case code — verified by
`test_attribute_backToBackHandoffs_inConsecutiveSegments` and
`test_attribute_twoHandoffsInTheSameSegment_lastOneWins`.

### Candidate fuzzy-match rule

`fuzzyMatches(name:candidate:)`: case-insensitive exact match against the
candidate's full string OR its first name (split on the first space), OR a
**symmetric** prefix match against the candidate's first name gated at 3
characters (either string a prefix of the other, both ≥3 chars). Symmetric
because either side of a real mishearing could be the truncated one — a
misheard "Fah" should match candidate "Fahad", and a candidate list
carrying only a partial name should still match a fuller transcript
capture. Below the 3-char floor, nothing matches — a 2-char prefix is too
common to trust (`test_attribute_prefixMatch_belowThreeChars_doesNotMatch`).

## Files touched, and why

- `Sources/MustardKit/Logic/MeetingSpeakerAttribution.swift` (new) — pure
  handoff detection + span attribution. No SwiftData, no Foundation-only
  gate — compiles on both macOS and the iOS companion target.
- `Sources/MustardKit/Meeting/MeetingSpeakerCandidateSource.swift` (new) —
  the one impure fetch helper assembling the candidate list.
- `Sources/MustardKit/Voice/VoiceTypes.swift` — `VoiceTranscriptSegment`
  gains `speaker: String? = nil` (defaulted init param; every existing call
  site across the codebase is unaffected).
- `Sources/MustardKit/Models/MeetingTranscriptSegment.swift` — the
  persisted counterpart, `speaker: String?`, additive/optional (lightweight
  SwiftData migration, no versioned schema needed).
- `Sources/MustardKit/Logic/MeetingUtteranceMerge.swift` — a run now also
  breaks on a speaker change (nil counts as its own speaker, so attributed
  and unattributed segments never merge); `MeetingUtterance.speaker` exposes
  the first constituent's; `asSegment` carries it through.
- `Sources/MustardKit/Meeting/MeetingDigestService.swift` — when building
  the digest's chunk input from utterances, an attributed utterance's
  rendered text is prefixed `"<Speaker>: "` — evidence ids and the
  id/timing/channel portion of `MeetingDigestChunker.renderedLine` are
  untouched; only `text` changes.
- `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift` — at
  finalize, after transcript segments arrive but before persisting them,
  runs attribution over the MEETING-channel segments only (in time order)
  using `MeetingSpeakerCandidateSource`, and writes the result onto each
  persisted row's `speaker`. The you-channel is never auto-stamped (Leon by
  construction — the UI renders "You" straight from the channel).
  `transcriptSegment(from:)` (used by `retryDigest`) now threads the
  persisted `speaker` back into the reconstructed `VoiceTranscriptSegment`.
- `Sources/MustardKit/Views/MeetingTranscriptView.swift` — the per-row
  channel label becomes a speaker label: "You" (never editable) for the
  you-channel, the attributed speaker or "Mtg" (editable via a small Menu
  offering every candidate + "None") for the meeting channel. Render-and-
  dispatch only; writes straight to the persisted segment.
- New/extended test files (see verification.md for the red-first proof on
  each): `Tests/MustardTests/MeetingSpeakerAttributionTests.swift` (new, 29
  tests), `Tests/MustardTests/MeetingSpeakerCandidateSourceTests.swift`
  (new, 5 tests), `Tests/MustardTests/MeetingUtteranceMergeTests.swift`
  (+6 tests), `Tests/MustardTests/MeetingDigestServiceTests.swift` (+3
  tests), `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` (+2
  tests).

**Explicitly NOT touched** (per hard rule): `Sources/MustardKit/Dictation/`,
`ClaudeRunner`, `TrustPolicy`, any agent-bridge code (`AgentTaskCoordinator`,
`BridgeExport`, outbox/results). None of this feature's surface overlaps
with the local-agent execution loop or the connected-worker bridge.

## Deviations / uncertainties

- The spec's design note for point 6 said "pick the cleaner" between
  baking the speaker prefix into `MeetingUtterance.asSegment.text`
  permanently, or doing it at the digest-service assembly point. I chose
  the digest-service assembly point: `asSegment` stays a general-purpose,
  unprefixed view (its existing unit tests assert exact unprefixed text),
  and the prefix is applied only to the throwaway segment list the
  chunker consumes — matching the spec's own test-category wording
  ("attributed utterance text reaches the stub prompt as 'Name: text'")
  which frames this as a digest-service-level behavior.
- The candidate fuzzy-match rule is deliberately symmetric (either string
  may be the truncated one), which is slightly broader than a literal
  reading of "candidate first-name prefix ≥3 chars" (which reads as one
  direction only). I judged the symmetric rule more faithful to the
  underlying intent — a real mishearing can truncate either the transcript
  capture or a candidate string typed into user-terms — and it's fully
  covered by dedicated tests in both directions.
