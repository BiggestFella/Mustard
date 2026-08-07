# Modern Voice-Task Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace legacy voice-task transcription/cleanup with the shared Apple voice core and open a safe notch-adjacent editor after capture.

**Architecture:** Refactor `VoiceCaptureController` into one coordinator that commits raw evidence first, requests typed on-device enrichment, and delegates editing to a focused floating-panel controller. Pure merge rules prevent late model output from overwriting user edits.

**Tech Stack:** MustardVoiceCore, SwiftData, SwiftUI/AppKit `NSPanel`, Foundation Models guided generation, Carbon hotkey, XCTest.

---

### Task 1: Implement safe draft validation and merge

**Files:**
- Create: `Sources/MustardKit/Logic/VoiceTaskDrafting.swift`
- Test: `Tests/MustardTests/VoiceTaskDraftingTests.swift`

- [ ] **Step 1: Write failing tests**

Test title trimming, empty-title rejection, allowed-area validation, URL parsing,
pinned UTC date conversion, and per-field user-revision precedence:

```swift
func testLateModelTitleDoesNotOverwriteUserEdit() {
    let merged = VoiceTaskDrafting.merge(
        generated: .init(title: "Generated"),
        into: .init(title: "My title"),
        revisions: [.title: 2],
        requestRevisions: [.title: 1])
    XCTAssertEqual(merged.title, "My title")
}
```

- [ ] **Step 2: Run and verify failure**

```bash
swift test --filter VoiceTaskDraftingTests
```

- [ ] **Step 3: Implement typed drafts and merge**

Define `VoiceTaskField`, `VoiceTaskDraft`, `VoiceTaskFieldRevisions`, and:

```swift
public static func shouldApply(
    field: VoiceTaskField,
    current: VoiceTaskFieldRevisions,
    atRequest: VoiceTaskFieldRevisions
) -> Bool {
    current[field] == atRequest[field]
}
```

Apply only valid fields whose revisions still match.

- [ ] **Step 4: Run tests and commit**

```bash
swift test --filter VoiceTaskDraftingTests
git add Sources/MustardKit/Logic/VoiceTaskDrafting.swift Tests/MustardTests/VoiceTaskDraftingTests.swift
git commit -m "feat(voice): add safe task draft merging" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 2: Add typed on-device voice-task drafting

**Files:**
- Create: `Sources/MustardKit/Voice/VoiceTaskDraftGenerator.swift`
- Create: `Sources/MustardKit/Voice/Prompts/voice-task-27.txt`
- Test: `Tests/MustardTests/VoiceTaskDraftGeneratorTests.swift`

- [ ] **Step 1: Write failing fixture tests**

Cover a plain task, URL, relative date, unknown area, missing title, model
unavailable, and invalid structured output.

- [ ] **Step 2: Add the guided type and prompt**

```swift
@Generable
public struct GeneratedVoiceTaskDraft {
    public var title: String
    public var notes: String?
    public var areaName: String?
    public var scheduledISO8601: String?
    public var urls: [String]
}
```

The prompt instructs the model to preserve meaning, never invent URLs/people or
completion, and choose an area only from the supplied list.

- [ ] **Step 3: Implement generation and deterministic validation**

Call `OnDeviceGenerating.generate`, parse dates with an injected calendar/time
zone, pass output through `VoiceTaskDrafting`, and return a retryable local
failure without mutating the task.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter VoiceTaskDraftGeneratorTests
git add Sources/MustardKit/Voice/VoiceTaskDraftGenerator.swift Sources/MustardKit/Voice/Prompts Tests/MustardTests/VoiceTaskDraftGeneratorTests.swift
git commit -m "feat(voice): draft tasks with Apple Intelligence" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 3: Refactor the capture coordinator

**Files:**
- Move: `Sources/MustardKit/Capture/VoiceCaptureController.swift` → `Sources/MustardKit/Capture/VoiceTaskCaptureCoordinator.swift`
- Modify: `Sources/MustardKit/Capture/PushToTalkHotKey.swift`
- Modify: `Sources/MustardKit/Logic/VoiceCapture.swift`
- Test: `Tests/MustardTests/VoiceTaskCaptureCoordinatorTests.swift`

- [ ] **Step 1: Write failing coordinator tests**

Use stub speech/hotkey/model/context closures. Assert provisional text never
commits, final text commits exactly once, raw transcript is verbatim, model
failure leaves a usable task, and a second capture closes the previous editor.

- [ ] **Step 2: Expose hotkey registration result**

Change `register()` to return:

```swift
public enum HotKeyRegistration: Equatable {
    case registered
    case conflict(OSStatus)
}
```

Check `RegisterEventHotKey`'s status and never fail silently.

- [ ] **Step 3: Implement the coordinator sequence**

On release: finalize speech, run `VoiceCapture.outcome`, insert/save the raw
task, present the editor, snapshot revisions, request local drafting, and merge
valid unchanged fields on the main actor.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter VoiceTaskCaptureCoordinatorTests
git add Sources/MustardKit/Capture Sources/MustardKit/Logic/VoiceCapture.swift Tests/MustardTests/VoiceTaskCaptureCoordinatorTests.swift
git commit -m "refactor(voice): coordinate modern task capture" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 4: Build the notch-adjacent quick-edit card

**Files:**
- Create: `Sources/MustardKit/Views/VoiceTaskQuickEditView.swift`
- Create: `Sources/MustardKit/Capture/VoiceTaskQuickEditController.swift`
- Modify: `Sources/MustardKit/Views/VoiceCapturePillView.swift`
- Test: `Tests/MustardTests/VoiceTaskQuickEditStateTests.swift`

- [ ] **Step 1: Write failing editor-state tests**

Test field revision increments, multiline Return behavior, `⌘Return`, Escape
keeps the task, outside-click commit, Open Fully dispatch, and one-visible-card
replacement.

- [ ] **Step 2: Implement editor state**

```swift
@MainActor @Observable
public final class VoiceTaskQuickEditState {
    public let task: MustardTask
    public private(set) var revisions = VoiceTaskFieldRevisions()
    public func userChanged(_ field: VoiceTaskField) { revisions.bump(field) }
}
```

- [ ] **Step 3: Implement panel and view**

Use an activating floating `NSPanel` positioned below the chosen notch display.
Render themed fields for title, notes, links, area, and schedule; wire
Save/Close/Open Fully. Reuse `NotchScreenPicker` for display choice and
`NotchNavigation` for drawer handoff.

- [ ] **Step 4: Run and commit**

```bash
swift test --filter VoiceTaskQuickEditStateTests
swift build
git add Sources/MustardKit/Views Sources/MustardKit/Capture/VoiceTaskQuickEditController.swift Tests/MustardTests/VoiceTaskQuickEditStateTests.swift
git commit -m "feat(voice): add notch task quick editor" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 5: Replace legacy cleanup and wire the app

