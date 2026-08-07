# System-Wide Dictation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Insert finalized on-device speech at the original cursor in compatible Mac applications using `⌃⌥D`.

**Architecture:** A pure coordinator snapshots and revalidates the focused Accessibility target. Injected insertion strategies attempt direct AX replacement first, then a lossless pasteboard fallback; failure exposes recoverable text and never targets a different field.

**Tech Stack:** MustardVoiceCore, ApplicationServices Accessibility APIs, AppKit pasteboard/CGEvent, Carbon global hotkey, SwiftUI/AppKit, XCTest.

---

### Task 1: Model focused targets and contextual whitespace

**Files:**
- Create: `Sources/MustardKit/Logic/FocusedTextTarget.swift`
- Create: `Sources/MustardKit/Logic/DictationWhitespace.swift`
- Test: `Tests/MustardTests/DictationWhitespaceTests.swift`

- [ ] **Step 1: Write failing tests**

Cover selection replacement, letters on both sides, punctuation, newlines,
empty documents, protected targets, and changed target identity.

- [ ] **Step 2: Define pure target identity**

```swift
public struct FocusedTextTarget: Equatable, Sendable {
    public let applicationPID: pid_t
    public let elementIdentifier: String
    public let selectedRange: NSRange?
    public let precedingCharacter: Character?
    public let followingCharacter: Character?
    public let isSecure: Bool
}
```

- [ ] **Step 3: Implement whitespace**

`DictationWhitespace.insertion(text:target:)` returns the exact replacement
string. It adds spaces only between adjacent word characters and never beside
newlines or before closing punctuation.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter DictationWhitespaceTests
git add Sources/MustardKit/Logic/FocusedTextTarget.swift Sources/MustardKit/Logic/DictationWhitespace.swift Tests/MustardTests/DictationWhitespaceTests.swift
git commit -m "feat(dictation): model safe text insertion" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 2: Read and revalidate Accessibility focus

**Files:**
- Create: `Sources/MustardKit/Dictation/AccessibilityFocusReader.swift`
- Test: `Tests/MustardTests/AccessibilityFocusReaderTests.swift`

- [ ] **Step 1: Write failing adapter tests**

Inject an `AXReading` closure and cover native field, web field, missing range,
secure role/subrole, missing permission, dead app, and identity mismatch.

- [ ] **Step 2: Implement the reader**

Read `kAXFocusedUIElementAttribute`, role/subrole, selected text range, value
around the selection, and PID. Build a stable identity from PID plus element
reference/role/window metadata. Expose:

```swift
public protocol FocusedTextReading {
    func snapshot() throws -> FocusedTextTarget
    func isStillFocused(_ target: FocusedTextTarget) -> Bool
}
```

- [ ] **Step 3: Run and commit**

```bash
swift test --filter AccessibilityFocusReaderTests
git add Sources/MustardKit/Dictation/AccessibilityFocusReader.swift Tests/MustardTests/AccessibilityFocusReaderTests.swift
git commit -m "feat(dictation): inspect focused text fields" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 3: Implement direct and pasteboard insertion

**Files:**
- Create: `Sources/MustardKit/Dictation/TextInserter.swift`
- Create: `Sources/MustardKit/Dictation/PasteboardSnapshot.swift`
- Test: `Tests/MustardTests/TextInserterTests.swift`
- Test: `Tests/MustardTests/PasteboardSnapshotTests.swift`

- [ ] **Step 1: Write failing tests**

Cover writable selected-text direct insertion, AX unsupported fallback,
multi-type pasteboard restoration, newer external pasteboard change, paste
failure, focus loss, and secure rejection.

- [ ] **Step 2: Implement direct insertion**

Try setting the selected text attribute/range on the revalidated AX element.
Return typed outcomes:

```swift
public enum TextInsertionOutcome: Equatable {
    case insertedDirectly
    case insertedByPaste
    case recoverable(String)
}
```

- [ ] **Step 3: Implement lossless paste fallback**

Snapshot every `NSPasteboardItem` type/data pair, write the transcript, send
Command-V to the original PID, and restore only if `changeCount` still matches
Mustard's write. Never overwrite a newer external clipboard change.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter TextInserterTests
swift test --filter PasteboardSnapshotTests
git add Sources/MustardKit/Dictation Tests/MustardTests/TextInserterTests.swift Tests/MustardTests/PasteboardSnapshotTests.swift
git commit -m "feat(dictation): insert text with safe fallback" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 4: Coordinate push-to-talk dictation

**Files:**
- Create: `Sources/MustardKit/Dictation/SystemDictationCoordinator.swift`
- Modify: `Sources/MustardKit/Capture/PushToTalkHotKey.swift`
- Test: `Tests/MustardTests/SystemDictationCoordinatorTests.swift`

- [ ] **Step 1: Write failing state-machine tests**

Test snapshot on press, short hold, provisional display, final insertion,
changed focus, secure field, speech error, hotkey conflict, and no SwiftData
mutation.

- [ ] **Step 2: Generalize the hotkey**

Permit distinct IDs and key combinations. Register task capture as ID 1 /
`⌃⌥Space`, and dictation as ID 2 / `⌃⌥D`.

- [ ] **Step 3: Implement coordinator phases**

```swift
public enum SystemDictationPhase: Equatable {
    case idle, listening
    case inserting
    case inserted
    case recoverable(String)
    case denied(String)
}
```

Snapshot target before speech starts, keep the pill nonactivating, finalize on
release, revalidate, normalize whitespace, then insert.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter SystemDictationCoordinatorTests
git add Sources/MustardKit/Dictation/SystemDictationCoordinator.swift Sources/MustardKit/Capture/PushToTalkHotKey.swift Tests/MustardTests/SystemDictationCoordinatorTests.swift
git commit -m "feat(dictation): coordinate global push-to-talk" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 5: Add the dictation pill and app wiring

**Files:**
- Create: `Sources/MustardKit/Views/SystemDictationPillView.swift`
- Modify: `Sources/Mustard/MustardApp.swift`
- Modify: `Sources/MustardKit/Views/VoiceSetupView.swift`
- Modify: `README.md`

- [ ] **Step 1: Build the nonactivating pill**

Render Listening, Inserting, Inserted, denied, and recoverable states with
Theme tokens. Recoverable state provides Copy and Try Current Field buttons;
only those actions may activate Mustard.

- [ ] **Step 2: Wire one coordinator**

Construct it beside voice-task capture, activate only after mic/speech readiness,
and report Accessibility denial independently in Voice Setup.

- [ ] **Step 3: Build and commit**

```bash
swift build
git add Sources/MustardKit/Views/SystemDictationPillView.swift Sources/Mustard/MustardApp.swift Sources/MustardKit/Views/VoiceSetupView.swift README.md
git commit -m "feat(dictation): add global dictation surface" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 6: Run the cross-app matrix

**Files:**
- Create: `docs/validation/2026-07-29-system-dictation.md`

- [ ] **Step 1: Test supported targets**

Record results for native SwiftUI/AppKit, Safari, Chrome, Slack, Gmail, Notes,
and Terminal fields: direct/fallback path, clipboard preserved, insertion text,
and focus behavior.

- [ ] **Step 2: Test protected and failure targets**

Verify password fields, an unsupported canvas/custom editor, focus switching,
Accessibility denial, external clipboard mutation, and speech failure.

- [ ] **Step 3: Verify and commit**

```bash
swift test
swift build
git diff --check
git add docs/validation/2026-07-29-system-dictation.md
git commit -m "test(dictation): record compatibility matrix" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```
