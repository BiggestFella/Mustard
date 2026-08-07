# On-device rewrite (⌃⌥R) — design

**Date:** 2026-08-05
**Status:** Approved (design); not yet planned or implemented
**Feature id:** F28 (F27 is the console/board attention consolidation)
**Related:** ADR-0011 (voice capture), PR #101 (Voice Suite), F25/F26 (voice capture)

## Summary

Select text in any application, press **⌃⌥R**, and a floating card offers a
rewrite produced entirely by Apple's on-device Foundation Models. Return
replaces the selection; Esc discards; ⌃⌥R again cycles another take. Nothing in
the target application is modified until the user accepts.

This completes the hotkey family: **⌃⌥Space** captures, **⌃⌥D** dictates,
**⌃⌥R** rewrites. Like the rest of the voice suite, the work is local and
offline-safe — no text leaves the machine, and there is no network fallback.

## Motivation, stated honestly

macOS 26 already ships Apple's own Writing Tools (Rewrite / Proofread / Make
Concise) free inside every `NSTextView`. A generic "rewrite this text" feature
would therefore be a worse reimplementation of something the OS already
provides.

The version worth building is one that knows things Writing Tools structurally
cannot: how Leon actually writes, and what Mustard knows about the client, the
area, and the task. That knowledge arrives in phases (below). Phase 1 exists to
prove the delivery mechanism — a system-wide hotkey that can read a selection
out of a foreign application and write a replacement back — because that is the
part Writing Tools does not expose to us and the part carrying all the risk.

## Prerequisite and sequencing (hard constraint)

This feature is built almost entirely on code that **exists only on the PR #101
branch** (`claude/mustard-voice-suite-linear-0xv7rj`) and is **not on `main`**:

- `Voice/OnDeviceLanguageService.swift` — the Foundation Models seam
- `Voice/PromptCatalog.swift` — release-band prompt resources
- `Dictation/AccessibilityFocusReader.swift` — focused-element snapshot
- `Dictation/TextInserter.swift` — verified write-back with ⌘V fallback
- `Dictation/PasteboardSnapshot.swift` — lossless clipboard capture/restore
- `Voice/VoiceAssetReadiness.swift`, `Voice/VoicePermissionStatus.swift` — setup routing

Implementation must therefore branch **from PR #101**, or wait for it to merge.
It cannot be built on a worktree based on `main`.

**Second prerequisite:** dictation (⌃⌥D) should be **verified on hardware
first**, in particular its refusal to write into secure text fields. Rewrite
inherits that exact code path, and a password field is the one place this
feature must never fire. Per the voice-suite record, dictation is code-complete
but has never been exercised on a device.

## Scope

### Phase 1 (this spec)

Hotkey → read selection → four fixed intents → review card → accept writes back.
No personal or project context in the prompt.

Rationale: the risk in this feature is in the plumbing, not the prompting.
Reading a selection out of Gmail and writing it back exercises the same
Accessibility layer that produced eight hardware-only bugs in the voice suite.
Stacking prompt sophistication on an unproven round-trip makes "the rewrite is
wrong" ambiguous between two unrelated causes.

### Phase 2 (named, not specced here)