**Files:**
- Modify: `Sources/Mustard/MustardApp.swift`
- Modify: `Sources/MustardKit/Agent/AgentService.swift`
- Delete: `Sources/MustardKit/Capture/SpeechTranscriber.swift`
- Delete: `Sources/MustardKit/Agent/CaptureCleanup.swift`
- Delete: `Sources/MustardKit/Logic/CaptureCleanupQueue.swift`
- Delete: `Tests/MustardTests/CaptureCleanupQueueTests.swift`
- Delete: `Tests/MustardTests/CaptureCleanupServiceTests.swift`
- Delete: `Tests/MustardTests/CaptureCleanupTests.swift`
- Modify: `README.md`
- Modify: `docs/build-order.md`

- [ ] **Step 1: Wire shared services and the new coordinator**

Construct `AppleSpeechSession`, `VoiceTaskDraftGenerator`, and
`VoiceTaskCaptureCoordinator` once in `MustardApp`. Activate after setup
readiness, not through the scheduler cleanup tick.

- [ ] **Step 2: Remove the scheduled agent cleanup**

Delete `cleanupCaptures` calls and obsolete cleanup types/tests. Keep
`captureTranscript` and compatible capture-state fields for store decoding;
mark a successfully generated task `.cleaned`, and leave a raw retryable task
`.raw`.

- [ ] **Step 3: Verify migration and full suite**

```bash
rg -n "SFSpeechRecognizer|cleanupCaptures|CaptureCleanup" Sources Tests
swift test
swift build
./build-app.sh
```

Expected: no live legacy references, tests pass, app builds.

- [ ] **Step 4: Commit**

```bash
git add -A Sources/Mustard Sources/MustardKit Tests/MustardTests README.md docs/build-order.md
git commit -m "feat(voice): ship modern editable voice capture" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 6: Run the macOS 27 acceptance pass

**Files:**
- Create: `docs/validation/2026-07-29-voice-task-capture.md`

- [ ] **Step 1: Record objective smoke results**

Capture OS build, Xcode/SDK, locale, first-partial latency, finalization latency,
permission state, raw transcript, generated fields, and whether manual edits
survived a late model result.

- [ ] **Step 2: Exercise failure paths**

Test model disabled, asset unavailable, hotkey conflict, empty/short hold, URL
editing, two sequential captures, and Open Fully.

- [ ] **Step 3: Final verification and commit**

```bash
swift test
swift build
git diff --check
git add docs/validation/2026-07-29-voice-task-capture.md
git commit -m "test(voice): record macOS 27 capture validation" \
  -m "Co-Authored-By: Codex <noreply@openai.com>"
```
