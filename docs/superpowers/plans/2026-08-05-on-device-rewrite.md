# On-device rewrite (⌃⌥R) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Select text in any macOS application, press ⌃⌥R, review an Apple
Foundation Models rewrite in a floating card, and accept it to replace the
selection — entirely on device.

**Architecture:** A pure decision core (`RewriteIntent`, `RewriteRoles`,
`RewriteGate`, `RewriteBudget`, `SelectionLadder`, `RewritePrompt`) with every
OS edge behind an injected closure or protocol, orchestrated by an `@Observable`
`RewriteCoordinator`. Generation reuses PR #101's `OnDeviceGenerating` seam;
write-back reuses its `TextInserter`. The one genuinely new adapter is
`SelectionReader`, which reads the selected text through a three-rung ladder
because web areas withhold `AXValue`.

**Tech Stack:** Swift 6.2 tools / Swift 5 language mode, SwiftUI, XCTest,
FoundationModels, ApplicationServices (AX), Carbon (`RegisterEventHotKey`),
AppKit (`NSPanel`), `os.Logger`.

**Spec:** `docs/superpowers/specs/2026-08-05-on-device-rewrite-design.md`

---

## Before you write any code

- [ ] **Branch from PR #101, not from `main`.**

Every dependency of this feature (`OnDeviceGenerating`, `PromptCatalog`,
`FocusedTextTarget`, `AccessibilityFocusReader`, `TextInserter`,
`PasteboardSnapshot`) exists **only** on `claude/mustard-voice-suite-linear-0xv7rj`.
Building on `main` will fail at the first import.

```bash
git fetch origin
git checkout claude/mustard-voice-suite-linear-0xv7rj
git checkout -b feat/rewrite-hotkey
```

- [ ] **Export the toolchain in every shell.** macOS-27 SDK APIs
  (`LanguageModelError`) need the beta. Never run `xcode-select -s`.

```bash
export DEVELOPER_DIR="/Users/leoncreed-baker/Downloads/Xcode-beta.app/Contents/Developer"
```

- [ ] **Verify by exit code, never by grepping test output.** Two broken pushes
  in the voice suite came from `swift test | grep "Executed"` reporting success
  over a failing run. Use this shape for every verification step:

```bash
if xcrun swift test --filter RewriteGateTests > /tmp/t.log 2>&1; then echo PASS; else tail -40 /tmp/t.log; exit 1; fi
```

- [ ] **Confirm dictation (⌃⌥D) has been verified on hardware first**, above all
  its refusal to write into a secure field. Rewrite inherits that code. If it
  has not been verified, stop and raise it — do not proceed on the assumption.

---

## File structure

| File | Responsibility |
|---|---|
| `Sources/MustardKit/Rewrite/RewriteIntent.swift` | The four intents; title, digit shortcut, instruction fragment. |
| `Sources/MustardKit/Rewrite/RewriteRoles.swift` | Rewrite's own AX role policy (does not touch dictation's). |
| `Sources/MustardKit/Rewrite/RewriteRefusal.swift` | Every typed reason a rewrite does not happen, with user-facing copy. |
| `Sources/MustardKit/Rewrite/RewriteBudget.swift` | Context budget → maximum selection length. |
| `Sources/MustardKit/Rewrite/RewriteGate.swift` | `admits(target:)` before any read; `accepts(selection:)` after. |
| `Sources/MustardKit/Rewrite/SelectionRead.swift` | Three-state read result, rungs, and the pure ladder resolution. |
| `Sources/MustardKit/Rewrite/RewriteDraft.swift` | `@Generable` model output. |
| `Sources/MustardKit/Rewrite/RewritePrompt.swift` | Instructions + prompt assembly from intent and band. |
| `Sources/MustardKit/Rewrite/Prompts/rewrite-26.txt`, `rewrite-27.txt` | Band-specific instruction resources. |
| `Sources/MustardKit/Rewrite/RewritePhase.swift` | Coordinator state machine states. |
| `Sources/MustardKit/Rewrite/RewriteCoordinator.swift` | Sequences the whole flow. |
| `Sources/MustardKit/Rewrite/AccessibilitySelectionReader.swift` | Live three-rung reader (macOS only). |
| `Sources/MustardKit/Rewrite/SelectionRestorer.swift` | Re-asserts the snapshotted range before write-back. |
| `Sources/MustardKit/Rewrite/RewriteHotKey.swift` | Carbon ⌃⌥R, tap semantics. |
| `Sources/MustardKit/Rewrite/RewriteLog.swift` | `os.Logger` boundary instrumentation. |
| `Sources/MustardKit/Views/RewriteCardView.swift` | The review card. |
| `Sources/MustardKit/Views/RewriteCardPanel.swift` | Non-activating `NSPanel` host. |
| `Tests/MustardTests/Rewrite*Tests.swift` | One test file per pure unit. |

---

### Task 1: `RewriteIntent`

**Files:**
- Create: `Sources/MustardKit/Rewrite/RewriteIntent.swift`
- Test: `Tests/MustardTests/RewriteIntentTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

/// The four phase-1 rewrite intents. Digits are the card's keyboard
/// shortcuts, so they are pinned: a reordered enum must not silently
/// remap ⌘-less 1–4 to different intents.
final class RewriteIntentTests: XCTestCase {

    func test_allCases_areTheFourPhaseOneIntents() {
        XCTAssertEqual(RewriteIntent.allCases,
                       [.proofread, .tighten, .warmer, .direct])
    }

    func test_shortcutDigits_arePinnedOneThroughFour() {
        XCTAssertEqual(RewriteIntent.proofread.shortcutDigit, 1)
        XCTAssertEqual(RewriteIntent.tighten.shortcutDigit, 2)
        XCTAssertEqual(RewriteIntent.warmer.shortcutDigit, 3)
        XCTAssertEqual(RewriteIntent.direct.shortcutDigit, 4)
    }

    func test_intentForDigit_roundTrips_andRejectsOutOfRange() {
        for intent in RewriteIntent.allCases {
            XCTAssertEqual(RewriteIntent(shortcutDigit: intent.shortcutDigit), intent)
        }
        XCTAssertNil(RewriteIntent(shortcutDigit: 0))
        XCTAssertNil(RewriteIntent(shortcutDigit: 5))
    }

    func test_default_isTighten() {
        XCTAssertEqual(RewriteIntent.default, .tighten,
                       "Tighten is the most common ask and the safest default.")
    }

    func test_everyIntent_hasATitleAndANonEmptyInstructionFragment() {
        for intent in RewriteIntent.allCases {
            XCTAssertFalse(intent.title.isEmpty)
            XCTAssertFalse(intent.instructionFragment.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `if xcrun swift test --filter RewriteIntentTests > /tmp/t.log 2>&1; then echo PASS; else tail -20 /tmp/t.log; fi`
Expected: FAIL — `cannot find 'RewriteIntent' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// What the user is asking the rewrite to do. Phase 1 ships four fixed
/// intents; the voice profile (phase 2) and Mustard context (phase 3) are
/// added in `RewritePrompt`, not here, so this stays a closed vocabulary.
public enum RewriteIntent: String, CaseIterable, Equatable, Sendable {
    case proofread
    case tighten
    case warmer
    case direct

    /// Tighten is the most common ask, and the least likely to change
    /// meaning if the user accepts without reading closely.
    public static let `default`: RewriteIntent = .tighten

    /// The card's 1–4 shortcut. Pinned, not derived from `allCases.firstIndex`,
    /// so reordering the enum cannot silently remap the keyboard.
    public var shortcutDigit: Int {
        switch self {
        case .proofread: return 1
        case .tighten: return 2
        case .warmer: return 3
        case .direct: return 4
        }
    }

    public init?(shortcutDigit: Int) {
        guard let match = RewriteIntent.allCases
            .first(where: { $0.shortcutDigit == shortcutDigit }) else { return nil }
        self = match
    }

    /// Sentence-case label for the card's chips.
    public var title: String {
        switch self {
        case .proofread: return "Proofread"
        case .tighten: return "Tighten"
        case .warmer: return "Warmer"
        case .direct: return "Direct"
        }
    }

    /// The intent-specific line appended to the band instructions.
    public var instructionFragment: String {
        switch self {
        case .proofread:
            return "Fix spelling, grammar and punctuation only. Do not change wording, tone or length."
        case .tighten:
            return "Cut redundancy and hedging. Keep every fact and commitment. Aim for noticeably shorter."
        case .warmer:
            return "Make the tone warmer and more human. Do not add flattery, exclamation marks or new claims."
        case .direct:
            return "Make it direct and unhedged. State the ask plainly. Do not become blunt or rude."
        }
    }
}
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `if xcrun swift test --filter RewriteIntentTests > /tmp/t.log 2>&1; then echo PASS; else tail -40 /tmp/t.log; exit 1; fi`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Rewrite/RewriteIntent.swift Tests/MustardTests/RewriteIntentTests.swift
git commit -m "feat(rewrite): the four phase-1 rewrite intents"
```

---

### Task 2: `RewriteRoles`

**Files:**
- Create: `Sources/MustardKit/Rewrite/RewriteRoles.swift`
- Test: `Tests/MustardTests/RewriteRolesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

/// Rewrite's own AX role policy. It is deliberately SEPARATE from
/// `AccessibilityFocusReader.textualRoles`, which dictation shares and which
/// is not yet hardware-verified — widening that set to catch Chromium web
/// areas would destabilise a feature still being proven.
final class RewriteRolesTests: XCTestCase {