**Voice profile.** A compact set of style rules distilled once from Leon's own
writing in the vault (uses contractions; does not open with "I hope this finds
you well"; signs off short), injected into every rewrite. A handful of lines, so
it costs almost nothing against the model's small context window, and it is the
capability Writing Tools cannot match.

### Phase 3 (named, not specced here)

**Live Mustard context.** Frontmost application → client area → related task or
note, retrieved at invocation time and folded into the prompt.

### Out of scope (YAGNI)

- Continuous grammar checking / underlining as you type. This is invoke-on-demand only.
- Multiple simultaneous variants (rejected: 3× generation cost per invocation).
- A free-text instruction box (rejected for phase 1: more typing than ⌃⌥R → Return).
- Rewrite with no selection. Refused with a hint — "rewrite the whole field" can
  destroy a long half-written email on a single keystroke.
- Any network model, for any reason, including as a fallback.

## Architecture

### Reused unchanged

| Unit | Provides |
|---|---|
| `OnDeviceGenerating` / `OnDeviceLanguageService` | Availability gate, locale check, guided generation, context-overflow mapping, prewarm |
| `PromptCatalog` | Release-band prompt resource loading ("26" / "26.4" / "27", downward-only fallback) |
| `AccessibilityFocusReader` | Focused-element snapshot: pid, role, subrole, `selectedRange`, value, `isSecure` |
| `TextInserter` | Selection-replacing write-back: verified direct AX write, then lossless ⌘V fallback |
| `PasteboardSnapshot` | Clipboard capture / write / restore-only-if-still-ours |
| `VoiceAssetReadiness`, `VoicePermissionStatus` | Setup and permission routing (Voice Setup screen) |

Replacing a selection is what `TextInserter` already does — dictating into a
selection and rewriting a selection are the same write. No changes required
there for phase 1.

### New — `Sources/MustardKit/Rewrite/`

| Unit | Kind | Responsibility |
|---|---|---|
| `RewriteIntent` | pure | The four intents and their prompt fragments. |
| `RewriteGate` | pure | Two decisions, deliberately split around the read (see interaction step 3a/4): `admits(target:)` runs **before** any read — secure field, role policy, permission — and `accepts(selection:budget:)` runs after — empty, over budget. The testable heart of the feature. |
| `RewriteRoles` | pure | Rewrite's **own** textual-role policy (see boundary note below). |
| `RewriteDraft` | `@Generable` | Typed model output: the rewritten text plus a one-line note on what changed. |
| `RewritePrompt` | pure | Builds instructions + prompt from intent and band. Phase 2 adds the voice profile here and nowhere else. |
| `SelectionReader` | adapter | Reads the selected text via the three-rung ladder. All edges injected closures. |
| `RewriteCoordinator` | `@Observable`, `@MainActor` | Sequences hotkey → snapshot → read → gate → generate → card → accept → write-back. Sibling of `VoiceCaptureController`. |
| `RewriteHotKey` | adapter | Carbon ⌃⌥R, tap semantics, returns `eventNotHandledErr` for foreign chords. |
| `RewriteCardView` | view | The review card, in a non-activating panel. |
| `Rewrite/Prompts/rewrite-<band>.txt` | resource | Band-specific instructions, loaded via `PromptCatalog`. |

**Boundary note — do not widen the shared role set.**
`AccessibilityFocusReader.textualRoles` is shared with dictation, and dictation
is not yet hardware-verified. Rewrite needs a broader policy (Chromium
applications sometimes focus an `AXWebArea` rather than an `AXTextArea`), so
rewrite defines its own `RewriteRoles` and passes it in. Mutating the shared set
would destabilise a feature that has not finished being proven.

### The in-app path (a deliberate, cheap win)

When the frontmost application is Mustard itself, `SelectionReader` and the
write-back use the `NSTextView` selection directly and skip Accessibility
entirely. Same coordinator, a different `SelectionReading` conformance.

This yields a fully working ⌃⌥R inside the notes editor **before any
Accessibility grant exists**, which means prompt quality and card UX can be
verified independently of the fragile layer — and gives a known-good path to
bisect against when a foreign application misbehaves.

## Interaction

1. User selects text in any application and presses ⌃⌥R (**tap**, not hold —
   distinct from ⌃⌥Space's hold-to-capture).
2. Focus is snapshotted **synchronously, first**, as a full
   `FocusedTextTarget` including `selectedRange`, before anything can move it.
3. **`RewriteGate.admits(target:)` runs before anything is read** — secure
   subrole, role policy, permission. This ordering is load-bearing: read rung 3
   synthesizes a ⌘C keystroke into the target, so it must never be reached for a
   password field.
3a. `SelectionReader` reads the selected text (ladder below).
4. `RewriteGate.accepts(selection:budget:)` decides on the text itself — empty,
   or over the context budget.
5. The card appears near the selection in a **non-activating** `NSPanel` that
   overrides `canBecomeKey`. `NSApp.activate` is never called — doing so dragged
   the whole app forward in voice-suite bug #8.
6. Keys: **Return** accepts · **Esc** discards · **1–4** switches intent
   (regenerates) · **⌃⌥R** cycles another take in the open card rather than
   opening a second one.
7. On accept: element identity is revalidated, **the snapshotted range is
   re-asserted** via `kAXSelectedTextRangeAttribute`, then
   `TextInserter.insert(rewritten, into: target)` runs.
8. On any write failure the original is untouched and the card stays open with
   the rewrite visible and copyable.

**Why step 7 re-asserts the range.** Whether a foreign application preserves its
selection while losing key-window status is application-specific and unproven.
Rather than resting the feature on that behaviour, the coordinator restores the
range it captured in step 2 before writing. This makes the question moot and
removes the card's focus behaviour as a correctness risk.

## The read ladder

Dictation only ever needed to *write*. Rewrite must *read* first, and the two are
not symmetric: `AXFocusProbe.value` is, in the existing code's own words, "often
withheld by web areas" — and Gmail and Slack are web areas.

Tried in order, first success wins:

| Rung | Method | Reaches |
|---|---|---|
| 1 | Read `kAXSelectedTextAttribute` | Frequently available even where `AXValue` is withheld. Cheapest, fully passive. Requires adding this attribute to `AXFocusProbe`. |
| 2 | `AXValue` + `selectedRange` substring | Native Cocoa: Notes, Mail, Xcode, TextEdit. |
| 3 | Synthesized ⌘C → read pasteboard → restore | Chromium / Electron: Gmail, Slack, Linear. The only rung that reaches them. |

Rung 3 reuses `PasteboardSnapshot`'s existing capture → write → restore-only-if-
still-ours discipline, and uses the same `postToPid` key synthesis
`TextInserter` already uses for ⌘V.

Each rung reports three-state, matching the honesty of the existing
`verifyInserted`: **text obtained** · **readable but empty** · **unreadable**.
"Unreadable" is not "empty" and must not be treated as one.

Reading via rung 1 or 2 is passive. Rung 3 synthesizes a keystroke into the
target application, which is why `RewriteGate.admits(target:)` must run *before*
the ladder (interaction step 3) rather than after it — a secure field must be
refused before any ⌘C is sent.

## Failure matrix

| Condition | Behaviour |
|---|---|
| Apple Intelligence disabled / device ineligible / model not ready | Explanatory pill routing to the existing Voice Setup screen |
| Accessibility not granted | Voice Setup's existing Open Settings path |
| Secure field (`AXSecureTextField` subrole) | Refused unconditionally, with a message. No read, no ⌘C, no write. |
| No selection | Brief hint pill, no card |
| All three read rungs failed | "Couldn't read the selection in <app>" — **and logs role/subrole** so the cross-app matrix grows from real data |
| Selection exceeds the reported context budget | Refused with the word count. Never silently truncated. |
| Generation error | One retry, then fail with the mapped `LocalModelFailure` reason |
| Focus or identity changed before accept | Refuse the write, keep the card, explain |
| Write failed (`.recoverable`) | Original untouched; rewrite stays on screen and copyable |

## Testing

Per the repo rule, every decision is pure and unit-tested; views are verified by
build plus Leon's eye.

**TDD, pure, no AX / pasteboard / model in tests:**
`RewriteGate` (each refusal reason), `RewriteIntent`, `RewritePrompt`,
`RewriteRoles`, the read-ladder rung-selection decision, and the
`RewriteCoordinator` phase machine driven by stubs. Every edge is an injected
closure, following the `TextInserter` pattern.

**Instrumented from the first commit, not after it goes wrong.** `os_log` under
subsystem `com.cavehole.mustard`, category `rewrite`, at every component
boundary: hotkey phase, snapshot contents (role/subrole/range), which read rung
was attempted and its three-state result, gate decision, generation outcome,
write path taken and its verification result. The voice-suite record is explicit
that three speculative fixes made things worse while a boundary trace found the
cause in one pass.

**Verify by exit code, never by grepping test output.** Chain
build → test → commit so a failure stops the commit.

**Toolchain:** `export DEVELOPER_DIR="/Users/leoncreed-baker/Downloads/Xcode-beta.app/Contents/Developer"`
then `xcrun swift build` / `xcrun swift test`. Never `xcode-select -s`.

**Cross-app matrix (Leon-gated — the agent cannot screenshot the native app).**
For each target record: focused role/subrole, which read rung won, which write
path won, and whether the selection survived the card.

| Target | Why it's in the matrix |
|---|---|
| Mustard notes editor | The non-AX path; proves prompt + card independently |
| Notes.app or Mail | Native Cocoa AX — rungs 1/2 and direct write |
| Gmail in Chrome | Chromium web area — expected rung 3 + paste fallback |
| Slack | Electron — known to report AX writes as successful while discarding them |
| Linear in browser | Second web-area data point |
| Xcode | Native, non-trivial text view |
| Any password field | **Must refuse.** Non-negotiable. |

## Open risks

1. **Rung 3 is a synthesized keystroke.** If the target application does not
   service ⌘C, the read fails and we report it — but the clipboard restore must
   still be correct. Covered by `PasteboardSnapshot`'s changeCount guard, which
   is already tested.
2. **Selection survival across the card** is application-specific. Mitigated by
   re-asserting the range (step 7) rather than depending on it.
3. **Dictation is unverified**, and rewrite inherits its secure-field refusal.
   Hence the prerequisite above.
4. **The model's context window is small.** Long selections are refused rather
   than truncated; the phase-2 voice profile must stay compact for this reason.
5. **`RewriteRoles` may need widening from matrix data.** Expected, and the
   reason the failure path logs role/subrole.

## Decisions taken and their alternatives

| Decision | Rejected alternative | Why |
|---|---|---|
| System-wide hotkey first | Agent drafts, or notes editor first | Leon's call; it is the true Grammarly analogue and completes the hotkey family |
| Card, then accept | Instant in-place replace | An unconfirmed AX write is a proven failure mode; a half-succeeded write in Gmail eats a paragraph |
| Four fixed intents in phase 1 | Voice profile in phase 1 | Keeps the first hardware test single-suspect |
| Own role policy | Widen shared `textualRoles` | Dictation is not yet verified; don't destabilise it |
| Re-assert range before write | Trust the app to keep the selection | Application-specific and unproven |
| Refuse with no selection | Rewrite the whole field | One keystroke could destroy a long draft |
