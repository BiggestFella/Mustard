# BAK-332: audio-source parity — mic audio never written, meeting reported clean

## Incident (given, verified forensics)

Meeting `69DBDDAF-BE74-4887-BE36-6E67FC70A746` (2026-08-05 9am, 23.5 min, recorded
on the pre-PR-#111 build): `status = ready`, `audioFinalized = true`, `captureSources`
archived BOTH `microphone` and `systemAudio`. 413 `you` transcript segments
(1,144 words) were persisted — the mic definitely fed the transcriber. But
`youAudioPath` is empty, no `you.m4a`, no `you.partial.caf` on disk, and
`recovery.json` listed only ONE source (`meeting.partial.caf`). The mic audio
never reached the writer and is gone. A shorter recording earlier the same
morning (`BBF7D032`) wrote `you.m4a` + `you.partial.caf` correctly — intermittent,
not structural. Context: an AVFAudio `installTap` NSException bug existed on
that date (fixed in PR #111 with fresh-engine-per-capture + an ObjC exception
shim).

## Root cause analysis

### Q1 — where does each source's writer start, and can transcription continue without one?

`MeetingCaptureCoordinator.confirmStart` (Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift:110-137)
creates exactly ONE `MeetingAudioWriter` for the whole meeting
(`makeWriter(record.uid, startedAt)`, line 111) — if THAT throws, the meeting
never starts recording at all (covered by the existing
`test_writerCreationFailure_failsAndPersistsTheReason`). But per-SOURCE
writing is not gated at start: `MeetingAudioWriter` opens a per-channel
`AVAudioFile` lazily, on the FIRST `append()` call for that channel
(`MeetingAudioWriter.trackFile(for:format:)`, MeetingAudioWriter.swift:59-77).
There is no separate "start the you writer" / "start the meeting writer"
step to fail loudly at — the first real buffer either opens the file or it
doesn't.

The actual defect is in the routing closure built in `confirmStart`
(MeetingCaptureCoordinator.swift:125-128):

```swift
let capture = MeetingAudioCapture(capturing: capturing) { [weak self] channel, sample in
    try? self?.writer?.append(sample.buffer, to: channel)
    self?.transcriptionFeed?.yield((channel, sample))
}
```

`try?` on the writer append silently discards ANY error —
`unsupportedFormat`, an `AVAudioFile(forWriting:)` failure inside
`trackFile`, anything — with no log line and no state change. Critically,
`transcriptionFeed?.yield(...)` runs UNCONDITIONALLY on the very next line,
regardless of whether the append above succeeded. **Yes — this is the exact
path where transcription continues without a writer.** Every mic sample can
fail to persist, forever, while the identical buffer keeps flowing into the
live transcription session and generating real segments. This matches the
incident precisely: 413 real "you" segments, zero mic bytes on disk.

### Q2 — how does `recovery.json` decide which sources it lists?

`MeetingAudioWriter.checkpoint()` (MeetingAudioWriter.swift:83-100) builds
`sources` by mapping over `trackFiles` — the dictionary a channel only enters
once `trackFile(for:format:)` has *successfully* returned an `AVAudioFile`
(MeetingAudioWriter.swift:62-67, cached on success). A channel whose very
first `AVAudioFile(forWriting:)` call throws is never added to `trackFiles`
and is therefore never checkpointed into `recovery.json` — not once, for the
whole recording. The incident's `recovery.json` listing only
`meeting.partial.caf` is exactly this: the mic's `trackFile` call never
succeeded a single time (consistent with the `installTap` bug leaving stale
engine/format state that made every `AVAudioFile(forWriting:)` attempt for
the mic channel fail), and the swallow above hid every failure.

### Q3 — does finalize check per-source success?

No. `MeetingAudioWriter.finalizeSources()` (MeetingAudioWriter.swift:107-117)
only exports `Array(trackFiles.keys)` — whatever sources happened to open a
file — with zero comparison against how many sources the meeting actually
started with. Back in the coordinator, `stop()`
(MeetingCaptureCoordinator.swift:179-220) calls `writer?.finalizeSources()`;
since it throws only on an export failure (not on "fewer sources than
expected"), it returns cleanly having exported nothing for `.you`. `apply(.audioFinalized)`
fires unconditionally on that success (line 186), `stampAudioPaths` (lines
390-400) sets `youAudioPath = nil` because the file genuinely doesn't exist,
and `record.audioFinalized = true` is set immediately after (line 220) with
**no code anywhere cross-checking `record.captureSources` (what was
promised) against which finalized files actually landed.** That is the
"obvious swallow" the whole incident rides on: two independent points where a
per-source failure had a visible consequence available (the `try?` in the
route closure, and the missing check between `stampAudioPaths` and
`audioFinalized = true`), and both were silent.

### Root-cause hypothesis (given as required, 3 sentences)

The `installTap` NSException bug (pre-PR-#111) left stale AVFoundation engine
state that made every `AVAudioFile(forWriting:)` attempt for the mic channel
throw inside `MeetingAudioWriter.trackFile`; because the route closure in
`MeetingCaptureCoordinator.confirmStart` wraps the writer append in `try?`
while unconditionally forwarding the same buffer to the transcription feed,
the mic kept transcribing successfully while every write silently failed and
never entered `trackFiles`, so it was never checkpointed into
`recovery.json` either. At finalize, `finalizeSources()` only exports
whatever *did* open a file, and the coordinator marks `audioFinalized = true`
and `status = .ready` without ever comparing the sources the meeting started
with against the sources that actually finalized — so the loss had no
consequence anywhere in the pipeline.

## Design decisions

1. **Start-time surfacing (narrowest fix, no re-plumbing).** The route
   closure now logs `voiceLog.error` naming the channel the FIRST time (and
   only the first time, tracked per-channel) a writer append fails, instead
   of swallowing every failure identically and silently. This does not
   change capture/writer lifecycle — it only makes an existing failure mode
   observable. (PR #111 already made the *engine* lifecycle safe; this task
   is surfacing, not re-plumbing, per the brief.)
2. **Finalize parity — the core.** New pure decision unit
   `Logic/MeetingSourceParity.swift`: given the capture sources the meeting
   started with, the set of channels that produced persisted transcript
   segments, and the set of channels with a finalized audio file, it flags a
   channel as missing ONLY when there is positive evidence it was active
   (transcript segments exist for it) yet no audio ever finalized. A source
   that never started, or one that legitimately captured no speech the whole
   meeting (no transcript, e.g. total silence), is never flagged — the
   function only names a channel when the evidence directly contradicts a
   clean finalize, which is exactly the incident's signature and avoids
   false alarms on quiet meetings.
3. **Status choice: keep `status = .ready`, set `errorMessage`, NOT
   `status = .partial`.** Read `MeetingReviewView.statusBadge`
   (Views/MeetingReviewView.swift:128-137): `.partial` renders as
   **"Interrupted"** in warning color — the wrong message for a meeting whose
   full recording, transcript, and digest all succeeded and only lost one
   audio channel. Worse, `digestSection` gates both the "Generate digest" and
   "Retry digest" buttons on `meeting.status == .ready`
   (MeetingReviewView.swift:331, 342) — setting `.partial` here would hide
   digest actions on a meeting whose transcript is completely intact, which
   is actively wrong. `errorMessage` already renders in the header
   unconditionally (MeetingReviewView.swift:190-192, existing pattern used by
   `interrupt()` and export failures) with no such side effect, so the fix
   sets `record.errorMessage` to a message that names the exact missing
   channel(s) (via `MeetingSourceParity.Verdict.userMessage`) and leaves
   `status`/`audioFinalized` on their existing successful values. The
   non-negotiable from the brief — a user-visible message naming the lost
   channel, never silently clean — is satisfied without the collateral
   damage `.partial` would cause.
4. **Manifest honesty.** Per Q2 above, `recovery.json` already lists exactly
   the sources that successfully opened a file — it doesn't fabricate an
   entry for a source that never wrote anything. The incident's root cause
   is that the mic writer never successfully opened at all; guarantee 1
   (start-time surfacing) is what makes that observable now. No change to
   `MeetingRecoveryManifest`/`checkpoint()` semantics.

## Files touched

- `Sources/MustardKit/Logic/MeetingSourceParity.swift` — new, pure.
- `Sources/MustardKit/Meeting/MeetingCaptureCoordinator.swift` — route-closure
  logging (narrowest seam) + finalize-time parity check + `errorMessage`.
- `Tests/MustardTests/MeetingSourceParityTests.swift` — new.
- `Tests/MustardTests/MeetingCaptureCoordinatorTests.swift` — extended:
  writer-append-failure regression.
- `.agent-loop/runs/20260812-bak332-audio-source-parity/` — this run's
  artifacts.

## Acceptance criteria checklist

- [x] Root cause analysis above, with file:line evidence.
- [x] Writer-append failure surfaces a `voiceLog.error` naming the channel
      (once per channel per recording, via `writerFailureLogged`).
- [x] `MeetingSourceParity` pure unit: all-good, missing-you-audio,
      missing-meeting-audio, source-never-started vs started-then-lost,
      empty-transcript (both the clean and the not-flagged variants), plus a
      both-sources-missing determinism case — 8 tests, all green, written
      before the implementation (confirmed red first — see verification.md).
- [x] Coordinator regression: mic writer produces no file (via a
      mismatched-sample-rate buffer tripping `MeetingAudioWriter.append`'s
      existing guard) while transcript persists → NOT silently clean,
      `errorMessage` names the microphone, transcript + meeting audio
      untouched. Confirmed red-first by temporarily reverting the
      coordinator fix — see verification.md.
- [x] `swift test` full suite green (1549 pass / 1 skip / 0 failures, exit
      0), `swift build` exit 0.
- [x] No push, no PR — stopped after local commits.