    func test_admits_theNativeTextualRoles() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(RewriteRoles.admits(role: role), "\(role) should be rewritable")
        }
    }

    func test_admits_webArea_whichDictationDoesNot() {
        XCTAssertTrue(RewriteRoles.admits(role: "AXWebArea"),
                      "Chromium apps focus a web area; rewrite must reach Gmail and Slack.")
        XCTAssertFalse(AccessibilityFocusReader.textualRoles.contains("AXWebArea"),
                       "Dictation's shared set must stay untouched by this change.")
    }

    func test_refuses_nonTextualRolesAndNil() {
        XCTAssertFalse(RewriteRoles.admits(role: "AXButton"))
        XCTAssertFalse(RewriteRoles.admits(role: "AXImage"))
        XCTAssertFalse(RewriteRoles.admits(role: nil))
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `if xcrun swift test --filter RewriteRolesTests > /tmp/t.log 2>&1; then echo PASS; else tail -20 /tmp/t.log; fi`
Expected: FAIL — `cannot find 'RewriteRoles' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Which focused-element roles rewrite will act on. Broader than dictation's
/// `AccessibilityFocusReader.textualRoles` because Chromium/Electron apps
/// (Gmail, Slack, Linear) often report the focused element as an `AXWebArea`
/// rather than an `AXTextArea` — and those are exactly the targets rewrite
/// exists for. Kept as a separate policy so widening it can never regress
/// dictation. Expect this set to grow from real cross-app matrix data.
public enum RewriteRoles {
    public static let textual: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea",
    ]

    public static func admits(role: String?) -> Bool {
        guard let role else { return false }
        return textual.contains(role)
    }
}
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `if xcrun swift test --filter RewriteRolesTests > /tmp/t.log 2>&1; then echo PASS; else tail -40 /tmp/t.log; exit 1; fi`
Expected: PASS. If `AccessibilityFocusReader.textualRoles` is not visible,
it is `static let` with default internal access in the same module — `@testable
import MustardKit` already covers it. Do not change its access level.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Rewrite/RewriteRoles.swift Tests/MustardTests/RewriteRolesTests.swift
git commit -m "feat(rewrite): own role policy, leaving dictation's untouched"
```

---

### Task 3: `RewriteRefusal` and `RewriteBudget`

**Files:**
- Create: `Sources/MustardKit/Rewrite/RewriteRefusal.swift`
- Create: `Sources/MustardKit/Rewrite/RewriteBudget.swift`
- Test: `Tests/MustardTests/RewriteBudgetTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

/// Selection-length budget. The on-device model's context is small, and the
/// spec refuses oversized selections rather than silently truncating them —
/// truncation would return a rewrite of half the user's paragraph and look
/// like success.
final class RewriteBudgetTests: XCTestCase {

    func test_maxWords_reservesRoomForInstructionsAndOutput() {
        // A rewrite must fit: instructions + selection + a rewrite roughly the
        // size of the selection. So the selection gets well under half the window.
        XCTAssertEqual(RewriteBudget.maxWords(contextSize: 4096), 1024)
        XCTAssertEqual(RewriteBudget.maxWords(contextSize: 8192), 2048)
    }

    func test_maxWords_neverReturnsLessThanAUsableFloor() {
        XCTAssertEqual(RewriteBudget.maxWords(contextSize: 0), RewriteBudget.floorWords)
        XCTAssertEqual(RewriteBudget.maxWords(contextSize: 100), RewriteBudget.floorWords,
                       "A nonsense context reading must not make the feature refuse everything.")
    }

    func test_wordCount_countsWhitespaceSeparatedRuns() {
        XCTAssertEqual(RewriteBudget.wordCount("Can you send the SOW?"), 5)
        XCTAssertEqual(RewriteBudget.wordCount("  spaced   out \n lines "), 3)
        XCTAssertEqual(RewriteBudget.wordCount(""), 0)
        XCTAssertEqual(RewriteBudget.wordCount("   "), 0)
    }

    func test_refusalCopy_isUserFacingAndNeverEmpty() {
        let refusals: [RewriteRefusal] = [
            .accessibilityPermissionMissing,
            .secureField,
            .unsupportedRole("AXButton"),
            .noSelection,
            .unreadableSelection(application: "Slack"),
            .overBudget(words: 3000, limit: 1024),
            .focusChanged,
            .model(.appleIntelligenceDisabled),
            .writeFailed("the app didn't accept the paste"),
        ]
        for refusal in refusals {
            XCTAssertFalse(refusal.message.isEmpty, "\(refusal) needs user-facing copy")
        }
    }

    func test_overBudgetCopy_namesBothNumbers() {
        let message = RewriteRefusal.overBudget(words: 3000, limit: 1024).message
        XCTAssertTrue(message.contains("3000"), "The user should see how long the selection is")
        XCTAssertTrue(message.contains("1024"), "…and what the limit is")
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `if xcrun swift test --filter RewriteBudgetTests > /tmp/t.log 2>&1; then echo PASS; else tail -20 /tmp/t.log; fi`
Expected: FAIL — `cannot find 'RewriteBudget' in scope`.

- [ ] **Step 3: Implement `RewriteRefusal.swift`**

```swift
import Foundation

/// Every reason a rewrite does not happen. Typed, exhaustive, and each case
/// carries its own user-facing copy — nothing about a refusal is silent, and
/// the card always has something specific to say.
public enum RewriteRefusal: Error, Equatable, Sendable {
    /// Accessibility is not granted; Voice Setup routes to System Settings.
    case accessibilityPermissionMissing
    /// A password-shaped field. Refused unconditionally, before any read.
    case secureField
    /// The focused element is not something we rewrite. Carries the role so
    /// the cross-app matrix grows from real data.
    case unsupportedRole(String)
    /// Nothing is selected. A hint, not an error.
    case noSelection
    /// All three read rungs failed. Carries the application name for the copy.
    case unreadableSelection(application: String)
    /// The selection is longer than the context window allows.
    case overBudget(words: Int, limit: Int)
    /// Focus or element identity moved between the snapshot and the accept.
    case focusChanged
    /// The on-device model could not run. Wraps PR #101's failure vocabulary.
    case model(LocalModelFailure)
    /// The write-back did not land. The original is untouched.
    case writeFailed(String)

    /// Sentence-case, no exclamation marks, says what happened and what to do.
    public var message: String {
        switch self {
        case .accessibilityPermissionMissing:
            return "Rewrite needs Accessibility access. Open Voice Setup to grant it."
        case .secureField:
            return "This looks like a password field — rewrite never touches those."
        case .unsupportedRole(let role):
            return "That isn't an editable text field (\(role))."
        case .noSelection:
            return "Select the text you want rewritten, then press ⌃⌥R."
        case .unreadableSelection(let application):
            return "Couldn't read the selection in \(application)."
        case .overBudget(let words, let limit):
            return "That selection is \(words) words; rewrite handles up to \(limit). Select less."
        case .focusChanged:
            return "The text moved before the rewrite was applied. Nothing was changed."
        case .model(let failure):
            return failure.rewriteMessage
        case .writeFailed(let reason):
            return "Couldn't write the rewrite back — \(reason). Your original is unchanged."
        }
    }
}

extension LocalModelFailure {
    /// Rewrite-flavoured copy for the shared on-device failure vocabulary.
    var rewriteMessage: String {
        switch self {
        case .appleIntelligenceDisabled:
            return "Apple Intelligence is switched off. Turn it on in System Settings."
        case .deviceNotEligible:
            return "This Mac can't run the on-device model."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again shortly."
        case .unsupportedLocale:
            return "The on-device model doesn't support this language yet."
        case .contextOverflow:
            return "That selection is too long for the on-device model. Select less."
        case .unavailable(let reason):
            return "Rewrite is unavailable — \(reason)."
        }
    }
}
```

- [ ] **Step 4: Implement `RewriteBudget.swift`**

```swift
import Foundation

/// Selection-length budget. `contextSize` is reported in tokens by
/// `SystemLanguageModel`; a rewrite has to fit instructions, the selection,
/// AND a rewrite of roughly the selection's size in the same window. A
/// quarter of the window in words is a deliberately conservative allowance
/// (English averages under a token per word, so a quarter in words is well
/// under half the window in tokens).
public enum RewriteBudget {
    /// Never refuse everything because the model reported a nonsense context.
    public static let floorWords = 400

    public static func maxWords(contextSize: Int) -> Int {
        max(floorWords, contextSize / 4)
    }

    /// Whitespace-separated runs. Deliberately crude: it only has to be a
    /// stable, explainable number to show the user in a refusal.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
```

- [ ] **Step 5: Run it and confirm it passes**

Run: `if xcrun swift test --filter RewriteBudgetTests > /tmp/t.log 2>&1; then echo PASS; else tail -40 /tmp/t.log; exit 1; fi`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MustardKit/Rewrite/RewriteRefusal.swift Sources/MustardKit/Rewrite/RewriteBudget.swift Tests/MustardTests/RewriteBudgetTests.swift
git commit -m "feat(rewrite): typed refusals with user-facing copy, plus the selection budget"
```

---

### Task 4: `SelectionRead` and the read ladder

**Files:**
- Create: `Sources/MustardKit/Rewrite/SelectionRead.swift`
- Test: `Tests/MustardTests/SelectionLadderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

/// The three-rung read ladder. The distinction that matters throughout:
/// "unreadable" is NOT "empty". Web areas withhold their value, and treating
/// a withheld value as an empty selection would rewrite nothing and call it
/// success.
final class SelectionLadderTests: XCTestCase {

    func test_rungOrder_isCheapestAndMostPassiveFirst() {
        XCTAssertEqual(SelectionRung.ordered,
                       [.axSelectedText, .axValueSubstring, .copyKeystroke],
                       "⌘C synthesis is last: it is the only rung that touches the target.")
    }

    func test_resolve_stopsAtTheFirstRungThatReturnsText() {
        let resolved = SelectionLadder.resolve([
            (.axSelectedText, .unreadable),
            (.axValueSubstring, .text("Can you send the SOW?")),
        ])
        XCTAssertEqual(resolved.read, .text("Can you send the SOW?"))
        XCTAssertEqual(resolved.rung, .axValueSubstring,
                       "The winning rung is recorded for the cross-app matrix.")
    }

    func test_resolve_treatsEmptyAsAuthoritative_andStops() {
        // A readable, genuinely empty selection is a real answer — do not
        // escalate to ⌘C and start synthesizing keystrokes over nothing.
        let resolved = SelectionLadder.resolve([
            (.axSelectedText, .empty),
            (.axValueSubstring, .text("should never be reached")),
        ])
        XCTAssertEqual(resolved.read, .empty)
        XCTAssertEqual(resolved.rung, .axSelectedText)
    }

    func test_resolve_isUnreadableOnlyWhenEveryRungWasUnreadable() {
        let resolved = SelectionLadder.resolve([
            (.axSelectedText, .unreadable),
            (.axValueSubstring, .unreadable),
            (.copyKeystroke, .unreadable),
        ])
        XCTAssertEqual(resolved.read, .unreadable)
        XCTAssertEqual(resolved.rung, .copyKeystroke, "The last rung attempted.")
    }

    func test_resolve_ofNoAttempts_isUnreadable() {
        XCTAssertEqual(SelectionLadder.resolve([]).read, .unreadable)
        XCTAssertNil(SelectionLadder.resolve([]).rung)
    }

    func test_shouldContinue_afterEachOutcome() {
        XCTAssertFalse(SelectionLadder.shouldContinue(after: .text("x")))
        XCTAssertFalse(SelectionLadder.shouldContinue(after: .empty))
        XCTAssertTrue(SelectionLadder.shouldContinue(after: .unreadable))
    }

    func test_substring_extractsTheSelectedRange_keepingEmojiWhole() {
        let value = "Ship the 🚀 launch on Thursday"
        let range = NSRange(location: 9, length: 3) // the emoji plus its spaces
        XCTAssertEqual(SelectionLadder.substring(of: value, in: range), " 🚀 ")
    }

    func test_substring_ofAnOutOfBoundsRange_isNil() {
        XCTAssertNil(SelectionLadder.substring(of: "short", in: NSRange(location: 40, length: 3)))
    }

    func test_substring_ofAZeroLengthRange_isEmptyNotNil() {
        XCTAssertEqual(SelectionLadder.substring(of: "abc", in: NSRange(location: 1, length: 0)), "")
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `if xcrun swift test --filter SelectionLadderTests > /tmp/t.log 2>&1; then echo PASS; else tail -20 /tmp/t.log; fi`
Expected: FAIL — `cannot find 'SelectionRung' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// One rung's answer. Three-state on purpose, mirroring
/// `TextInserter.verifyInserted`: an unreadable element is not an empty one,
/// and collapsing the two would silently rewrite nothing.
public enum SelectionRead: Equatable, Sendable {
    case text(String)
    case empty
    case unreadable
}

/// How the selected text was obtained. Recorded on every result so the
/// cross-app matrix is built from observed behaviour, not assumptions.
public enum SelectionRung: String, CaseIterable, Equatable, Sendable {
    /// Read `kAXSelectedTextAttribute`. Frequently available even where the
    /// element's full value is withheld. Fully passive.
    case axSelectedText
    /// Substring `kAXValueAttribute` by the selected range. Native Cocoa.
    case axValueSubstring
    /// Synthesize ⌘C, read the pasteboard, restore it. The only rung that
    /// reaches Chromium/Electron — and the only one that touches the target,
    /// which is why it is last.
    case copyKeystroke

    public static let ordered: [SelectionRung] = [
        .axSelectedText, .axValueSubstring, .copyKeystroke,
    ]
}

/// The pure ladder decision: given what each attempted rung returned, what is
/// the answer and which rung produced it. Kept separate from the adapter that
/// performs the reads so the sequencing is unit-testable without AX.
public enum SelectionLadder {

    public struct Resolution: Equatable, Sendable {
        public let read: SelectionRead
        /// The rung that produced `read`; nil only when nothing was attempted.
        public let rung: SelectionRung?

        public init(read: SelectionRead, rung: SelectionRung?) {
            self.read = read
            self.rung = rung
        }
    }

    /// Only an unreadable rung justifies escalating to the next one. Text and
    /// empty are both authoritative answers.
    public static func shouldContinue(after read: SelectionRead) -> Bool {
        read == .unreadable
    }

    public static func resolve(_ attempts: [(SelectionRung, SelectionRead)]) -> Resolution {
        for (rung, read) in attempts where !shouldContinue(after: read) {
            return Resolution(read: read, rung: rung)
        }
        return Resolution(read: .unreadable, rung: attempts.last?.0)
    }

    /// AX ranges are UTF-16 based; converting through `Range(_:in:)` keeps
    /// surrogate pairs (emoji) whole. Out of bounds is nil, not empty.
    public static func substring(of value: String, in range: NSRange) -> String? {
        guard let converted = Range(range, in: value) else { return nil }
        return String(value[converted])
    }
}
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `if xcrun swift test --filter SelectionLadderTests > /tmp/t.log 2>&1; then echo PASS; else tail -40 /tmp/t.log; exit 1; fi`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Rewrite/SelectionRead.swift Tests/MustardTests/SelectionLadderTests.swift
git commit -m "feat(rewrite): three-rung selection read ladder, unreadable distinct from empty"
```

---

### Task 5: `RewriteGate`

**Files:**
- Create: `Sources/MustardKit/Rewrite/RewriteGate.swift`
- Test: `Tests/MustardTests/RewriteGateTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

/// The gate, split around the read. `admits` runs BEFORE anything is read —
/// this ordering is load-bearing, because read rung 3 synthesizes ⌘C into the
/// target and must never be reached for a password field.
final class RewriteGateTests: XCTestCase {

    private func target(
        role: String = "AXTextArea",
        selectedRange: NSRange? = NSRange(location: 0, length: 12),
        isSecure: Bool = false
    ) -> FocusedTextTarget {
        FocusedTextTarget(
            applicationPID: 501,
            elementIdentifier: "501#token#\(role)#Window",
            selectedRange: selectedRange,
            precedingCharacter: nil,
            followingCharacter: nil,
            isSecure: isSecure)
    }

    // MARK: - admits (pre-read)

    func test_admits_aNormalTextAreaWithASelection() {
        XCTAssertNil(RewriteGate.admits(target: target(), role: "AXTextArea", hasAccessibility: true))
    }

    func test_admits_refusesASecureField_beforeAnythingIsRead() {
        XCTAssertEqual(
            RewriteGate.admits(target: target(isSecure: true), role: "AXTextField", hasAccessibility: true),
            .secureField,
            "A password field must be refused before rung 3 can synthesize ⌘C.")
    }

    func test_admits_refusesSecureField_evenBeforeMissingPermission() {
        // Ordering guard: if both are wrong, the secure refusal is the one that
        // matters, and it must not be masked by a permission message.
        XCTAssertEqual(
            RewriteGate.admits(target: target(isSecure: true), role: "AXTextField", hasAccessibility: false),
            .secureField)
    }

    func test_admits_refusesMissingAccessibility() {
        XCTAssertEqual(
            RewriteGate.admits(target: target(), role: "AXTextArea", hasAccessibility: false),
            .accessibilityPermissionMissing)
    }

    func test_admits_refusesAnUnsupportedRole_namingIt() {
        XCTAssertEqual(
            RewriteGate.admits(target: target(role: "AXButton"), role: "AXButton", hasAccessibility: true),
            .unsupportedRole("AXButton"))
    }

    func test_admits_refusesAZeroLengthSelection() {
        XCTAssertEqual(
            RewriteGate.admits(
                target: target(selectedRange: NSRange(location: 4, length: 0)),
                role: "AXTextArea", hasAccessibility: true),
            .noSelection,
            "A bare cursor is not a selection; rewriting the whole field could destroy a draft.")
    }

    func test_admits_allowsAHiddenRange_becauseWebAreasWithholdIt() {
        // nil range is 'unknown', not 'empty' — the ⌘C rung can still recover
        // the selection, so refusing here would lose Gmail and Slack.
        XCTAssertNil(
            RewriteGate.admits(target: target(selectedRange: nil), role: "AXWebArea", hasAccessibility: true))
    }

    // MARK: - accepts (post-read)

    func test_accepts_returnsTheTrimmedSelection() {
        let result = RewriteGate.accepts(
            read: .text("  Can you send the SOW?  "), application: "Mail", maxWords: 1024)
        XCTAssertEqual(try? result.get(), "Can you send the SOW?")
    }

    func test_accepts_refusesEmpty() {
        let result = RewriteGate.accepts(read: .empty, application: "Mail", maxWords: 1024)
        XCTAssertEqual(result.failure, .noSelection)
    }

    func test_accepts_refusesWhitespaceOnlyTextAsEmpty() {
        let result = RewriteGate.accepts(read: .text("   \n  "), application: "Mail", maxWords: 1024)
        XCTAssertEqual(result.failure, .noSelection)
    }

    func test_accepts_refusesUnreadable_namingTheApplication() {
        let result = RewriteGate.accepts(read: .unreadable, application: "Slack", maxWords: 1024)
        XCTAssertEqual(result.failure, .unreadableSelection(application: "Slack"))
    }

    func test_accepts_refusesOverBudget_reportingBothNumbers() {
        let long = Array(repeating: "word", count: 1200).joined(separator: " ")
        let result = RewriteGate.accepts(read: .text(long), application: "Mail", maxWords: 1024)
        XCTAssertEqual(result.failure, .overBudget(words: 1200, limit: 1024))
    }

    func test_accepts_allowsExactlyTheLimit() {
        let exact = Array(repeating: "word", count: 1024).joined(separator: " ")
        let result = RewriteGate.accepts(read: .text(exact), application: "Mail", maxWords: 1024)
        XCTAssertNotNil(try? result.get(), "The limit is inclusive.")
    }
}

// Small test-only conveniences for reading Result failures.
extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `if xcrun swift test --filter RewriteGateTests > /tmp/t.log 2>&1; then echo PASS; else tail -20 /tmp/t.log; fi`
Expected: FAIL — `cannot find 'RewriteGate' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// The rewrite gate, deliberately split into two decisions around the read.
///
/// `admits` runs FIRST, on the focus snapshot alone. Read rung 3 synthesizes a
/// ⌘C keystroke into the target application, so a secure field has to be
/// refused before the ladder ever runs — not after.
///
/// `accepts` runs SECOND, on the text that came back.
public enum RewriteGate {

    /// Pre-read admission. Returns nil when the target may be read.
    /// Secure is checked first and unconditionally: if a password field also
    /// lacks permission, the refusal the user must see is the secure one.
    public static func admits(
        target: FocusedTextTarget,
        role: String?,
        hasAccessibility: Bool
    ) -> RewriteRefusal? {
        if target.isSecure { return .secureField }
        guard hasAccessibility else { return .accessibilityPermissionMissing }
        guard RewriteRoles.admits(role: role) else {
            return .unsupportedRole(role ?? "unknown")
        }
        // A KNOWN zero-length range is a bare cursor. A nil range is merely
        // withheld (web areas do this routinely) and the ⌘C rung can still
        // recover the selection, so nil must not be refused here.
        if let range = target.selectedRange, range.length == 0 { return .noSelection }
        return nil
    }

    /// Post-read acceptance. Trims the selection, and refuses empty,
    /// unreadable, and oversized selections with specific copy.
    public static func accepts(
        read: SelectionRead,
        application: String,
        maxWords: Int
    ) -> Result<String, RewriteRefusal> {
        switch read {
        case .unreadable:
            return .failure(.unreadableSelection(application: application))
        case .empty:
            return .failure(.noSelection)
        case .text(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.noSelection) }
            let words = RewriteBudget.wordCount(trimmed)
            guard words <= maxWords else {
                return .failure(.overBudget(words: words, limit: maxWords))
            }
            return .success(trimmed)
        }
    }
}
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `if xcrun swift test --filter RewriteGateTests > /tmp/t.log 2>&1; then echo PASS; else tail -40 /tmp/t.log; exit 1; fi`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Rewrite/RewriteGate.swift Tests/MustardTests/RewriteGateTests.swift
git commit -m "feat(rewrite): gate split around the read so ⌘C never reaches a password field"
```

---

### Task 6: `RewriteDraft` and `RewritePrompt`

**Files:**
- Create: `Sources/MustardKit/Rewrite/RewriteDraft.swift`
- Create: `Sources/MustardKit/Rewrite/RewritePrompt.swift`
- Create: `Sources/MustardKit/Rewrite/Prompts/rewrite-26.txt`
- Create: `Sources/MustardKit/Rewrite/Prompts/rewrite-27.txt`
- Modify: `Package.swift:11` (add the resource directory)
- Test: `Tests/MustardTests/RewritePromptTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

/// Prompt assembly. Phase 2's voice profile enters through `styleRules` and
/// nowhere else, which is why that parameter exists now with an empty default.
final class RewritePromptTests: XCTestCase {

    func test_instructions_combineTheBandTextAndTheIntentFragment() {
        let instructions = RewritePrompt.instructions(
            intent: .tighten, bandInstructions: "BAND RULES", styleRules: [])
        XCTAssertTrue(instructions.contains("BAND RULES"))
        XCTAssertTrue(instructions.contains(RewriteIntent.tighten.instructionFragment))
    }

    func test_instructions_includeStyleRulesWhenPresent() {
        let instructions = RewritePrompt.instructions(
            intent: .warmer, bandInstructions: "BAND RULES",
            styleRules: ["Use contractions.", "Never open with pleasantries."])
        XCTAssertTrue(instructions.contains("Use contractions."))
        XCTAssertTrue(instructions.contains("Never open with pleasantries."))
    }

    func test_instructions_omitTheStyleSection_whenThereAreNoRules() {
        let instructions = RewritePrompt.instructions(
            intent: .warmer, bandInstructions: "BAND RULES", styleRules: [])
        XCTAssertFalse(instructions.contains(RewritePrompt.styleHeading),
                       "An empty style section is wasted context on a small window.")
    }

    func test_prompt_carriesTheSelectionVerbatimInsideDelimiters() {
        let selection = "Just wanted to check in re: the SOW"
        let prompt = RewritePrompt.prompt(selection: selection)
        XCTAssertTrue(prompt.contains(selection), "The selection must not be paraphrased or escaped.")
        XCTAssertTrue(prompt.contains(RewritePrompt.selectionOpenDelimiter))
        XCTAssertTrue(prompt.contains(RewritePrompt.selectionCloseDelimiter))
    }

    func test_promptFeatureName_isStable() {
        XCTAssertEqual(RewritePrompt.feature, "rewrite",
                       "PromptCatalog resource names derive from this.")
    }

    func test_bandResources_existForTheShippedBands() {
        // The catalog falls back downward only, so the base band must exist.
        let available: Set<String> = ["rewrite-26", "rewrite-27"]
        XCTAssertEqual(
            PromptCatalog.bestResource(feature: RewritePrompt.feature, band: .macOS26_4) {
                available.contains($0)
            },
            "rewrite-26",
            "26.4 has no dedicated prompt and must fall back to 26, never up to 27.")
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `if xcrun swift test --filter RewritePromptTests > /tmp/t.log 2>&1; then echo PASS; else tail -20 /tmp/t.log; fi`
Expected: FAIL — `cannot find 'RewritePrompt' in scope`.

- [ ] **Step 3: Implement `RewriteDraft.swift`**

```swift
import Foundation
import FoundationModels

/// The model's typed output. Guided generation means we never parse prose:
/// the framework constrains the model to this shape.
///
/// `changeNote` is one short line for the card ("cut hedging, 41 → 21 words").
/// It is explanatory only — never applied to the user's document.
@available(macOS 26.0, *)
@Generable
public struct RewriteDraft: Equatable, Sendable {
    @Guide(description: "The rewritten text only. No preamble, no quotes, no explanation.")
    public var rewritten: String

    @Guide(description: "One short line naming what changed. Under 12 words.")
    public var changeNote: String

    /// Explicit, because a public struct does not get a public memberwise
    /// init — the tests construct this directly.
    public init(rewritten: String, changeNote: String) {
        self.rewritten = rewritten
        self.changeNote = changeNote
    }
}
```

If `@Generable` and the explicit `Equatable`/`Sendable` conformances conflict on
this SDK, drop the explicit conformances first (the macro may synthesise them)
and re-run — do not remove the `@Guide` descriptions, which are what constrain
the model's output.

- [ ] **Step 4: Implement `RewritePrompt.swift`**

```swift
import Foundation

/// Builds the instructions and prompt for one rewrite. Pure — the band text
/// is passed in, having been loaded from a `PromptCatalog` resource by the
/// coordinator, so nothing here touches `Bundle`.
///
/// Phase 2 (voice profile) enters through `styleRules` and nowhere else.
public enum RewritePrompt {
    /// Feeds `PromptCatalog.resourceName(feature:band:)` → "rewrite-27" etc.
    public static let feature = "rewrite"

    public static let styleHeading = "How this person writes:"
    public static let selectionOpenDelimiter = "<<<SELECTION"
    public static let selectionCloseDelimiter = "SELECTION>>>"

    public static func instructions(
        intent: RewriteIntent,
        bandInstructions: String,
        styleRules: [String] = []
    ) -> String {
        var parts = [bandInstructions, intent.instructionFragment]
        if !styleRules.isEmpty {
            parts.append(([styleHeading] + styleRules.map { "- \($0)" }).joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// The selection goes in verbatim, inside delimiters, so the model can tell
    /// the text-to-rewrite from the instructions even when the selection itself
    /// contains instruction-shaped sentences.
    public static func prompt(selection: String) -> String {
        """
        Rewrite the text between the delimiters.

        \(selectionOpenDelimiter)
        \(selection)
        \(selectionCloseDelimiter)
        """
    }
}
```

- [ ] **Step 5: Create `Prompts/rewrite-26.txt`**

```text
You rewrite short pieces of the user's own writing — emails, chat messages, notes.

Rules, in priority order:
1. Preserve meaning exactly. Never add a fact, name, date, number, commitment or link that is not in the original.
2. Never remove a commitment, deadline, question or caveat.
3. Return the rewritten text only. No preamble, no quotation marks, no commentary.
4. Match the original's language, register and format. If it is one sentence, return one sentence. If it is a bulleted list, return a bulleted list.
5. Keep the original's markup, code, URLs and @mentions byte-for-byte.
6. If the text is already good, return it unchanged rather than inventing changes.
```

- [ ] **Step 6: Create `Prompts/rewrite-27.txt`** — same content as `rewrite-26.txt`
  for now. It exists so the current band gets an exact match rather than a
  fallback, and so band-specific tuning has a home once the matrix produces
  evidence. Copy the file verbatim:

```bash
cp Sources/MustardKit/Rewrite/Prompts/rewrite-26.txt Sources/MustardKit/Rewrite/Prompts/rewrite-27.txt
```

- [ ] **Step 7: Register the resource directory in `Package.swift`**

Change line 11 from:

```swift
            resources: [.process("Agent/Prompts"), .process("Voice/Prompts")]
```

to:

```swift
            resources: [
                .process("Agent/Prompts"), .process("Voice/Prompts"),
                .process("Rewrite/Prompts"),
            ]
```

- [ ] **Step 8: Run the tests and a full build**

Run: `if xcrun swift build > /tmp/b.log 2>&1 && xcrun swift test --filter RewritePromptTests > /tmp/t.log 2>&1; then echo PASS; else tail -40 /tmp/b.log /tmp/t.log; exit 1; fi`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/MustardKit/Rewrite/RewriteDraft.swift Sources/MustardKit/Rewrite/RewritePrompt.swift Sources/MustardKit/Rewrite/Prompts Package.swift Tests/MustardTests/RewritePromptTests.swift
git commit -m "feat(rewrite): guided-generation draft type, prompt assembly and band resources"
```

---

### Task 7: `SelectionReading` seam and the live AX reader

**Files:**
- Create: `Sources/MustardKit/Rewrite/AccessibilitySelectionReader.swift`
- Modify: `Sources/MustardKit/Dictation/AccessibilityFocusReader.swift` (add
  `selectedText` to `AXFocusProbe` and its live probe)
- Test: `Tests/MustardTests/AccessibilitySelectionReaderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

/// The live reader's SEQUENCING, with all three rungs stubbed. No test here
/// touches AX or the pasteboard — the point is to pin that rung 3 (⌘C) is only
/// ever reached when the passive rungs came back unreadable.
final class AccessibilitySelectionReaderTests: XCTestCase {

    private let target = FocusedTextTarget(
        applicationPID: 501,
        elementIdentifier: "501#t#AXWebArea#Gmail",
        selectedRange: NSRange(location: 0, length: 5),
        precedingCharacter: nil,
        followingCharacter: nil,
        isSecure: false)

    private func reader(
        axSelectedText: @escaping () -> String? = { nil },
        axValue: @escaping () -> String? = { nil },
        copy: @escaping () -> String? = { nil },
        copyCount: CopyCounter = CopyCounter()
    ) -> AccessibilitySelectionReader {
        AccessibilitySelectionReader(
            readSelectedTextAttribute: { _ in axSelectedText() },
            readValueAttribute: { _ in axValue() },
            copySelectionViaKeystroke: { _ in copyCount.calls += 1; return copy() })
    }

    final class CopyCounter { var calls = 0 }

    func test_rungOne_wins_andNoKeystrokeIsSynthesized() async {
        let counter = CopyCounter()
        let reader = self.reader(axSelectedText: { "Hello there" }, copyCount: counter)

        let resolution = await reader.read(target)

        XCTAssertEqual(resolution.read, .text("Hello there"))
        XCTAssertEqual(resolution.rung, .axSelectedText)
        XCTAssertEqual(counter.calls, 0, "A passive rung succeeded; nothing may be sent to the app.")
    }

    func test_rungTwo_substringsTheValueByTheSelectedRange() async {
        let reader = self.reader(axValue: { "Hello there, Leon" })

        let resolution = await reader.read(target) // range 0..<5

        XCTAssertEqual(resolution.read, .text("Hello"))
        XCTAssertEqual(resolution.rung, .axValueSubstring)
    }

    func test_rungTwo_isSkipped_whenTheRangeIsWithheld() async {
        let hiddenRange = FocusedTextTarget(
            applicationPID: 501, elementIdentifier: "x", selectedRange: nil,
            precedingCharacter: nil, followingCharacter: nil, isSecure: false)
        let reader = self.reader(axValue: { "Hello there, Leon" }, copy: { "copied" })

        let resolution = await reader.read(hiddenRange)

        XCTAssertEqual(resolution.read, .text("copied"),
                       "Without a range the value cannot be sliced; fall through to ⌘C.")
        XCTAssertEqual(resolution.rung, .copyKeystroke)
    }

    func test_rungThree_reached_onlyWhenBothPassiveRungsAreUnreadable() async {
        let counter = CopyCounter()
        let reader = self.reader(copy: { "Can you send the SOW?" }, copyCount: counter)

        let resolution = await reader.read(target)

        XCTAssertEqual(resolution.read, .text("Can you send the SOW?"))
        XCTAssertEqual(resolution.rung, .copyKeystroke)
        XCTAssertEqual(counter.calls, 1)
    }

    func test_allRungsUnreadable_isUnreadable_notEmpty() async {
        let resolution = await reader(copy: { nil }).read(target)
        XCTAssertEqual(resolution.read, .unreadable)
    }

    func test_aReadableEmptySelection_stopsAtRungOne() async {
        let counter = CopyCounter()
        let reader = self.reader(axSelectedText: { "" }, copyCount: counter)

        let resolution = await reader.read(target)

        XCTAssertEqual(resolution.read, .empty)
        XCTAssertEqual(counter.calls, 0, "A real empty answer must not escalate to ⌘C.")
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `if xcrun swift test --filter AccessibilitySelectionReaderTests > /tmp/t.log 2>&1; then echo PASS; else tail -20 /tmp/t.log; fi`
Expected: FAIL — `cannot find 'AccessibilitySelectionReader' in scope`.

- [ ] **Step 3: Add `selectedText` to `AXFocusProbe`**

In `Sources/MustardKit/Dictation/AccessibilityFocusReader.swift`, add the
property to the struct (after `value`), add it to the memberwise `init` with a
default of `nil` so existing dictation call sites and tests keep compiling:

```swift
    /// The element's currently selected text (`kAXSelectedTextAttribute`).
    /// Frequently readable even when `value` is withheld, which is why rewrite's
    /// read ladder tries it first. Dictation does not use this.
    public var selectedText: String?
```

In the `init`, add the parameter last, with a default:

```swift
        selectedText: String? = nil,
```

and assign it: `self.selectedText = selectedText`.

In `liveProbe()`, populate it alongside the other attributes:

```swift
            selectedText: attribute(kAXSelectedTextAttribute, of: element) as? String,
```

- [ ] **Step 4: Implement `AccessibilitySelectionReader.swift`**

```swift
import Foundation

/// Reads the text a user has selected in the focused element. Every edge is an
/// injected closure, so the sequencing below is unit-tested without AX, the
/// pasteboard, or synthesized key events.
///
/// The ordering is a safety property, not an optimisation: rungs 1 and 2 are
/// passive reads, and rung 3 posts ⌘V-style key events into someone else's
/// application. Rung 3 is therefore last, and `RewriteGate.admits` must have
/// already refused secure fields before this runs at all.
public struct AccessibilitySelectionReader {
    /// Rung 1 — `kAXSelectedTextAttribute`. nil means unreadable.
    public var readSelectedTextAttribute: (FocusedTextTarget) -> String?
    /// Rung 2 — `kAXValueAttribute`, to be sliced by the target's range.
    public var readValueAttribute: (FocusedTextTarget) -> String?
    /// Rung 3 — synthesize ⌘C, read the pasteboard, restore it. nil means
    /// the application did not service the copy.
    public var copySelectionViaKeystroke: (FocusedTextTarget) -> String?

    public init(
        readSelectedTextAttribute: @escaping (FocusedTextTarget) -> String?,
        readValueAttribute: @escaping (FocusedTextTarget) -> String?,
        copySelectionViaKeystroke: @escaping (FocusedTextTarget) -> String?
    ) {
        self.readSelectedTextAttribute = readSelectedTextAttribute
        self.readValueAttribute = readValueAttribute
        self.copySelectionViaKeystroke = copySelectionViaKeystroke
    }

    public func read(_ target: FocusedTextTarget) async -> SelectionLadder.Resolution {
        var attempts: [(SelectionRung, SelectionRead)] = []

        attempts.append((.axSelectedText, Self.classify(readSelectedTextAttribute(target))))
        if SelectionLadder.shouldContinue(after: attempts[attempts.count - 1].1) {
            attempts.append((.axValueSubstring, rungTwo(target)))
        }
        if SelectionLadder.shouldContinue(after: attempts[attempts.count - 1].1) {
            attempts.append((.copyKeystroke, Self.classify(copySelectionViaKeystroke(target))))
        }
        return SelectionLadder.resolve(attempts)
    }

    /// Rung 2 needs BOTH a readable value and a known range — a withheld range
    /// cannot be sliced, so that case is unreadable and falls through.
    private func rungTwo(_ target: FocusedTextTarget) -> SelectionRead {
        guard let value = readValueAttribute(target),
              let range = target.selectedRange,
              let slice = SelectionLadder.substring(of: value, in: range) else {
            return .unreadable
        }
        return Self.classify(slice)
    }

    /// nil is unreadable; "" is a real, readable, empty selection. Collapsing
    /// these is the bug this three-state exists to prevent.
    static func classify(_ text: String?) -> SelectionRead {
        guard let text else { return .unreadable }
        return text.isEmpty ? .empty : .text(text)
    }
}
```

- [ ] **Step 5: Run the tests and the full suite**

Run: `if xcrun swift test > /tmp/t.log 2>&1; then echo PASS; else tail -60 /tmp/t.log; exit 1; fi`
Expected: PASS, including every pre-existing dictation test — the `AXFocusProbe`
change is additive with a defaulted parameter, so no existing call site changes.

- [ ] **Step 6: Commit**

```bash
git add Sources/MustardKit/Rewrite/AccessibilitySelectionReader.swift Sources/MustardKit/Dictation/AccessibilityFocusReader.swift Tests/MustardTests/AccessibilitySelectionReaderTests.swift
git commit -m "feat(rewrite): selection reader whose ⌘C rung is reached last, and only when needed"
```

---

### Task 8: Live wiring for the reader's three rungs

**Files:**
- Modify: `Sources/MustardKit/Rewrite/AccessibilitySelectionReader.swift` (add a
  `live()` factory in an `#if os(macOS)` extension)

There is no unit test for this task: it is pure OS edge, exactly like
`TextInserter.live()`, and is verified by the cross-app matrix in Task 14.

- [ ] **Step 1: Append the live factory**

```swift
#if os(macOS)
import AppKit
import ApplicationServices

extension AccessibilitySelectionReader {
    /// The production reader. Rungs 1 and 2 are passive AX reads. Rung 3
    /// reuses `PasteboardSnapshot`'s capture → copy → restore-only-if-still-ours
    /// discipline and the same `postToPid` synthesis `TextInserter` uses for ⌘V,
    /// so the user's clipboard survives a rewrite untouched.
    @MainActor
    public static func live() -> AccessibilitySelectionReader {
        func focusedElement() -> AXUIElement? {
            let systemWide = AXUIElementCreateSystemWide()
            var focusedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                    systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                  let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeDowncast(focusedRef, to: AXUIElement.self)
        }

        func attribute(_ name: String) -> String? {
            guard let element = focusedElement() else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
                return nil
            }
            return value as? String
        }

        return AccessibilitySelectionReader(
            readSelectedTextAttribute: { _ in attribute(kAXSelectedTextAttribute) },
            readValueAttribute: { _ in attribute(kAXValueAttribute) },
            copySelectionViaKeystroke: { target in
                let snapshot = PasteboardSnapshot.capture(from: .general)
                let before = NSPasteboard.general.changeCount

                guard let source = CGEventSource(stateID: .hidSystemState),
                      // virtualKey 8 == 'c'
                      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
                    return nil
                }
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand
                keyDown.postToPid(target.applicationPID)
                keyUp.postToPid(target.applicationPID)

                // Give the target time to service ⌘C, matching TextInserter's
                // 350ms settle. A copy that never lands leaves changeCount
                // untouched, which is how we detect it.
                Thread.sleep(forTimeInterval: 0.35)

                let copied = NSPasteboard.general.changeCount != before
                    ? NSPasteboard.general.string(forType: .string)
                    : nil
                snapshot.restore(to: .general)
                return copied
            })
    }
}
#endif
```

- [ ] **Step 2: Build**

Run: `if xcrun swift build > /tmp/b.log 2>&1; then echo PASS; else tail -40 /tmp/b.log; exit 1; fi`
Expected: PASS. If `PasteboardSnapshot.capture(from:)`/`restore(to:)` signatures
differ, read `Sources/MustardKit/Dictation/PasteboardSnapshot.swift` and match
it — do not change that file.

- [ ] **Step 3: Commit**

```bash
git add Sources/MustardKit/Rewrite/AccessibilitySelectionReader.swift
git commit -m "feat(rewrite): live AX/⌘C selection reader with clipboard restore"
```

---

### Task 9: `SelectionRestorer` — re-assert the range before writing

**Files:**
- Create: `Sources/MustardKit/Rewrite/SelectionRestorer.swift`
- Test: `Tests/MustardTests/SelectionRestorerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

/// Before writing a rewrite back, the coordinator re-asserts the range it
/// snapshotted rather than trusting the target application to have preserved
/// its selection while the card held key focus. Whether an app keeps its
/// selection highlight after losing key-window status is app-specific; this
/// removes the question from the correctness path entirely.
final class SelectionRestorerTests: XCTestCase {

    private func target(range: NSRange?) -> FocusedTextTarget {
        FocusedTextTarget(
            applicationPID: 501, elementIdentifier: "e", selectedRange: range,
            precedingCharacter: nil, followingCharacter: nil, isSecure: false)
    }

    func test_reasserts_theSnapshottedRange_whenIdentityStillMatches() {
        var written: NSRange?
        let restorer = SelectionRestorer(
            stillFocused: { _ in true },
            setSelectedRange: { _, range in written = range; return true })

        let outcome = restorer.reassert(on: target(range: NSRange(location: 4, length: 12)))

        XCTAssertEqual(outcome, .reasserted)
        XCTAssertEqual(written, NSRange(location: 4, length: 12))
    }

    func test_refuses_whenFocusMoved() {
        var written: NSRange?
        let restorer = SelectionRestorer(
            stillFocused: { _ in false },
            setSelectedRange: { _, range in written = range; return true })

        XCTAssertEqual(restorer.reassert(on: target(range: NSRange(location: 0, length: 3))),
                       .focusChanged)
        XCTAssertNil(written, "Nothing may be written into an element that no longer has focus.")
    }

    func test_withholdRange_isNotAFailure_becausePasteReplacesTheLiveSelection() {
        // Web areas hide their range. There is nothing to re-assert, and ⌘V
        // over whatever is selected still does the right thing — so this
        // proceeds rather than refusing and losing Gmail and Slack.
        let restorer = SelectionRestorer(
            stillFocused: { _ in true },
            setSelectedRange: { _, _ in XCTFail("nothing to set"); return false })

        XCTAssertEqual(restorer.reassert(on: target(range: nil)), .noRangeToReassert)
    }

    func test_aRejectedRangeWrite_isNotFatal() {
        // Plenty of apps refuse a settable range write yet still paste
        // correctly. Report it so it is logged, but do not block the write.
        let restorer = SelectionRestorer(
            stillFocused: { _ in true },
            setSelectedRange: { _, _ in false })

        XCTAssertEqual(restorer.reassert(on: target(range: NSRange(location: 1, length: 2))),
                       .reassertRejected)
    }

    func test_onlyFocusChanged_blocksTheWrite() {
        XCTAssertFalse(SelectionRestorer.Outcome.focusChanged.permitsWrite)
        XCTAssertTrue(SelectionRestorer.Outcome.reasserted.permitsWrite)
        XCTAssertTrue(SelectionRestorer.Outcome.noRangeToReassert.permitsWrite)
        XCTAssertTrue(SelectionRestorer.Outcome.reassertRejected.permitsWrite)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `if xcrun swift test --filter SelectionRestorerTests > /tmp/t.log 2>&1; then echo PASS; else tail -20 /tmp/t.log; fi`
Expected: FAIL — `cannot find 'SelectionRestorer' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Re-asserts the snapshotted selection immediately before the rewrite is
/// written back. Only a genuine focus change blocks the write — a withheld or
/// unsettable range is reported (so the matrix records it) but still proceeds,
/// because ⌘V over the live selection remains correct in those apps.
public struct SelectionRestorer {
    public enum Outcome: Equatable, Sendable {
        /// The range was set successfully.
        case reasserted
        /// The element hides its range; nothing to set.
        case noRangeToReassert
        /// The element refused the range write. Logged, not fatal.
        case reassertRejected
        /// A different element has focus. The write must not happen.
        case focusChanged

        public var permitsWrite: Bool { self != .focusChanged }
    }

    public var stillFocused: (FocusedTextTarget) -> Bool
    public var setSelectedRange: (FocusedTextTarget, NSRange) -> Bool

    public init(
        stillFocused: @escaping (FocusedTextTarget) -> Bool,
        setSelectedRange: @escaping (FocusedTextTarget, NSRange) -> Bool
    ) {
        self.stillFocused = stillFocused
        self.setSelectedRange = setSelectedRange
    }

    public func reassert(on target: FocusedTextTarget) -> Outcome {
        guard stillFocused(target) else { return .focusChanged }
        guard let range = target.selectedRange else { return .noRangeToReassert }
        return setSelectedRange(target, range) ? .reasserted : .reassertRejected
    }
}

#if os(macOS)
import ApplicationServices

extension SelectionRestorer {
    /// The production restorer, over `kAXSelectedTextRangeAttribute`.
    @MainActor
    public static func live(reader: AccessibilityFocusReader = .live()) -> SelectionRestorer {
        SelectionRestorer(
            stillFocused: { reader.isStillFocused($0) },
            setSelectedRange: { _, range in
                let systemWide = AXUIElementCreateSystemWide()
                var focusedRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                        systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                      let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
                    return false
                }
                let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
                var cfRange = CFRange(location: range.location, length: range.length)
                guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
                return AXUIElementSetAttributeValue(
                    element, kAXSelectedTextRangeAttribute as CFString, value) == .success
            })
    }
}
#endif
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `if xcrun swift test --filter SelectionRestorerTests > /tmp/t.log 2>&1; then echo PASS; else tail -40 /tmp/t.log; exit 1; fi`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Rewrite/SelectionRestorer.swift Tests/MustardTests/SelectionRestorerTests.swift
git commit -m "feat(rewrite): re-assert the snapshotted range instead of trusting the app to keep it"
```

---

### Task 10: `RewritePhase` and `RewriteCoordinator`

**Files:**
- Create: `Sources/MustardKit/Rewrite/RewritePhase.swift`
- Create: `Sources/MustardKit/Rewrite/RewriteCoordinator.swift`
- Test: `Tests/MustardTests/RewriteCoordinatorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import MustardKit

/// The coordinator's phase machine, driven entirely by stubs. This is where the
/// spec's ordering guarantees are pinned: the gate runs before the read, the
/// write happens only after an explicit accept, and a failed write leaves the
/// original alone.
@available(macOS 26.0, *)
@MainActor
final class RewriteCoordinatorTests: XCTestCase {

    private func target(isSecure: Bool = false) -> FocusedTextTarget {
        FocusedTextTarget(
            applicationPID: 501, elementIdentifier: "e",
            selectedRange: NSRange(location: 0, length: 20),
            precedingCharacter: nil, followingCharacter: nil, isSecure: false || isSecure)
    }

    /// Records what the coordinator did, in order.
    final class Journal { var events: [String] = [] }

    private func coordinator(
        journal: Journal = Journal(),
        snapshot: FocusedTextTarget? = nil,
        role: String = "AXTextArea",
        hasAccessibility: Bool = true,
        read: SelectionRead = .text("I just wanted to quickly check in about the SOW"),
        draft: Result<RewriteDraft, Error> = .success(
            RewriteDraft(rewritten: "Can you send the SOW?", changeNote: "cut hedging")),
        reassert: SelectionRestorer.Outcome = .reasserted,
        write: TextInsertionOutcome = .insertedDirectly
    ) -> RewriteCoordinator {
        RewriteCoordinator(
            snapshotFocus: { journal.events.append("snapshot"); return snapshot ?? self.target() },
            focusedRole: { role },
            hasAccessibility: { hasAccessibility },
            applicationName: { _ in "Mail" },
            maxWords: { 1024 },
            bandInstructions: { "BAND" },
            readSelection: { _ in
                journal.events.append("read")
                return SelectionLadder.Resolution(read: read, rung: .axSelectedText)
            },
            generate: { _, _ in
                journal.events.append("generate")
                return try draft.get()
            },
            reassertSelection: { _ in journal.events.append("reassert"); return reassert },
            writeBack: { _, _ in journal.events.append("write"); return write })
    }

    // MARK: - Ordering

    func test_invoke_gatesBeforeReading_soASecureFieldIsNeverRead() async {
        let journal = Journal()
        let sut = coordinator(journal: journal, snapshot: target(isSecure: true))

        await sut.invoke(intent: .tighten)

        XCTAssertEqual(sut.phase, .refused(.secureField))
        XCTAssertEqual(journal.events, ["snapshot"],
                       "No read may occur for a secure field — rung 3 would synthesize ⌘C.")
    }

    func test_invoke_reachesReviewWithoutWriting() async {
        let journal = Journal()
        let sut = coordinator(journal: journal)

        await sut.invoke(intent: .tighten)

        guard case .reviewing(let review) = sut.phase else {
            return XCTFail("expected reviewing, got \(sut.phase)")
        }
        XCTAssertEqual(review.rewritten, "Can you send the SOW?")
        XCTAssertEqual(review.original, "I just wanted to quickly check in about the SOW")
        XCTAssertEqual(review.intent, .tighten)
        XCTAssertEqual(journal.events, ["snapshot", "read", "generate"],
                       "Nothing is written until the user accepts.")
    }

    // MARK: - Refusals

    func test_invoke_refusesMissingAccessibility_withoutReading() async {
        let journal = Journal()
        let sut = coordinator(journal: journal, hasAccessibility: false)

        await sut.invoke(intent: .tighten)

        XCTAssertEqual(sut.phase, .refused(.accessibilityPermissionMissing))
        XCTAssertEqual(journal.events, ["snapshot"])
    }

    func test_invoke_refusesAnUnreadableSelection_namingTheApplication() async {
        let sut = coordinator(read: .unreadable)
        await sut.invoke(intent: .tighten)
        XCTAssertEqual(sut.phase, .refused(.unreadableSelection(application: "Mail")))
    }

    func test_invoke_mapsAModelFailure() async {
        let sut = coordinator(draft: .failure(LocalModelFailure.appleIntelligenceDisabled))
        await sut.invoke(intent: .tighten)
        XCTAssertEqual(sut.phase, .refused(.model(.appleIntelligenceDisabled)))
    }

    // MARK: - Accept

    func test_accept_reassertsTheRangeThenWrites() async {
        let journal = Journal()
        let sut = coordinator(journal: journal)
        await sut.invoke(intent: .tighten)

        await sut.accept()

        XCTAssertEqual(journal.events, ["snapshot", "read", "generate", "reassert", "write"],
                       "The range is re-asserted immediately before the write, in that order.")
        XCTAssertEqual(sut.phase, .idle, "A successful write closes the card.")
    }

    func test_accept_refusesToWrite_whenFocusMoved() async {
        let journal = Journal()
        let sut = coordinator(journal: journal, reassert: .focusChanged)
        await sut.invoke(intent: .tighten)

        await sut.accept()

        XCTAssertFalse(journal.events.contains("write"))
        XCTAssertEqual(sut.phase, .refused(.focusChanged))
    }

    func test_accept_keepsTheRewriteOnScreen_whenTheWriteFails() async {
        let sut = coordinator(write: .recoverable("the app didn't accept the paste"))
        await sut.invoke(intent: .tighten)

        await sut.accept()

        guard case .reviewing(let review) = sut.phase else {
            return XCTFail("A failed write must keep the card open, got \(sut.phase)")
        }
        XCTAssertEqual(review.rewritten, "Can you send the SOW?")
        XCTAssertEqual(review.writeFailure, "the app didn't accept the paste")
    }

    func test_accept_doesNothing_whenThereIsNoReview() async {
        let journal = Journal()
        let sut = coordinator(journal: journal)

        await sut.accept()

        XCTAssertEqual(journal.events, [], "An accept with no open card is a no-op, not a crash.")
    }

    // MARK: - Discard and re-invoke

    func test_discard_returnsToIdle_withoutWriting() async {
        let journal = Journal()
        let sut = coordinator(journal: journal)
        await sut.invoke(intent: .tighten)

        sut.discard()

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertFalse(journal.events.contains("write"))
    }

    func test_reinvoke_whileReviewing_regeneratesAgainstTheSameOriginal() async {
        let journal = Journal()
        let sut = coordinator(journal: journal)
        await sut.invoke(intent: .tighten)

        await sut.invoke(intent: .tighten)

        XCTAssertEqual(journal.events, ["snapshot", "read", "generate", "generate"],
                       "Another take re-generates; it must not re-snapshot or re-read.")
    }

    func test_changeIntent_regeneratesWithTheNewIntent() async {
        let sut = coordinator()
        await sut.invoke(intent: .tighten)

        await sut.change(intent: .warmer)

        guard case .reviewing(let review) = sut.phase else {
            return XCTFail("expected reviewing")
        }
        XCTAssertEqual(review.intent, .warmer)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `if xcrun swift test --filter RewriteCoordinatorTests > /tmp/t.log 2>&1; then echo PASS; else tail -20 /tmp/t.log; fi`
Expected: FAIL — `cannot find 'RewriteCoordinator' in scope`.

- [ ] **Step 3: Implement `RewritePhase.swift`**

```swift
import Foundation

/// What the card is showing. One value, so the view is a pure function of it.
@available(macOS 26.0, *)
public enum RewritePhase: Equatable, Sendable {
    case idle
    case reading
    case generating(RewriteIntent)
    case reviewing(RewriteReview)
    case refused(RewriteRefusal)
}

/// A rewrite awaiting the user's decision. Holds the original so the card can
/// show the before/after, and the target so the accept writes to the element
/// that was focused when ⌃⌥R was pressed — not whatever has focus later.
@available(macOS 26.0, *)
public struct RewriteReview: Equatable, Sendable {
    public let original: String
    public let rewritten: String
    public let changeNote: String
    public let intent: RewriteIntent
    public let target: FocusedTextTarget
    /// Set when an accept was attempted and the write-back failed. The card
    /// stays open so the rewrite is not lost.
    public var writeFailure: String?

    public init(
        original: String,
        rewritten: String,
        changeNote: String,
        intent: RewriteIntent,
        target: FocusedTextTarget,
        writeFailure: String? = nil
    ) {
        self.original = original
        self.rewritten = rewritten
        self.changeNote = changeNote
        self.intent = intent
        self.target = target
        self.writeFailure = writeFailure
    }
}
```

- [ ] **Step 4: Implement `RewriteCoordinator.swift`**

```swift
import Foundation
import Observation

/// Sequences one rewrite: snapshot → gate → read → gate → generate → review →
/// accept → re-assert → write. Every OS edge is an injected closure, so the
/// ordering guarantees in the spec are unit-testable without AX or a model.
///
/// Ordering that is load-bearing, not incidental:
/// - `RewriteGate.admits` runs BEFORE `readSelection`, because read rung 3
///   synthesizes ⌘C into the target and must never reach a password field.
/// - `reassertSelection` runs immediately BEFORE `writeBack`, so the write
///   lands on the range that was snapshotted rather than on whatever the app
///   left selected while the card had key focus.
@available(macOS 26.0, *)
@MainActor
@Observable
public final class RewriteCoordinator {
    public private(set) var phase: RewritePhase = .idle

    private let snapshotFocus: () -> FocusedTextTarget?
    private let focusedRole: () -> String?
    private let hasAccessibility: () -> Bool
    private let applicationName: (pid_t) -> String
    private let maxWords: () -> Int
    private let bandInstructions: () -> String
    private let readSelection: (FocusedTextTarget) async -> SelectionLadder.Resolution
    private let generate: (String, RewriteIntent) async throws -> RewriteDraft
    private let reassertSelection: (FocusedTextTarget) -> SelectionRestorer.Outcome
    private let writeBack: (String, FocusedTextTarget) async -> TextInsertionOutcome

    public init(
        snapshotFocus: @escaping () -> FocusedTextTarget?,
        focusedRole: @escaping () -> String?,
        hasAccessibility: @escaping () -> Bool,
        applicationName: @escaping (pid_t) -> String,
        maxWords: @escaping () -> Int,
        bandInstructions: @escaping () -> String,
        readSelection: @escaping (FocusedTextTarget) async -> SelectionLadder.Resolution,
        generate: @escaping (String, RewriteIntent) async throws -> RewriteDraft,
        reassertSelection: @escaping (FocusedTextTarget) -> SelectionRestorer.Outcome,
        writeBack: @escaping (String, FocusedTextTarget) async -> TextInsertionOutcome
    ) {
        self.snapshotFocus = snapshotFocus
        self.focusedRole = focusedRole
        self.hasAccessibility = hasAccessibility
        self.applicationName = applicationName
        self.maxWords = maxWords
        self.bandInstructions = bandInstructions
        self.readSelection = readSelection
        self.generate = generate
        self.reassertSelection = reassertSelection
        self.writeBack = writeBack
    }

    /// ⌃⌥R. While a review is open this is "another take" — it regenerates
    /// against the same original rather than re-snapshotting focus, which by
    /// then belongs to the card.
    public func invoke(intent: RewriteIntent) async {
        if case .reviewing(let review) = phase {
            await regenerate(review: review, intent: intent)
            return
        }

        guard let target = snapshotFocus() else {
            phase = .refused(.accessibilityPermissionMissing)
            return
        }
        if let refusal = RewriteGate.admits(
            target: target, role: focusedRole(), hasAccessibility: hasAccessibility()) {
            phase = .refused(refusal)
            return
        }

        phase = .reading
        let resolution = await readSelection(target)
        let application = applicationName(target.applicationPID)
        switch RewriteGate.accepts(
            read: resolution.read, application: application, maxWords: maxWords()) {
        case .failure(let refusal):
            phase = .refused(refusal)
        case .success(let selection):
            await produce(original: selection, intent: intent, target: target)
        }
    }

    /// 1–4 in the card.
    public func change(intent: RewriteIntent) async {
        guard case .reviewing(let review) = phase else { return }
        await regenerate(review: review, intent: intent)
    }

    /// Return in the card.
    public func accept() async {
        guard case .reviewing(var review) = phase else { return }

        let outcome = reassertSelection(review.target)
        guard outcome.permitsWrite else {
            phase = .refused(.focusChanged)
            return
        }

        switch await writeBack(review.rewritten, review.target) {
        case .insertedDirectly, .insertedByPaste:
            phase = .idle
        case .recoverable(let reason):
            // Keep the card open: the rewrite is still on screen and the
            // user's original is untouched in the application.
            review.writeFailure = reason
            phase = .reviewing(review)
        }
    }

    /// Esc in the card.
    public func discard() {
        phase = .idle
    }

    // MARK: - Private

    private func produce(original: String, intent: RewriteIntent, target: FocusedTextTarget) async {
        phase = .generating(intent)
        do {
            let draft = try await generate(original, intent)
            phase = .reviewing(RewriteReview(
                original: original,
                rewritten: draft.rewritten,
                changeNote: draft.changeNote,
                intent: intent,
                target: target))
        } catch {
            phase = .refused(Self.refusal(for: error))
        }
    }

    private func regenerate(review: RewriteReview, intent: RewriteIntent) async {
        await produce(original: review.original, intent: intent, target: review.target)
    }

    /// Maps a thrown error onto the refusal vocabulary. Anything unrecognised
    /// keeps its own description rather than being flattened to "unavailable".
    static func refusal(for error: Error) -> RewriteRefusal {
        if let failure = error as? LocalModelFailure { return .model(failure) }
        if let mapped = OnDeviceLanguageService.mappedFailure(error) { return .model(mapped) }
        return .model(.unavailable(String(describing: error)))
    }
}
```

- [ ] **Step 5: Run it and confirm it passes**

Run: `if xcrun swift test --filter RewriteCoordinatorTests > /tmp/t.log 2>&1; then echo PASS; else tail -60 /tmp/t.log; exit 1; fi`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/MustardKit/Rewrite/RewritePhase.swift Sources/MustardKit/Rewrite/RewriteCoordinator.swift Tests/MustardTests/RewriteCoordinatorTests.swift
git commit -m "feat(rewrite): coordinator pinning gate-before-read and reassert-before-write"
```

---

### Task 11: `RewriteLog` — instrumentation, before the fragile layer exists

**Files:**
- Create: `Sources/MustardKit/Rewrite/RewriteLog.swift`
- Modify: `Sources/MustardKit/Rewrite/RewriteCoordinator.swift` (log at each boundary)

There is no unit test: this is logging. It is a *task* rather than an
afterthought because the voice suite's record is explicit — three speculative
hotkey fixes made things worse, and a boundary trace found the cause in one pass.

- [ ] **Step 1: Create the logger**

```swift
import Foundation
import os

/// Boundary instrumentation for the rewrite path. Same subsystem as the voice
/// suite so one predicate follows a whole interaction:
///
///     log stream --predicate 'subsystem == "com.cavehole.mustard"'
///
/// Selection text is NEVER logged — only its length. The whole point of an
/// on-device rewrite is that the user's words stay private, and a system log is
/// readable by anything on the machine.
public enum RewriteLog {
    public static let logger = Logger(subsystem: "com.cavehole.mustard", category: "rewrite")

    public static func snapshot(role: String?, subrole: String?, range: NSRange?, secure: Bool) {
        logger.info("""
            snapshot role=\(role ?? "nil", privacy: .public) \
            subrole=\(subrole ?? "nil", privacy: .public) \
            range=\(range.map { "\($0.location)+\($0.length)" } ?? "nil", privacy: .public) \
            secure=\(secure, privacy: .public)
            """)
    }

    public static func gate(_ refusal: RewriteRefusal?) {
        logger.info("gate=\(refusal.map { String(describing: $0) } ?? "admitted", privacy: .public)")
    }

    public static func read(rung: SelectionRung?, outcome: SelectionRead, characters: Int) {
        let described: String
        switch outcome {
        case .text: described = "text"
        case .empty: described = "empty"
        case .unreadable: described = "unreadable"
        }
        logger.info("""
            read rung=\(rung?.rawValue ?? "none", privacy: .public) \
            outcome=\(described, privacy: .public) chars=\(characters, privacy: .public)
            """)
    }

    public static func generated(intent: RewriteIntent, characters: Int, band: String) {
        logger.info("""
            generated intent=\(intent.rawValue, privacy: .public) \
            chars=\(characters, privacy: .public) band=\(band, privacy: .public)
            """)
    }

    public static func reassert(_ outcome: SelectionRestorer.Outcome) {
        logger.info("reassert=\(String(describing: outcome), privacy: .public)")
    }

    public static func wrote(_ outcome: TextInsertionOutcome) {
        logger.info("write=\(String(describing: outcome), privacy: .public)")
    }
}
```

- [ ] **Step 2: Call it from the coordinator**

Add these calls in `RewriteCoordinator`, without changing any control flow:

- in `invoke`, after `snapshotFocus()` succeeds:
  `RewriteLog.snapshot(role: focusedRole(), subrole: nil, range: target.selectedRange, secure: target.isSecure)`
- in `invoke`, immediately after computing the `admits` result (both branches):
  `RewriteLog.gate(refusal)`
- in `invoke`, after `readSelection`:
  `RewriteLog.read(rung: resolution.rung, outcome: resolution.read, characters: { if case .text(let t) = resolution.read { return t.count } else { return 0 } }())`
- in `produce`, after a successful `generate`:
  `RewriteLog.generated(intent: intent, characters: draft.rewritten.count, band: PromptCatalog.currentBand.rawValue)`
- in `accept`, after `reassertSelection`: `RewriteLog.reassert(outcome)`
- in `accept`, after `writeBack` returns: `RewriteLog.wrote(result)` (bind the
  result to a `let` first rather than switching on the call directly)

- [ ] **Step 3: Run the full suite and build**

Run: `if xcrun swift build > /tmp/b.log 2>&1 && xcrun swift test > /tmp/t.log 2>&1; then echo PASS; else tail -60 /tmp/b.log /tmp/t.log; exit 1; fi`
Expected: PASS — the coordinator tests must still pass unchanged, since logging
adds no behaviour.

- [ ] **Step 4: Commit**

```bash
git add Sources/MustardKit/Rewrite/RewriteLog.swift Sources/MustardKit/Rewrite/RewriteCoordinator.swift
git commit -m "chore(rewrite): instrument every boundary before the hardware layer lands"
```

---

### Task 12: `RewriteHotKey` — Carbon ⌃⌥R

**Files:**
- Create: `Sources/MustardKit/Rewrite/RewriteHotKey.swift`

No unit test: `RegisterEventHotKey` is an OS edge with no injectable seam, exactly
like `Capture/PushToTalkHotKey`. **Read `Capture/PushToTalkHotKey.swift` first and
mirror its structure** — it already encodes four hard-won hardware lessons.

- [ ] **Step 1: Implement, mirroring `PushToTalkHotKey`**

```swift
#if os(macOS)
import Carbon.HIToolbox
import Foundation

/// ⌃⌥R, tap semantics. Registered with Carbon `RegisterEventHotKey`, which
/// needs no Accessibility or Input Monitoring grant.
///
/// Two properties are load-bearing and were learned the hard way in the voice
/// suite:
/// 1. The handler MUST return `eventNotHandledErr` for any hot key that is not
///    ours. A second handler returning `noErr` for a foreign chord swallowed
///    ⌃⌥Space system-wide (voice bug #1).
/// 2. This is a PRESSED-only hot key. Carbon only delivers
///    `kEventHotKeyReleased` while the modifiers are still held, so a
///    tap-style action must fire on press and never wait for a release.
public final class RewriteHotKey {
    /// Fired on ⌃⌥R press, on the main queue.
    public var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x4D52_5754 // 'MRWT'
    private static let identifier: UInt32 = 1

    public init() {}

    public func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr,
                      hotKeyID.signature == RewriteHotKey.signature,
                      hotKeyID.id == RewriteHotKey.identifier else {
                    // Not ours. Returning noErr here would swallow another
                    // app's shortcut system-wide.
                    return OSStatus(eventNotHandledErr)
                }
                let owner = Unmanaged<RewriteHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { owner.onPress?() }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef)
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    deinit { unregister() }
}
#endif
```

- [ ] **Step 2: Build**

Run: `if xcrun swift build > /tmp/b.log 2>&1; then echo PASS; else tail -40 /tmp/b.log; exit 1; fi`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/MustardKit/Rewrite/RewriteHotKey.swift
git commit -m "feat(rewrite): ⌃⌥R Carbon hot key that never swallows foreign chords"
```

---

### Task 13: The review card and its non-activating panel

**Files:**
- Create: `Sources/MustardKit/Views/RewriteCardView.swift`
- Create: `Sources/MustardKit/Views/RewriteCardPanel.swift`

Per the repo's testing rules, views are verified by build plus Leon's eye — no
unit tests. **Use `Theme.Palette` and `Theme.Fonts` throughout; never hardcode a
colour.** Read `Views/VoiceCapturePillView.swift` first and mirror how it is
presented — it is the closest existing surface.

- [ ] **Step 1: Implement `RewriteCardView.swift`**

The card is a pure function of `RewritePhase`:

- `.reading` / `.generating` → the intent chips plus a small progress indicator
- `.reviewing(review)` → intent chips (the active one accented), `review.rewritten`
  at `Theme.Fonts` body size, a collapsed `review.original` in secondary colour
  with a word-count delta, `review.changeNote`, and the key hints
  `return replace · esc discard · ⌃⌥R another take`
- `.reviewing` where `review.writeFailure != nil` → the same, plus the failure
  message and a Copy button
- `.refused(refusal)` → `refusal.message` alone, and for
  `.accessibilityPermissionMissing` an "Open Voice Setup" button
- `.idle` → renders nothing; the panel is ordered out

Keyboard handling belongs here, on the card, via `.onKeyPress`:
`.return` → `await coordinator.accept()`, `.escape` → `coordinator.discard()`,
digits 1–4 → `await coordinator.change(intent:)` through
`RewriteIntent(shortcutDigit:)`.

- [ ] **Step 2: Implement `RewriteCardPanel.swift`**

```swift
#if os(macOS)
import AppKit
import SwiftUI

/// Hosts the review card. Non-activating and key-capable at the same time:
/// the panel must take keystrokes (return / esc / 1–4) WITHOUT bringing
/// Mustard forward, because activating the app is what dragged the whole
/// window stack forward in voice bug #7 — and here it would also disturb the
/// very selection being rewritten.
///
/// `NSApp.activate` must never be called on this path.
public final class RewriteCardPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// Required: a borderless panel returns false by default, and the card
    /// would never receive return / esc.
    public override var canBecomeKey: Bool { true }
    /// Must stay false — becoming main is what activates the application.
    public override var canBecomeMain: Bool { false }
}
#endif
```

- [ ] **Step 3: Build**

Run: `if xcrun swift build > /tmp/b.log 2>&1; then echo PASS; else tail -40 /tmp/b.log; exit 1; fi`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/MustardKit/Views/RewriteCardView.swift Sources/MustardKit/Views/RewriteCardPanel.swift
git commit -m "feat(rewrite): review card in a key-capable, non-activating panel"
```

---

### Task 14: Wire into the app, build it, and run the cross-app matrix

**Files:**
- Modify: `Sources/Mustard/MustardApp.swift`
- Modify: `build-app.sh` (Info.plist — see step 2)
- Create: `docs/rewrite-acceptance-checklist.md`

- [ ] **Step 1: Own the coordinator and hot key in `MustardApp`**

Mirror how `VoiceCaptureController` is owned.

First add the two helpers the coordinator needs, in
`Sources/MustardKit/Rewrite/RewriteWiring.swift`. They exist so `MustardApp`
stays thin and so neither one is an inline closure nobody can test later:

```swift
#if os(macOS)
import ApplicationServices
import Foundation

/// Live suppliers for the coordinator's two remaining edges.
public enum RewriteWiring {

    /// The focused element's AX role, read independently of dictation's
    /// narrower `textualRoles` gate. `AccessibilityFocusReader.snapshot()`
    /// throws `noFocusedTextElement` for anything outside that set, which
    /// would block rewrite in exactly the web areas it exists for — so the
    /// role is read directly here and judged by `RewriteRoles`.
    public static func focusedRole() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// The band-appropriate instruction text, loaded once. Falls back to the
    /// base band's resource, and finally to a minimal built-in string so a
    /// missing resource degrades instead of crashing.
    public static func bandInstructions(bundle: Bundle = .module) -> String {
        let band = PromptCatalog.currentBand
        guard let name = PromptCatalog.bestResource(
                feature: RewritePrompt.feature, band: band,
                isAvailable: { bundle.url(forResource: $0, withExtension: "txt") != nil }),
              let url = bundle.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Rewrite the text. Preserve meaning exactly. Return only the rewritten text."
        }
        return text
    }
}
#endif
```

Then build the live coordinator from the live adapters:

```swift
let selectionReader = AccessibilitySelectionReader.live()
let focusReader = AccessibilityFocusReader.live()
let restorer = SelectionRestorer.live(reader: focusReader)
let inserter = TextInserter.live(reader: focusReader)
let language = OnDeviceLanguageService.live()

// Loaded once: the prompt text does not change while the app runs.
let instructions = RewriteWiring.bandInstructions()

let rewrite = RewriteCoordinator(
    snapshotFocus: { try? focusReader.snapshot() },
    focusedRole: { RewriteWiring.focusedRole() },
    hasAccessibility: { AXIsProcessTrusted() },
    applicationName: { pid in
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "that app"
    },
    maxWords: { RewriteBudget.maxWords(contextSize: SystemLanguageModel.default.contextSize) },
    bandInstructions: { instructions },
    readSelection: { await selectionReader.read($0) },
    generate: { selection, intent in
        try await language.generate(
            RewriteDraft.self,
            instructions: RewritePrompt.instructions(
                intent: intent, bandInstructions: instructions, styleRules: []),
            prompt: RewritePrompt.prompt(selection: selection))
    },
    reassertSelection: { restorer.reassert(on: $0) },
    writeBack: { text, target in await inserter.insert(text, into: target) })
```

**One known wrinkle to resolve here, not to paper over.**
`focusReader.snapshot()` throws `FocusReadError.noFocusedTextElement` for any
role outside dictation's narrower `textualRoles` — which includes `AXWebArea`,
so as written it will refuse rewrite in Gmail and Slack, the two targets that
matter most.

Fix it by adding a `roles:` parameter to `AccessibilityFocusReader.snapshot`
that **defaults to `textualRoles`**, so every existing dictation call site is
unchanged, and passing `RewriteRoles.textual` from rewrite:

```swift
    public func snapshot(roles: Set<String> = Self.textualRoles) throws -> FocusedTextTarget {
        guard isTrusted() else { throw FocusReadError.accessibilityPermissionMissing }
        guard let probe = try probe(),
              let role = probe.role, roles.contains(role) else {
            throw FocusReadError.noFocusedTextElement
        }
        // …rest of the body unchanged…
    }
```

Then the coordinator's `snapshotFocus` becomes:

```swift
    snapshotFocus: { try? focusReader.snapshot(roles: RewriteRoles.textual) },
```

This is a defaulted parameter, not a widened shared set — dictation's behaviour
is byte-for-byte identical. Confirm that by running the full suite; every
pre-existing dictation test must pass untouched.

Register the hot key on launch and route it:

```swift
rewriteHotKey.onPress = { Task { await rewrite.invoke(intent: .default) } }
rewriteHotKey.register()
```

- [ ] **Step 2: Confirm the Info.plist needs nothing new**

Rewrite adds no new TCC-protected capability: the Accessibility grant is already
requested by dictation, and Foundation Models needs no usage string. Verify no
new key is required and leave `build-app.sh` unchanged if so.

- [ ] **Step 3: Build the app and the suite**

```bash
export DEVELOPER_DIR="/Users/leoncreed-baker/Downloads/Xcode-beta.app/Contents/Developer"
if xcrun swift build > /tmp/b.log 2>&1 && xcrun swift test > /tmp/t.log 2>&1 && ./build-app.sh > /tmp/a.log 2>&1; then echo PASS; else tail -60 /tmp/b.log /tmp/t.log /tmp/a.log; exit 1; fi
```

Expected: PASS, and `build/Mustard.app` exists. A fresh worktree has no
`build/` — run `./build-app.sh` before asking Leon to test anything, and again
after every change, or he will test a stale binary.

- [ ] **Step 4: Write `docs/rewrite-acceptance-checklist.md`**

A table Leon fills in, one row per target, with these columns: target app ·
focused role/subrole · which read rung won · which write path won · did the
selection survive the card · notes. Rows to include:

| Target | What it proves |
|---|---|
| Mustard notes editor | The prompt and card, independent of AX |
| Notes.app or Mail | Native Cocoa: rungs 1/2 and the direct write |
| Gmail in Chrome | Chromium web area: expected rung 3 plus paste |
| Slack | Electron, which reports AX writes as successful while discarding them |
| Linear in a browser | A second web-area data point |
| Xcode | A non-trivial native text view |
| Any password field | **Must refuse.** Non-negotiable. |

Include the log predicate at the top of the file so each run is traceable:

```bash
log stream --predicate 'subsystem == "com.cavehole.mustard" AND category == "rewrite"'
```

- [ ] **Step 5: Commit**

```bash
git add Sources/Mustard/MustardApp.swift docs/rewrite-acceptance-checklist.md
git commit -m "feat(rewrite): wire ⌃⌥R into the app, with the cross-app acceptance checklist"
```

- [ ] **Step 6: Hand to Leon for the matrix**

State plainly that the suite passes and the app builds and launches, that the
in-app path was exercised, and that **the foreign-app behaviour is unverified
until the matrix is filled in**. Do not claim any app works from inspection —
the voice suite found eight bugs that existed only on real hardware, and every
one was in this layer.

---

## Deferred to phase 2 and 3 — do not build now

Named here so nobody "helpfully" adds them mid-plan. Each needs its own spec.

- **Voice profile (phase 2).** Enters through `RewritePrompt.styleRules`, which
  already exists with an empty default for exactly this reason.
- **Live Mustard context (phase 3).** Frontmost app → client area → related task.
- **In-app `NSTextView` reader.** The plan's Task 14 wiring uses the AX path for
  everything. A native `SelectionReading` conformance for Mustard's own editor is
  a small follow-up; it is called out in the spec as the non-AX bisect path and
  should be added if the matrix proves messy.

## Self-review notes

Spec coverage checked section by section:

| Spec section | Task |
|---|---|
| Prerequisite / branch from #101 | Before you write any code |
| Four intents | 1 |
| Own role policy | 2 |
| Typed refusals; budget refusal not truncation | 3 |
| Three-rung ladder; unreadable ≠ empty | 4, 7, 8 |
| Gate split around the read | 5, 10 |
| Guided generation; band prompts | 6 |
| Re-assert range before write | 9, 10 |
| Card, accept-to-write, failure keeps original | 10, 13 |
| Non-activating panel; no `NSApp.activate` | 13 |
| ⌃⌥R tap, `eventNotHandledErr` | 12 |
| `os_log` from the first commit | 11 |
| Cross-app matrix, Leon-gated | 14 |
| Verify by exit code; DEVELOPER_DIR | Before you write any code, and every step |
