# Settings Consolidation + Customizable Hotkeys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Settings home (the existing in-app `SettingsView`) that owns all agent/source/calendar config, a bare triage-only Agent console, and a key-recorder UI that customizes all eight hotkeys (3 global Carbon, 5 in-app SwiftUI) with live apply.

**Architecture:** Pure decision units in `Sources/MustardKit/Logic/` (key tables, bindings registry, validation, conflicts, recorder event mapping) per the repo's separation rule; a thin `@Observable HotKeyBindingsStore` bridges them to SwiftUI; Carbon hotkeys gain `rebind()`; views only render and dispatch. Spec: `docs/superpowers/specs/2026-08-12-settings-hotkey-customization-design.md`.

**Tech Stack:** Swift 6.2 SPM package, SwiftUI, XCTest (`swift test`), Carbon `RegisterEventHotKey` (existing), `NSEvent.addLocalMonitorForEvents` (recorder only).

**Verification commands (every task):** `swift test --filter <Suite>` during TDD; each task ends with `swift build` green and a commit. Judge success by **exit code**, never by grepping output.

**Key constants used throughout** (Carbon, Events.h): modifier masks ctrl `0x1000`, opt `0x800`, shift `0x200`, cmd `0x100`; key codes Space 49, D 2, R 15, H 4, N 45, K 40, S 1, F 3, Esc 53, Delete(⌫) 51.

---

### Task 1: `HotKeyKeyMap` — key-code tables (Logic, TDD)

**Files:**
- Create: `Sources/MustardKit/Logic/HotKeyKeyMap.swift`
- Test: `Tests/MustardTests/HotKeyKeyMapTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import SwiftUI
import XCTest

@testable import MustardKit

/// Key-code tables for the hotkey settings surface: display names, SwiftUI
/// KeyEquivalent bridging, and Carbon↔EventModifiers mapping.
final class HotKeyKeyMapTests: XCTestCase {
    func test_displayName_coversLettersDigitsAndSpecials() {
        XCTAssertEqual(HotKeyKeyMap.displayName(forKeyCode: 4), "H")
        XCTAssertEqual(HotKeyKeyMap.displayName(forKeyCode: 49), "Space")
        XCTAssertEqual(HotKeyKeyMap.displayName(forKeyCode: 18), "1")
        XCTAssertEqual(HotKeyKeyMap.displayName(forKeyCode: 126), "↑")
        XCTAssertEqual(HotKeyKeyMap.displayName(forKeyCode: 122), "F1")
        XCTAssertNil(HotKeyKeyMap.displayName(forKeyCode: 999))
    }

    func test_keyEquivalentCharacter_lettersAreLowercase_spaceIsSpace() {
        XCTAssertEqual(HotKeyKeyMap.keyEquivalentCharacter(forKeyCode: 4), "h")
        XCTAssertEqual(HotKeyKeyMap.keyEquivalentCharacter(forKeyCode: 49), " ")
        XCTAssertEqual(HotKeyKeyMap.keyEquivalentCharacter(forKeyCode: 126), "\u{F700}")
    }

    func test_keyEquivalentCharacter_functionKeysAreNotMappable() {
        // SwiftUI KeyEquivalent has no F-key story we want to rely on; the
        // recorder rejects these for in-app actions.
        XCTAssertNil(HotKeyKeyMap.keyEquivalentCharacter(forKeyCode: 122))
        XCTAssertNil(HotKeyKeyMap.keyEquivalentCharacter(forKeyCode: 115))
    }

    func test_eventModifiers_mapsAllFourCarbonMasks() {
        XCTAssertEqual(
            HotKeyKeyMap.eventModifiers(fromCarbon: 0x1000 | 0x800),
            [.control, .option])
        XCTAssertEqual(
            HotKeyKeyMap.eventModifiers(fromCarbon: 0x100 | 0x200),
            [.command, .shift])
        XCTAssertEqual(HotKeyKeyMap.eventModifiers(fromCarbon: 0), [])
    }

    func test_keyboardShortcut_mappableChord_buildsShortcut() {
        let shortcut = HotKeyKeyMap.keyboardShortcut(keyCode: 40, carbonModifiers: 0x100)
        XCTAssertEqual(shortcut, KeyboardShortcut(KeyEquivalent("k"), modifiers: .command))
    }

    func test_keyboardShortcut_unmappableKey_isNil() {
        XCTAssertNil(HotKeyKeyMap.keyboardShortcut(keyCode: 122, carbonModifiers: 0x100))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HotKeyKeyMapTests`
Expected: build FAILS with "cannot find 'HotKeyKeyMap' in scope"

- [ ] **Step 3: Write the implementation**

```swift
import SwiftUI

/// Pure key-code tables shared by the chord formatter, the hotkey recorder,
/// and the SwiftUI shortcut bridge. Carbon virtual key codes (Events.h) in;
/// display names / KeyEquivalent characters out.
public enum HotKeyKeyMap {
    /// Readable key name for the settings surface. Covers every key the
    /// recorder accepts; callers keep their own fallback for the rest.
    public static func displayName(forKeyCode keyCode: UInt32) -> String? {
        names[keyCode]
    }

    /// The Character SwiftUI's `KeyEquivalent` understands, for in-app
    /// shortcuts. Nil for keys SwiftUI can't express (F-keys, Home, …) —
    /// the recorder rejects those for in-app actions. Global Carbon chords
    /// take any key code and never consult this.
    public static func keyEquivalentCharacter(forKeyCode keyCode: UInt32) -> Character? {
        keyEquivalents[keyCode]
    }

    /// Carbon modifier masks → SwiftUI `EventModifiers` (⌃⌥⇧⌘ only).
    public static func eventModifiers(fromCarbon modifiers: UInt32) -> EventModifiers {
        var result: EventModifiers = []
        if modifiers & 0x1000 != 0 { result.insert(.control) }
        if modifiers & 0x0800 != 0 { result.insert(.option) }
        if modifiers & 0x0200 != 0 { result.insert(.shift) }
        if modifiers & 0x0100 != 0 { result.insert(.command) }
        return result
    }

    /// The SwiftUI shortcut for an in-app chord, or nil when the key has no
    /// KeyEquivalent representation.
    public static func keyboardShortcut(keyCode: UInt32, carbonModifiers: UInt32) -> KeyboardShortcut? {
        guard let char = keyEquivalentCharacter(forKeyCode: keyCode) else { return nil }
        return KeyboardShortcut(KeyEquivalent(char), modifiers: eventModifiers(fromCarbon: carbonModifiers))
    }

    private static let names: [UInt32: String] = [
        // Letters (kVK_ANSI_*)
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
        15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        // Digit row
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9",
        // Punctuation
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",",
        44: "/", 47: ".", 50: "`",
        // Whitespace / editing / navigation
        49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        // Function row
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Arrow characters are the AppKit function-key scalars KeyEquivalent's
    /// .upArrow/.downArrow/.leftArrow/.rightArrow wrap (NSUpArrowFunctionKey…).
    private static let keyEquivalents: [UInt32: Character] = [
        0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i",
        38: "j", 40: "k", 37: "l", 46: "m", 45: "n", 31: "o", 35: "p", 12: "q",
        15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w", 7: "x", 16: "y", 6: "z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",",
        44: "/", 47: ".", 50: "`",
        49: " ", 36: "\r", 48: "\t",
        123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}",
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HotKeyKeyMapTests`
Expected: PASS (6 tests), exit 0

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/HotKeyKeyMap.swift Tests/MustardTests/HotKeyKeyMapTests.swift
git commit -m "feat(hotkeys): key-code tables for display names and KeyEquivalent bridging

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `HotKeyChord` becomes a value type with full key names

**Files:**
- Modify: `Sources/MustardKit/Capture/PushToTalkHotKey.swift:90-104` (the `HotKeyChord` enum)
- Test: `Tests/MustardTests/HotKeyChordTests.swift`

The existing `enum HotKeyChord` (formatter only) becomes a struct carrying
`keyCode` + `carbonModifiers`, keeping the `static func description(keyCode:modifiers:)`
so all existing call sites (`PushToTalkHotKey.register`, `RewriteHotKey.register`)
compile unchanged. Key names now come from `HotKeyKeyMap`.

- [ ] **Step 1: Extend the test file (keep the two passing tests, replace the fallback test — key code 97 is now F6)**

Replace the whole of `Tests/MustardTests/HotKeyChordTests.swift` with:

```swift
import XCTest

@testable import MustardKit

/// Chord formatting for the settings surface (review fix: conflicts must be
/// shown with the failed shortcut, so the shortcut must render readably).
final class HotKeyChordTests: XCTestCase {
    func test_captureChord_rendersControlOptionSpace() {
        XCTAssertEqual(HotKeyChord.description(keyCode: 49, modifiers: 0x1000 | 0x800), "⌃⌥Space")
    }

    func test_dictationChord_rendersControlOptionD() {
        XCTAssertEqual(HotKeyChord.description(keyCode: 2, modifiers: 0x1000 | 0x800), "⌃⌥D")
    }

    func test_fullKeyTable_rendersLettersArrowsAndFKeys() {
        XCTAssertEqual(HotKeyChord.description(keyCode: 4, modifiers: 0x100 | 0x200), "⇧⌘H")
        XCTAssertEqual(HotKeyChord.description(keyCode: 126, modifiers: 0x100), "⌘↑")
        XCTAssertEqual(HotKeyChord.description(keyCode: 122, modifiers: 0x1000), "⌃F1")
    }

    func test_unknownKeyCode_fallsBackReadably() {
        XCTAssertEqual(HotKeyChord.description(keyCode: 999, modifiers: 0x100), "⌘key #999")
    }

    func test_chordValue_describesItself_andIsEquatable() {
        let chord = HotKeyChord(keyCode: 49, carbonModifiers: 0x1800)
        XCTAssertEqual(chord.description, "⌃⌥Space")
        XCTAssertEqual(chord, HotKeyChord(keyCode: 49, carbonModifiers: 0x1800))
        XCTAssertNotEqual(chord, HotKeyChord(keyCode: 49, carbonModifiers: 0x100))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HotKeyChordTests`
Expected: build FAILS ("'HotKeyChord' cannot be constructed" / no `init(keyCode:carbonModifiers:)`)

- [ ] **Step 3: Replace the enum in `PushToTalkHotKey.swift`**

Replace lines 90–104 (the `/// Pure chord formatting…` comment + `enum HotKeyChord`) with:

```swift
/// One hotkey chord as raw Carbon values (platform-free, so the formatter and
/// the bindings registry stay unit-testable): "⌃⌥Space", "⌃⌥D", …
public struct HotKeyChord: Hashable, Codable, Sendable, CustomStringConvertible {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Carbon modifier masks (Events.h): cmdKey/shiftKey/optionKey/controlKey.
    private static let masks: [(UInt32, String)] = [
        (0x1000, "⌃"), (0x800, "⌥"), (0x200, "⇧"), (0x100, "⌘"),
    ]

    public var description: String {
        Self.description(keyCode: keyCode, modifiers: carbonModifiers)
    }

    public static func description(keyCode: UInt32, modifiers: UInt32) -> String {
        let mods = masks.filter { modifiers & $0.0 != 0 }.map(\.1).joined()
        return mods + (HotKeyKeyMap.displayName(forKeyCode: keyCode) ?? "key #\(keyCode)")
    }
}
```

- [ ] **Step 4: Run tests — chord suite, then the whole build**

Run: `swift test --filter HotKeyChordTests` → PASS (5 tests)
Run: `swift build` → exit 0 (confirms all existing `HotKeyChord.description(…)` call sites still compile)

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Capture/PushToTalkHotKey.swift Tests/MustardTests/HotKeyChordTests.swift
git commit -m "feat(hotkeys): HotKeyChord value type with the full key-name table

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `HotKeyAction` registry + `HotKeyBindings` + validation + conflicts (Logic, TDD)

**Files:**
- Create: `Sources/MustardKit/Logic/HotKeyBindings.swift`
- Test: `Tests/MustardTests/HotKeyBindingsTests.swift`
- Test: `Tests/MustardTests/HotKeyConflictTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/MustardTests/HotKeyBindingsTests.swift`:

```swift
import XCTest

@testable import MustardKit

/// The eight-action bindings registry (BoardSettings pattern): defaults,
/// round-trip, legacy-key compatibility, resets, malformed fallback.
final class HotKeyBindingsTests: XCTestCase {
    private func makeStore() -> UserDefaults {
        UserDefaults(suiteName: "test.hotkeys.\(UUID().uuidString)")!
    }

    func test_defaults_matchShippedChords() {
        let bindings = HotKeyBindings(store: makeStore())
        XCTAssertEqual(bindings.chord(for: .pushToTalk), HotKeyChord(keyCode: 49, carbonModifiers: 0x1800))
        XCTAssertEqual(bindings.chord(for: .dictation), HotKeyChord(keyCode: 2, carbonModifiers: 0x1800))
        XCTAssertEqual(bindings.chord(for: .rewrite), HotKeyChord(keyCode: 15, carbonModifiers: 0x1800))
        XCTAssertEqual(bindings.chord(for: .hover), HotKeyChord(keyCode: 4, carbonModifiers: 0x300))
        XCTAssertEqual(bindings.chord(for: .notch), HotKeyChord(keyCode: 45, carbonModifiers: 0x300))
        XCTAssertEqual(bindings.chord(for: .commandBar), HotKeyChord(keyCode: 40, carbonModifiers: 0x100))
        XCTAssertEqual(bindings.chord(for: .sourceInspector), HotKeyChord(keyCode: 1, carbonModifiers: 0x300))
        XCTAssertEqual(bindings.chord(for: .noteSearch), HotKeyChord(keyCode: 3, carbonModifiers: 0x300))
    }

    func test_globalActions_useTheHistoricUserDefaultsKeys() {
        // These keys predate this feature (PushToTalkHotKey/RewriteHotKey read
        // them at init) — a rename would orphan existing manual overrides.
        XCTAssertEqual(HotKeyAction.pushToTalk.codeKey, "voiceHotKeyCode")
        XCTAssertEqual(HotKeyAction.pushToTalk.modifiersKey, "voiceHotKeyModifiers")
        XCTAssertEqual(HotKeyAction.dictation.codeKey, "dictationHotKeyCode")
        XCTAssertEqual(HotKeyAction.rewrite.codeKey, "rewriteHotKeyCode")
        XCTAssertEqual(HotKeyAction.hover.codeKey, "hotkey.hover.code")
    }

    func test_roundTrip_persistsAsIntPair() {
        let store = makeStore()
        let bindings = HotKeyBindings(store: store)
        bindings.set(HotKeyChord(keyCode: 11, carbonModifiers: 0x1100), for: .commandBar)
        XCTAssertEqual(bindings.chord(for: .commandBar), HotKeyChord(keyCode: 11, carbonModifiers: 0x1100))
        // Stored in the exact shape the Carbon hotkey inits read (as? Int).
        XCTAssertEqual(store.object(forKey: "hotkey.commandBar.code") as? Int, 11)
        XCTAssertEqual(store.object(forKey: "hotkey.commandBar.modifiers") as? Int, 0x1100)
    }

    func test_preexistingLegacyOverride_isHonored() {
        let store = makeStore()
        store.set(3, forKey: "voiceHotKeyCode")
        store.set(0x1800, forKey: "voiceHotKeyModifiers")
        XCTAssertEqual(
            HotKeyBindings(store: store).chord(for: .pushToTalk),
            HotKeyChord(keyCode: 3, carbonModifiers: 0x1800))
    }

    func test_malformed_onlyOneKeyPresent_fallsBackToDefault() {
        let store = makeStore()
        store.set(3, forKey: "voiceHotKeyCode")  // modifiers key missing
        XCTAssertEqual(
            HotKeyBindings(store: store).chord(for: .pushToTalk),
            HotKeyAction.pushToTalk.defaultChord)
    }

    func test_reset_removesOverride_resetAllClearsEverything() {
        let store = makeStore()
        let bindings = HotKeyBindings(store: store)
        bindings.set(HotKeyChord(keyCode: 11, carbonModifiers: 0x1100), for: .hover)
        bindings.reset(.hover)
        XCTAssertEqual(bindings.chord(for: .hover), HotKeyAction.hover.defaultChord)
        XCTAssertNil(store.object(forKey: "hotkey.hover.code"))

        bindings.set(HotKeyChord(keyCode: 11, carbonModifiers: 0x1100), for: .notch)
        bindings.set(HotKeyChord(keyCode: 12, carbonModifiers: 0x1100), for: .rewrite)
        bindings.resetAll()
        XCTAssertEqual(bindings.chord(for: .notch), HotKeyAction.notch.defaultChord)
        XCTAssertEqual(bindings.chord(for: .rewrite), HotKeyAction.rewrite.defaultChord)
    }

    func test_validation_requiresARealModifier() {
        // No modifier at all, and shift-only, both reject: the chord would
        // fire while typing.
        XCTAssertEqual(
            HotKeyValidation.validate(HotKeyChord(keyCode: 4, carbonModifiers: 0), scope: .inApp),
            .needsModifier)
        XCTAssertEqual(
            HotKeyValidation.validate(HotKeyChord(keyCode: 4, carbonModifiers: 0x200), scope: .global),
            .needsModifier)
        XCTAssertNil(
            HotKeyValidation.validate(HotKeyChord(keyCode: 4, carbonModifiers: 0x1000), scope: .global))
    }

    func test_validation_inAppRequiresMappableKey_globalDoesNot() {
        let f1Chord = HotKeyChord(keyCode: 122, carbonModifiers: 0x100)
        XCTAssertEqual(HotKeyValidation.validate(f1Chord, scope: .inApp), .keyNotSupportedInApp)
        XCTAssertNil(HotKeyValidation.validate(f1Chord, scope: .global))
    }
}
```

`Tests/MustardTests/HotKeyConflictTests.swift`:

```swift
import XCTest

@testable import MustardKit

/// Duplicate-chord detection across the whole registry — scope does not
/// matter (a global and an in-app action sharing a chord shadow each other).
final class HotKeyConflictTests: XCTestCase {
    private var defaults: [HotKeyAction: HotKeyChord] {
        Dictionary(uniqueKeysWithValues: HotKeyAction.allCases.map { ($0, $0.defaultChord) })
    }

    func test_uniqueChord_hasNoConflict() {
        XCTAssertNil(HotKeyConflicts.conflictingAction(
            with: HotKeyChord(keyCode: 11, carbonModifiers: 0x1800),
            for: .commandBar, chords: defaults))
    }

    func test_takingAnotherActionsChord_namesTheOwner() {
        // ⌘⇧H is hover's default — assigning it to the command bar conflicts.
        XCTAssertEqual(
            HotKeyConflicts.conflictingAction(
                with: HotKeyChord(keyCode: 4, carbonModifiers: 0x300),
                for: .commandBar, chords: defaults),
            .hover)
    }

    func test_crossScope_globalTakingInAppChord_conflicts() {
        XCTAssertEqual(
            HotKeyConflicts.conflictingAction(
                with: HotKeyChord(keyCode: 40, carbonModifiers: 0x100),
                for: .rewrite, chords: defaults),
            .commandBar)
    }

    func test_reassigningYourOwnChord_isNotAConflict() {
        XCTAssertNil(HotKeyConflicts.conflictingAction(
            with: HotKeyChord(keyCode: 4, carbonModifiers: 0x300),
            for: .hover, chords: defaults))
    }

    func test_defaultChords_haveNoDuplicatesAmongThemselves() {
        for action in HotKeyAction.allCases {
            XCTAssertNil(
                HotKeyConflicts.conflictingAction(
                    with: action.defaultChord, for: action, chords: defaults),
                "\(action) default collides")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HotKeyBindingsTests` → build FAILS ("cannot find 'HotKeyBindings'")

- [ ] **Step 3: Write the implementation**

`Sources/MustardKit/Logic/HotKeyBindings.swift`:

```swift
import Foundation

/// One customizable shortcut. The three global (Carbon) actions keep the
/// UserDefaults keys they have always had — `PushToTalkHotKey`/`RewriteHotKey`
/// read them at init — so pre-existing manual overrides survive this feature
/// with no migration. In-app actions get namespaced keys.
public enum HotKeyAction: String, CaseIterable, Identifiable, Sendable {
    case pushToTalk, dictation, rewrite
    case hover, notch, commandBar, sourceInspector, noteSearch

    public var id: String { rawValue }

    public enum Scope: Equatable, Sendable {
        /// Registered with Carbon; works anywhere on the Mac.
        case global
        /// A SwiftUI `.keyboardShortcut`; works while Mustard is frontmost.
        case inApp
    }

    public var scope: Scope {
        switch self {
        case .pushToTalk, .dictation, .rewrite: .global
        case .hover, .notch, .commandBar, .sourceInspector, .noteSearch: .inApp
        }
    }

    public var label: String {
        switch self {
        case .pushToTalk: "Push-to-talk capture"
        case .dictation: "System dictation"
        case .rewrite: "Rewrite selection"
        case .hover: "Hover panel"
        case .notch: "Notch"
        case .commandBar: "Command bar"
        case .sourceInspector: "Source inspector"
        case .noteSearch: "Note search"
        }
    }

    public var defaultChord: HotKeyChord {
        switch self {
        case .pushToTalk: HotKeyChord(keyCode: 49, carbonModifiers: 0x1800)  // ⌃⌥Space
        case .dictation: HotKeyChord(keyCode: 2, carbonModifiers: 0x1800)  // ⌃⌥D
        case .rewrite: HotKeyChord(keyCode: 15, carbonModifiers: 0x1800)  // ⌃⌥R
        case .hover: HotKeyChord(keyCode: 4, carbonModifiers: 0x300)  // ⌘⇧H
        case .notch: HotKeyChord(keyCode: 45, carbonModifiers: 0x300)  // ⌘⇧N
        case .commandBar: HotKeyChord(keyCode: 40, carbonModifiers: 0x100)  // ⌘K
        case .sourceInspector: HotKeyChord(keyCode: 1, carbonModifiers: 0x300)  // ⌘⇧S
        case .noteSearch: HotKeyChord(keyCode: 3, carbonModifiers: 0x300)  // ⌘⇧F
        }
    }

    public var codeKey: String {
        switch self {
        case .pushToTalk: "voiceHotKeyCode"
        case .dictation: "dictationHotKeyCode"
        case .rewrite: "rewriteHotKeyCode"
        default: "hotkey.\(rawValue).code"
        }
    }

    public var modifiersKey: String {
        switch self {
        case .pushToTalk: "voiceHotKeyModifiers"
        case .dictation: "dictationHotKeyModifiers"
        case .rewrite: "rewriteHotKeyModifiers"
        default: "hotkey.\(rawValue).modifiers"
        }
    }

    /// The `PushToTalkHotKey.registrationBoard` purpose key (global actions only).
    public var registrationPurpose: String? {
        switch self {
        case .pushToTalk: "Task capture"
        case .dictation: "Dictation"
        case .rewrite: "Rewrite"
        default: nil
        }
    }
}

/// Hotkey chords persisted per action (BoardSettings pattern: injected store).
/// Values are Int pairs — the exact shape the Carbon hotkey inits read.
public struct HotKeyBindings {
    private let store: UserDefaults
    public init(store: UserDefaults = .standard) { self.store = store }

    /// The stored chord, or the action's default when unset or malformed
    /// (one key present without the other, e.g. a hand-edited `defaults` write).
    public func chord(for action: HotKeyAction) -> HotKeyChord {
        guard let code = store.object(forKey: action.codeKey) as? Int,
            let modifiers = store.object(forKey: action.modifiersKey) as? Int
        else { return action.defaultChord }
        return HotKeyChord(keyCode: UInt32(code), carbonModifiers: UInt32(modifiers))
    }

    public func set(_ chord: HotKeyChord, for action: HotKeyAction) {
        store.set(Int(chord.keyCode), forKey: action.codeKey)
        store.set(Int(chord.carbonModifiers), forKey: action.modifiersKey)
    }

    public func reset(_ action: HotKeyAction) {
        store.removeObject(forKey: action.codeKey)
        store.removeObject(forKey: action.modifiersKey)
    }

    public func resetAll() {
        for action in HotKeyAction.allCases { reset(action) }
    }
}

public enum HotKeyValidationError: Equatable, Sendable {
    case needsModifier
    case keyNotSupportedInApp

    public var message: String {
        switch self {
        case .needsModifier: "Add ⌘, ⌃ or ⌥"
        case .keyNotSupportedInApp: "That key can't be an in-app shortcut"
        }
    }
}

public enum HotKeyValidation {
    /// Shift alone is not enough — an unmodified (or shift-only) key would
    /// fire while typing. In-app chords must also be expressible as a SwiftUI
    /// KeyEquivalent; global Carbon chords take any key code.
    public static func validate(_ chord: HotKeyChord, scope: HotKeyAction.Scope) -> HotKeyValidationError? {
        if chord.carbonModifiers & (0x1000 | 0x800 | 0x100) == 0 { return .needsModifier }
        if scope == .inApp, HotKeyKeyMap.keyEquivalentCharacter(forKeyCode: chord.keyCode) == nil {
            return .keyNotSupportedInApp
        }
        return nil
    }
}

public enum HotKeyConflicts {
    /// The action already holding `chord`, if any. Scope does not matter:
    /// a global and an in-app action sharing a chord would shadow each other.
    public static func conflictingAction(
        with chord: HotKeyChord, for action: HotKeyAction, chords: [HotKeyAction: HotKeyChord]
    ) -> HotKeyAction? {
        HotKeyAction.allCases.first { $0 != action && chords[$0] == chord }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter "HotKeyBindingsTests|HotKeyConflictTests"` → PASS (13 tests), exit 0

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/HotKeyBindings.swift Tests/MustardTests/HotKeyBindingsTests.swift Tests/MustardTests/HotKeyConflictTests.swift
git commit -m "feat(hotkeys): bindings registry with legacy-key compat, validation and conflicts

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: `HotKeyRecorderLogic` — recorder event mapping (Logic, TDD)

**Files:**
- Create: `Sources/MustardKit/Logic/HotKeyRecorderLogic.swift`
- Test: `Tests/MustardTests/HotKeyRecorderLogicTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

@testable import MustardKit

/// What a keyDown means while the recorder field is armed. Pure — the view
/// only installs/removes the NSEvent monitor.
final class HotKeyRecorderLogicTests: XCTestCase {
    // NSEvent.ModifierFlags raw bits: shift 1<<17, control 1<<18,
    // option 1<<19, command 1<<20.
    func test_flagMapping_coversAllFourModifiers() {
        XCTAssertEqual(
            HotKeyRecorderLogic.carbonModifiers(fromNSEventFlags: (1 << 18) | (1 << 19)),
            0x1800)
        XCTAssertEqual(
            HotKeyRecorderLogic.carbonModifiers(fromNSEventFlags: (1 << 20) | (1 << 17)),
            0x300)
        XCTAssertEqual(HotKeyRecorderLogic.carbonModifiers(fromNSEventFlags: 0), 0)
    }

    func test_flagMapping_ignoresCapsLockAndDeviceBits() {
        // Caps lock (1<<16) and device-dependent low bits must not leak in.
        XCTAssertEqual(
            HotKeyRecorderLogic.carbonModifiers(fromNSEventFlags: (1 << 16) | (1 << 20) | 0xFF),
            0x100)
    }

    func test_escape_cancels() {
        XCTAssertEqual(HotKeyRecorderLogic.outcome(keyCode: 53, nsEventFlags: 0), .cancel)
        // Even with modifiers held: Esc is always the way out.
        XCTAssertEqual(HotKeyRecorderLogic.outcome(keyCode: 53, nsEventFlags: 1 << 18), .cancel)
    }

    func test_delete_resetsToDefault() {
        XCTAssertEqual(HotKeyRecorderLogic.outcome(keyCode: 51, nsEventFlags: 0), .reset)
    }

    func test_anyOtherKey_isAChordAttempt() {
        XCTAssertEqual(
            HotKeyRecorderLogic.outcome(keyCode: 11, nsEventFlags: (1 << 18) | (1 << 19)),
            .capture(keyCode: 11, carbonModifiers: 0x1800))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HotKeyRecorderLogicTests` → build FAILS

- [ ] **Step 3: Write the implementation**

`Sources/MustardKit/Logic/HotKeyRecorderLogic.swift`:

```swift
import Foundation

/// What one keyDown means while a hotkey recorder field is armed.
public enum HotKeyRecorderOutcome: Equatable, Sendable {
    /// Esc — disarm, keep the old chord.
    case cancel
    /// ⌫ — restore the action's default chord.
    case reset
    /// A chord attempt (validation/conflict checks happen downstream).
    case capture(keyCode: UInt32, carbonModifiers: UInt32)
}

public enum HotKeyRecorderLogic {
    /// NSEvent.ModifierFlags raw bits → Carbon masks. Only ⌃⌥⇧⌘ carry over;
    /// caps lock and the device-dependent bits are dropped.
    public static func carbonModifiers(fromNSEventFlags raw: UInt) -> UInt32 {
        var mods: UInt32 = 0
        if raw & (1 << 18) != 0 { mods |= 0x1000 }  // control
        if raw & (1 << 19) != 0 { mods |= 0x0800 }  // option
        if raw & (1 << 17) != 0 { mods |= 0x0200 }  // shift
        if raw & (1 << 20) != 0 { mods |= 0x0100 }  // command
        return mods
    }

    /// Esc cancels and ⌫ resets regardless of modifiers — those are the
    /// recorder's own controls, so they can never be recorded as chords.
    public static func outcome(keyCode: UInt32, nsEventFlags raw: UInt) -> HotKeyRecorderOutcome {
        switch keyCode {
        case 53: .cancel
        case 51: .reset
        default: .capture(keyCode: keyCode, carbonModifiers: carbonModifiers(fromNSEventFlags: raw))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HotKeyRecorderLogicTests` → PASS (5 tests), exit 0

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Logic/HotKeyRecorderLogic.swift Tests/MustardTests/HotKeyRecorderLogicTests.swift
git commit -m "feat(hotkeys): pure recorder event mapping (Esc cancels, backspace resets)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Live `rebind()` on the Carbon hotkeys + rewrite joins the registration board

**Files:**
- Modify: `Sources/MustardKit/Capture/PushToTalkHotKey.swift` (`keyCode`/`modifiers` lets → vars; add `rebind`; add `post`)
- Modify: `Sources/MustardKit/Rewrite/RewriteHotKey.swift` (lets → vars; add `rebind`; post to the board)

No new unit tests — these methods are thin Carbon wiring around already-tested
pieces (`register()`/`unregister()`/`endHold()`); compile + the existing suite
guard them. Verified live in the final eye-check.

- [ ] **Step 1: In `PushToTalkHotKey`, make the chord mutable and add `rebind` + `post`**

Change lines 122–123:

```swift
    private(set) var keyCode: UInt32
    private(set) var modifiers: UInt32
```

Add below `unregister()` (after line 289):

```swift
    /// Swap the chord live (Settings → Hotkeys). Any active hold is ended
    /// through the normal release path FIRST — `unregister()` alone would
    /// clear `isHolding` without firing `onRelease`, stranding a capture with
    /// a live microphone. Then the new chord is claimed and the board updated.
    @discardableResult
    public func rebind(keyCode: UInt32, modifiers: UInt32) -> HotKeyRegistration {
        endHold()
        unregister()
        self.keyCode = keyCode
        self.modifiers = modifiers
        return register()
    }

    /// Post a registration outcome for a chord owned by another hotkey class
    /// (rewrite) so every chord's fate is visible on the one board.
    static func post(purpose: String, chord: String, registration: HotKeyRegistration) {
        registrationBoard[purpose] = (chord: chord, registration: registration)
    }
```

- [ ] **Step 2: In `RewriteHotKey`, make the chord mutable, add `rebind`, and post to the board**

Change lines 33–34:

```swift
    private(set) var keyCode: UInt32
    private(set) var modifiers: UInt32
```

In `register()`, directly after `registration = result` (line 95), add:

```swift
        // Rewrite's conflict used to be invisible (only logged) — post to the
        // shared board so Voice Setup and Settings → Hotkeys can render it.
        PushToTalkHotKey.post(
            purpose: "Rewrite",
            chord: HotKeyChord.description(keyCode: keyCode, modifiers: modifiers),
            registration: result)
```

Add below `unregister()`:

```swift
    /// Swap the chord live (Settings → Hotkeys). Tap semantics — no hold to
    /// unwind, unlike `PushToTalkHotKey.rebind`.
    @discardableResult
    public func rebind(keyCode: UInt32, modifiers: UInt32) -> HotKeyRegistration {
        unregister()
        self.keyCode = keyCode
        self.modifiers = modifiers
        return register()
    }
```

- [ ] **Step 3: Build and run the full suite**

Run: `swift build` → exit 0; `swift test` → exit 0 (no regressions)

- [ ] **Step 4: Commit**

```bash
git add Sources/MustardKit/Capture/PushToTalkHotKey.swift Sources/MustardKit/Rewrite/RewriteHotKey.swift
git commit -m "feat(hotkeys): live rebind on the Carbon hotkeys; rewrite posts to the registration board

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Coordinator rebind plumbing (seam + three coordinators)

**Files:**
- Modify: `Sources/MustardKit/Capture/VoiceTaskCaptureCoordinator.swift:113-134` (HotKeySeam) and near `activate()` (~line 261)
- Modify: `Sources/MustardKit/Dictation/SystemDictationCoordinator.swift` (near `activate()`, ~line 108)
- Modify: `Sources/MustardKit/Rewrite/RewriteController.swift` (near `registration`, ~line 26)
- Test: `Tests/MustardTests/VoiceTaskCaptureCoordinatorTests.swift` (add one test)

- [ ] **Step 1: Add a failing test — rebind routes through the seam and updates the published registration**

Open `Tests/MustardTests/VoiceTaskCaptureCoordinatorTests.swift`, find how the
existing tests construct a coordinator with a stub `HotKeySeam` (they pass
`register:`/`bind:` closures), and add one test following that exact
construction pattern:

```swift
    @MainActor
    func test_rebindHotKey_routesThroughSeam_andUpdatesRegistration() {
        var rebound: (keyCode: UInt32, modifiers: UInt32)?
        // Build the coordinator exactly like the neighboring tests, but with
        // a seam whose rebind records its arguments and reports a conflict.
        let seam = VoiceTaskCaptureCoordinator.HotKeySeam(
            register: { .registered },
            bind: { _, _ in },
            rebind: { keyCode, modifiers in
                rebound = (keyCode, modifiers)
                return .conflict(-9878)
            })
        let coordinator = makeCoordinator(hotKey: seam)  // ← use the file's existing factory/helper; adapt its name
        let result = coordinator.rebindHotKey(keyCode: 11, modifiers: 0x1800)
        XCTAssertEqual(rebound?.keyCode, 11)
        XCTAssertEqual(rebound?.modifiers, 0x1800)
        XCTAssertEqual(result, .conflict(-9878))
        XCTAssertEqual(coordinator.hotKeyRegistration, .conflict(-9878))
    }
```

(If the file has no shared factory, construct the coordinator inline the way
its shortest test does — the point is the seam stub, not the other seams.)

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter VoiceTaskCaptureCoordinatorTests` → build FAILS (no `rebind` in seam)

- [ ] **Step 3: Implement**

In `VoiceTaskCaptureCoordinator.HotKeySeam`, add the field with a defaulted
init parameter (so every existing test call site keeps compiling), and wire
`.live`:

```swift
    /// The hotkey seam: registration result + press/release binding + live rebind.
    public struct HotKeySeam {
        public var register: @MainActor () -> HotKeyRegistration
        public var bind: @MainActor (_ onPress: @escaping () -> Void, _ onRelease: @escaping () -> Void) -> Void
        public var rebind: @MainActor (_ keyCode: UInt32, _ modifiers: UInt32) -> HotKeyRegistration

        public init(
            register: @escaping @MainActor () -> HotKeyRegistration,
            bind: @escaping @MainActor (_ onPress: @escaping () -> Void, _ onRelease: @escaping () -> Void) -> Void,
            rebind: @escaping @MainActor (_ keyCode: UInt32, _ modifiers: UInt32) -> HotKeyRegistration = { _, _ in .registered }
        ) {
            self.register = register
            self.bind = bind
            self.rebind = rebind
        }

        @MainActor
        public static func live(_ hotKey: PushToTalkHotKey) -> HotKeySeam {
            HotKeySeam(
                register: { hotKey.register() },
                bind: { onPress, onRelease in
                    hotKey.onPress = onPress
                    hotKey.onRelease = onRelease
                },
                rebind: { keyCode, modifiers in
                    hotKey.rebind(keyCode: keyCode, modifiers: modifiers)
                })
        }
    }
```

Below `activate()` in the same class, add:

```swift
    /// Swap the push-to-talk chord live (Settings → Hotkeys).
    @discardableResult
    public func rebindHotKey(keyCode: UInt32, modifiers: UInt32) -> HotKeyRegistration {
        let registration = hotKey.rebind(keyCode, modifiers)
        hotKeyRegistration = registration
        return registration
    }
```

Below `activate()` in `SystemDictationCoordinator` (same seam type), add the
identical method:

```swift
    /// Swap the dictation chord live (Settings → Hotkeys).
    @discardableResult
    public func rebindHotKey(keyCode: UInt32, modifiers: UInt32) -> HotKeyRegistration {
        let registration = hotKey.rebind(keyCode, modifiers)
        hotKeyRegistration = registration
        return registration
    }
```

In `RewriteController` (below the `registration` computed property):

```swift
    /// Swap the rewrite chord live (Settings → Hotkeys).
    @discardableResult
    public func rebindHotKey(keyCode: UInt32, modifiers: UInt32) -> HotKeyRegistration {
        hotKey.rebind(keyCode: keyCode, modifiers: modifiers)
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter VoiceTaskCaptureCoordinatorTests` → PASS; then `swift build` → exit 0

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Capture/VoiceTaskCaptureCoordinator.swift Sources/MustardKit/Dictation/SystemDictationCoordinator.swift Sources/MustardKit/Rewrite/RewriteController.swift Tests/MustardTests/VoiceTaskCaptureCoordinatorTests.swift
git commit -m "feat(hotkeys): rebind plumbing through the hotkey seam and all three coordinators

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: `HotKeyBindingsStore` — the observable bridge (TDD)

**Files:**
- Create: `Sources/MustardKit/Views/HotKeyBindingsStore.swift`
- Test: `Tests/MustardTests/HotKeyBindingsStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

@testable import MustardKit

/// The @Observable bridge between the pure bindings registry and SwiftUI:
/// attempted writes validate + conflict-check, global writes route through
/// the injected applier, resets restore defaults.
@MainActor
final class HotKeyBindingsStoreTests: XCTestCase {
    private func makeStore() -> UserDefaults {
        UserDefaults(suiteName: "test.hotkeys.store.\(UUID().uuidString)")!
    }

    func test_attemptSet_valid_savesPersistsAndPublishes() {
        let defaults = makeStore()
        let store = HotKeyBindingsStore(store: defaults)
        let chord = HotKeyChord(keyCode: 11, carbonModifiers: 0x1800)
        XCTAssertEqual(store.attemptSet(chord, for: .commandBar), .saved)
        XCTAssertEqual(store.chord(for: .commandBar), chord)
        XCTAssertEqual(HotKeyBindings(store: defaults).chord(for: .commandBar), chord)
    }

    func test_attemptSet_noModifier_rejectsAndKeepsOldChord() {
        let store = HotKeyBindingsStore(store: makeStore())
        let outcome = store.attemptSet(HotKeyChord(keyCode: 11, carbonModifiers: 0), for: .commandBar)
        XCTAssertEqual(outcome, .rejected("Add ⌘, ⌃ or ⌥"))
        XCTAssertEqual(store.chord(for: .commandBar), HotKeyAction.commandBar.defaultChord)
    }

    func test_attemptSet_duplicate_rejectsNamingTheOwner() {
        let store = HotKeyBindingsStore(store: makeStore())
        // ⌘⇧H is hover's chord.
        let outcome = store.attemptSet(HotKeyChord(keyCode: 4, carbonModifiers: 0x300), for: .commandBar)
        XCTAssertEqual(outcome, .rejected("Already used by Hover panel"))
    }

    func test_attemptSet_global_routesThroughApplyGlobal_andRecordsStatus() {
        let store = HotKeyBindingsStore(store: makeStore())
        var applied: (action: HotKeyAction, chord: HotKeyChord)?
        store.applyGlobal = { action, chord in
            applied = (action, chord)
            return .conflict(-9878)
        }
        let chord = HotKeyChord(keyCode: 11, carbonModifiers: 0x1800)
        XCTAssertEqual(store.attemptSet(chord, for: .rewrite), .saved)
        XCTAssertEqual(applied?.action, .rewrite)
        XCTAssertEqual(applied?.chord, chord)
        // The chord is saved even when the OS rejects it (spec §6): the row
        // shows the conflict and offers Reset.
        XCTAssertEqual(store.chord(for: .rewrite), chord)
        XCTAssertEqual(store.globalStatus[.rewrite], .conflict(-9878))
    }

    func test_attemptSet_inApp_doesNotTouchApplyGlobal() {
        let store = HotKeyBindingsStore(store: makeStore())
        var applied = false
        store.applyGlobal = { _, _ in applied = true; return .registered }
        _ = store.attemptSet(HotKeyChord(keyCode: 11, carbonModifiers: 0x1800), for: .noteSearch)
        XCTAssertFalse(applied)
    }

    func test_reset_restoresDefault_andReappliesGlobal() {
        let defaults = makeStore()
        let store = HotKeyBindingsStore(store: defaults)
        store.applyGlobal = { _, _ in .registered }
        _ = store.attemptSet(HotKeyChord(keyCode: 11, carbonModifiers: 0x1800), for: .dictation)
        store.reset(.dictation)
        XCTAssertEqual(store.chord(for: .dictation), HotKeyAction.dictation.defaultChord)
        XCTAssertEqual(store.globalStatus[.dictation], .registered)
        XCTAssertNil(defaults.object(forKey: "dictationHotKeyCode"))
    }

    func test_resetAll_restoresEveryDefault() {
        let store = HotKeyBindingsStore(store: makeStore())
        _ = store.attemptSet(HotKeyChord(keyCode: 11, carbonModifiers: 0x1800), for: .hover)
        _ = store.attemptSet(HotKeyChord(keyCode: 12, carbonModifiers: 0x1800), for: .notch)
        store.resetAll()
        for action in HotKeyAction.allCases {
            XCTAssertEqual(store.chord(for: action), action.defaultChord)
        }
    }

    func test_shortcut_forInAppAction_matchesKeyMap() {
        let store = HotKeyBindingsStore(store: makeStore())
        XCTAssertEqual(
            store.shortcut(for: .commandBar),
            HotKeyKeyMap.keyboardShortcut(keyCode: 40, carbonModifiers: 0x100))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter HotKeyBindingsStoreTests` → build FAILS

- [ ] **Step 3: Write the implementation**

`Sources/MustardKit/Views/HotKeyBindingsStore.swift`:

```swift
import SwiftUI

/// The observable bridge between the pure hotkey registry (`HotKeyBindings`,
/// `HotKeyValidation`, `HotKeyConflicts`) and the app: SwiftUI shortcuts read
/// `shortcut(for:)` so they update live; global chord writes route through
/// `applyGlobal` (set by `MustardApp`) into the owning coordinator's rebind.
@MainActor @Observable
public final class HotKeyBindingsStore {
    @ObservationIgnored private var bindings: HotKeyBindings

    /// Current chord per action — the published source SwiftUI observes.
    public private(set) var chords: [HotKeyAction: HotKeyChord] = [:]

    /// Routes a saved global chord into the owning Carbon hotkey's rebind.
    /// Nil result (coordinator not built, e.g. rewrite on macOS < 26) leaves
    /// the previous status untouched; the chord itself still persists.
    @ObservationIgnored public var applyGlobal: (@MainActor (HotKeyAction, HotKeyChord) -> HotKeyRegistration?)?

    /// The latest live-rebind outcome per global action, for the settings row.
    public private(set) var globalStatus: [HotKeyAction: HotKeyRegistration] = [:]

    public init(store: UserDefaults = .standard) {
        let bindings = HotKeyBindings(store: store)
        self.bindings = bindings
        for action in HotKeyAction.allCases { chords[action] = bindings.chord(for: action) }
    }

    public func chord(for action: HotKeyAction) -> HotKeyChord {
        chords[action] ?? action.defaultChord
    }

    /// Nil when the chord's key has no KeyEquivalent (validation prevents
    /// saving such chords for in-app actions, so this is belt-and-braces).
    public func shortcut(for action: HotKeyAction) -> KeyboardShortcut? {
        let chord = chord(for: action)
        return HotKeyKeyMap.keyboardShortcut(keyCode: chord.keyCode, carbonModifiers: chord.carbonModifiers)
    }

    public enum SetOutcome: Equatable {
        case saved
        case rejected(String)
    }

    /// Validate → conflict-check → persist → publish → (global) rebind live.
    /// An OS-level registration conflict does NOT unsave the chord (spec §6):
    /// the row shows the conflict and offers Reset.
    @discardableResult
    public func attemptSet(_ chord: HotKeyChord, for action: HotKeyAction) -> SetOutcome {
        if let error = HotKeyValidation.validate(chord, scope: action.scope) {
            return .rejected(error.message)
        }
        if let owner = HotKeyConflicts.conflictingAction(with: chord, for: action, chords: chords) {
            return .rejected("Already used by \(owner.label)")
        }
        bindings.set(chord, for: action)
        chords[action] = chord
        applyIfGlobal(action, chord)
        return .saved
    }

    public func reset(_ action: HotKeyAction) {
        bindings.reset(action)
        chords[action] = action.defaultChord
        applyIfGlobal(action, action.defaultChord)
    }

    public func resetAll() {
        for action in HotKeyAction.allCases { reset(action) }
    }

    private func applyIfGlobal(_ action: HotKeyAction, _ chord: HotKeyChord) {
        guard action.scope == .global, let result = applyGlobal?(action, chord) else { return }
        globalStatus[action] = result
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter HotKeyBindingsStoreTests` → PASS (8 tests), exit 0

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Views/HotKeyBindingsStore.swift Tests/MustardTests/HotKeyBindingsStoreTests.swift
git commit -m "feat(hotkeys): observable bindings store bridging registry, SwiftUI and live rebind

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: `Theme.Fonts.sectionHeader` token

**Files:**
- Modify: `Sources/MustardKit/Logic/Theme.swift` (inside `enum Fonts`, after the `label` token, ~line 208)

- [ ] **Step 1: Add the token**

```swift
        /// Settings-style section headers ("PROJECTS", "HOTKEYS"): 10pt
        /// semibold, callers add `.tracking(0.06)` (tracking is a view
        /// modifier, not a Font attribute). Promoted from copy-pasted
        /// literals in SettingsView/SourceSettingsView/VoiceSetupView.
        public static let sectionHeader = Font.system(size: 10, weight: .semibold)
```

New sections use it; existing call sites migrate only in files this plan
already touches (SettingsView, SourceSettingsView) — no drive-by edits to
VoiceSetupView's `sectionHeader(_:)` helper beyond the copy change in Task 14.

- [ ] **Step 2: Build**

Run: `swift build` → exit 0

- [ ] **Step 3: Commit**

```bash
git add Sources/MustardKit/Logic/Theme.swift
git commit -m "feat(theme): sectionHeader font token

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: `HotKeyRecorderView` + `HotKeySettingsSection` (views, build-verified)

**Files:**
- Create: `Sources/MustardKit/Views/HotKeyRecorderView.swift`
- Create: `Sources/MustardKit/Views/HotKeySettingsSection.swift`

Views are not unit-tested (repo rule) — decisions already live in Logic.

- [ ] **Step 1: Write `HotKeyRecorderView.swift`**

```swift
import AppKit
import SwiftUI

/// One hotkey row's recorder field: click to arm, press the new chord.
/// Esc cancels, ⌫ resets to the default. All accept/reject decisions are
/// pure (`HotKeyRecorderLogic`, `HotKeyValidation`, `HotKeyConflicts` via the
/// store) — this view only arms/disarms the NSEvent monitor and renders.
struct HotKeyRecorderView: View {
    let action: HotKeyAction
    @Environment(HotKeyBindingsStore.self) private var hotKeys
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejection: String?

    var body: some View {
        HStack(spacing: 8) {
            if let rejection {
                Text(rejection)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.error)
            }
            Button {
                isRecording ? disarm() : arm()
            } label: {
                Text(isRecording ? "Press keys…" : hotKeys.chord(for: action).description)
                    .font(Theme.Fonts.meta.monospaced())
                    .foregroundStyle(isRecording ? Theme.Palette.accent : Theme.Palette.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(minWidth: 96)
                    .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isRecording ? Theme.Palette.accent : Theme.Palette.hairline,
                                lineWidth: isRecording ? 1 : 0.5))
            }
            .buttonStyle(.plain)
            .help("Click, then press the new shortcut. Esc cancels, ⌫ resets to the default.")

            Button {
                rejection = nil
                hotKeys.reset(action)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Reset to \(action.defaultChord.description)")
        }
        .onDisappear { disarm() }
    }

    private func arm() {
        rejection = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil  // swallow while armed — the pressed chord must not reach the app
        }
    }

    private func disarm() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        switch HotKeyRecorderLogic.outcome(
            keyCode: UInt32(event.keyCode), nsEventFlags: event.modifierFlags.rawValue)
        {
        case .cancel:
            disarm()
        case .reset:
            hotKeys.reset(action)
            disarm()
        case let .capture(keyCode, carbonModifiers):
            switch hotKeys.attemptSet(
                HotKeyChord(keyCode: keyCode, carbonModifiers: carbonModifiers), for: action)
            {
            case .saved:
                disarm()
            case .rejected(let why):
                rejection = why  // stay armed so the next attempt is one keypress away
            }
        }
    }
}
```

- [ ] **Step 2: Write `HotKeySettingsSection.swift`**

```swift
import SwiftUI

/// Settings → HOTKEYS: one recorder row per action, live registration status
/// for the global three, and a reset-all footer.
struct HotKeySettingsSection: View {
    @Environment(HotKeyBindingsStore.self) private var hotKeys

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOTKEYS")
                .font(Theme.Fonts.sectionHeader).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)

            ForEach(HotKeyAction.allCases) { action in
                row(action)
            }

            Button("Reset all to defaults") { hotKeys.resetAll() }
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.accent)
                .buttonStyle(.plain)

            Text("The first three work anywhere on the Mac; the rest while Mustard is frontmost.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func row(_ action: HotKeyAction) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(action.label)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if case .conflict = registration(for: action) {
                    Text("In use by another app — pick a different chord, or free it there.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.warning)
                }
            }
            Spacer()
            HotKeyRecorderView(action: action)
        }
    }

    /// Live rebind status if the user changed this chord this session,
    /// otherwise the launch-time registration from the shared board.
    private func registration(for action: HotKeyAction) -> HotKeyRegistration? {
        if let live = hotKeys.globalStatus[action] { return live }
        guard let purpose = action.registrationPurpose else { return nil }
        return PushToTalkHotKey.registrationBoard[purpose]?.registration
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build` → exit 0

- [ ] **Step 4: Commit**

```bash
git add Sources/MustardKit/Views/HotKeyRecorderView.swift Sources/MustardKit/Views/HotKeySettingsSection.swift
git commit -m "feat(settings): hotkey recorder field and HOTKEYS section

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Extract `CalendarSettingsView`; slim `SourceSettingsView` to projects only

**Files:**
- Create: `Sources/MustardKit/Views/CalendarSettingsView.swift`
- Modify: `Sources/MustardKit/Views/SourceSettingsView.swift`

- [ ] **Step 1: Create `CalendarSettingsView.swift`** — move the calendar code out of `SourceSettingsView` verbatim (states, onAppear hydration, section body):

```swift
import SwiftUI

/// GOOGLE CALENDAR OAuth connection, extracted from SourceSettingsView so the
/// Settings screen can order it as its own section. Credentials live in the
/// Keychain (KeychainTokenStore), never UserDefaults.
struct CalendarSettingsView: View {
    @Environment(GoogleCalendarService.self) private var calendar
    @State private var gcalClientId = ""
    @State private var gcalClientSecret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("GOOGLE CALENDAR")
                    .font(Theme.Fonts.sectionHeader).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                if case .connected = calendar.state {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.done)
                }
            }

            switch calendar.state {
            case .disconnected, .failed:
                TextField("OAuth Client ID", text: $gcalClientId)
                    .textFieldStyle(.roundedBorder).font(Theme.Fonts.meta)
                SecureField("OAuth Client Secret", text: $gcalClientSecret)
                    .textFieldStyle(.roundedBorder).font(Theme.Fonts.meta)
                if case .failed(let msg) = calendar.state {
                    Text(msg).font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.error)
                }
                Button("Connect") {
                    Task {
                        await calendar.connect(
                            credentials: .init(clientId: gcalClientId, clientSecret: gcalClientSecret))
                    }
                }
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.accent)
                .buttonStyle(.plain)
                .disabled(gcalClientId.isEmpty || gcalClientSecret.isEmpty)

            case .connecting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Google… approve in your browser.")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textTertiary)
                }

            case .connected:
                if let synced = calendar.lastSynced {
                    Text("Last synced \(synced.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.Palette.textTertiary)
                }
                HStack(spacing: 14) {
                    Button("Refresh now") { Task { await calendar.fetch() } }
                        .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.accent).buttonStyle(.plain)
                    Button("Disconnect", role: .destructive) { calendar.disconnect() }
                        .font(Theme.Fonts.meta).foregroundStyle(Theme.Palette.error).buttonStyle(.plain)
                }
            }
        }
        .onAppear {
            if let creds = calendar.savedCredentials() {
                gcalClientId = creds.clientId
                gcalClientSecret = creds.clientSecret
            }
        }
    }
}
```

- [ ] **Step 2: Slim `SourceSettingsView.swift`** — delete from it: the
`@Environment(GoogleCalendarService.self)` line, the `gcalClientId`/`gcalClientSecret`
states, the `calendarSection` property and its call in `body` (line 37), the
`.onAppear` credentials block (lines 41–46), and update the doc comment. Change
the `PROJECTS` header literal to the token:

```swift
                Text("PROJECTS")
                    .font(Theme.Fonts.sectionHeader).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
```

Also remove the `.padding(.top, 16)` / `.padding(.bottom, 4)` on the outer
VStack (the parent section now owns spacing).

- [ ] **Step 3: Interim wiring so the build stays green** — `SettingsView` (old
shape, still rendering `SourceSettingsView()`) must show the calendar until
Task 11 recomposes it. In `SettingsView.body`, directly under `SourceSettingsView()`,
add `CalendarSettingsView()`. (AgentConsoleView also embeds `SourceSettingsView()`;
it loses that embed entirely in Task 12 — don't add the calendar there.)

- [ ] **Step 4: Build**

Run: `swift build` → exit 0

- [ ] **Step 5: Commit**

```bash
git add Sources/MustardKit/Views/CalendarSettingsView.swift Sources/MustardKit/Views/SourceSettingsView.swift Sources/MustardKit/Views/SettingsView.swift
git commit -m "refactor(settings): extract CalendarSettingsView; SourceSettingsView is projects-only

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: `AgentSettingsSection` + recomposed `SettingsView`

**Files:**
- Create: `Sources/MustardKit/Views/AgentSettingsSection.swift`
- Modify: `Sources/MustardKit/Views/SettingsView.swift` (full rewrite below)

- [ ] **Step 1: Create `AgentSettingsSection.swift`** — the config moved off the
Agent console (rows come from `AgentConsoleView.sourceRow`/`meetingSourceRow`
essentially verbatim):

```swift
import AppKit
import SwiftUI

/// SOURCES & AGENT: the vaults the sweeps read, the per-project schedule,
/// sweep-now, trust, and auto-open-source. Moved here from the Agent console
/// (settings spec 2026-08-12) — the console is pure triage now.
struct AgentSettingsSection: View {
    @Environment(AgentService.self) private var agent
    @AppStorage("vaultPath") private var vaultPath = ""
    @AppStorage("meetingVaultPath") private var meetingVaultPath = ""
    @AppStorage("trustLevel") private var trustRaw = TrustLevel.manual.rawValue
    @AppStorage("autoOpenSourceOnSelect") private var autoOpenSource = true

    private var trust: TrustLevel { TrustLevel(rawValue: trustRaw) ?? .manual }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SOURCES & AGENT")
                .font(Theme.Fonts.sectionHeader).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)

            vaultRow
            meetingRow
            SourceSettingsView()
            trustBlock

            Toggle(isOn: $autoOpenSource) {
                Text("Auto-open source").font(Theme.Fonts.meta)
            }
            .toggleStyle(.switch).controlSize(.mini)
            .help("When on, selecting a recommendation that has a source also opens it in the side panel.")

            if let error = agent.lastError {
                Text(error)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.error)
            }
        }
    }

    private var vaultRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(vaultPath.isEmpty ? "Choose your knowledge base folder…" : vaultPath)
                .font(Theme.Fonts.meta)
                .foregroundStyle(vaultPath.isEmpty ? Theme.Palette.textTertiary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url {
                    vaultPath = url.path
                }
            }
            .controlSize(.small)
            Spacer()
            Button {
                Task { await agent.sweep(vaultPath: vaultPath) }
            } label: {
                if agent.isSweeping {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Sweeping…")
                    }
                } else {
                    Label("✦ Sweep", systemImage: "wand.and.stars")
                }
            }
            .disabled(vaultPath.isEmpty || agent.isSweeping)
            .tint(Theme.Palette.accent)
        }
    }

    private var meetingRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2.wave.2")
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(meetingVaultPath.isEmpty ? "Choose your meeting-notes vault…" : meetingVaultPath)
                .font(Theme.Fonts.meta)
                .foregroundStyle(meetingVaultPath.isEmpty ? Theme.Palette.textTertiary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url {
                    meetingVaultPath = url.path
                }
            }
            .controlSize(.small)
            Spacer()
            if let summary = agent.lastMeetingSummary {
                Text(summary)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private var trustBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: Binding(
                get: { trust },
                set: { level in
                    trustRaw = level.rawValue
                    Task { await agent.applyTrust(level) }
                }
            )) {
                ForEach(TrustLevel.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).tint(Theme.Palette.agent).fixedSize()
            .help(trust.blurb)
            Text(trust.blurb)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("🔒 Email, Slack and tickets are always reviewed by you — at every trust level.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(.top, 4)
    }
}
```

- [ ] **Step 2: Rewrite `SettingsView.swift`** — full replacement:

```swift
import SwiftData
import SwiftUI

/// The settings home (BAK-133, expanded by the 2026-08-12 settings spec):
/// sources & agent, calendar, voice, hotkeys. The Agent console is pure
/// triage — everything configurable lives here now, including trust (this is
/// its only surface since the console strip-down).
public struct SettingsView: View {
    /// Navigates to the Voice Setup screen (BAK-280); RootView owns the route.
    private let onVoiceSetup: (() -> Void)?

    public init(onVoiceSetup: (() -> Void)? = nil) {
        self.onVoiceSetup = onVoiceSetup
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(Theme.Fonts.header)
                    .foregroundStyle(Theme.Palette.textPrimary)

                AgentSettingsSection()
                CalendarSettingsView()
                voiceSection
                HotKeySettingsSection()
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(Theme.Palette.bg)
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VOICE")
                .font(Theme.Fonts.sectionHeader).tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)
            Button {
                onVoiceSetup?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(Theme.Fonts.meta)
                    Text("Voice Setup…")
                        .font(Theme.Fonts.body)
                }
                .foregroundStyle(Theme.Palette.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("Microphone, speech, accessibility, system audio and calendar permissions — plus the on-device speech model.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `swift build` → exit 0. If a `#Preview`/`PreviewData` site constructs
`SettingsView` without the environment objects the new sections need
(`HotKeyBindingsStore`), add `.environment(HotKeyBindingsStore())` there.

- [ ] **Step 4: Commit**

```bash
git add Sources/MustardKit/Views/AgentSettingsSection.swift Sources/MustardKit/Views/SettingsView.swift
git commit -m "feat(settings): consolidated settings home — sources & agent, calendar, voice, hotkeys

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: Strip the Agent console to pure triage

**Files:**
- Modify: `Sources/MustardKit/Views/AgentConsoleView.swift`
- Modify: `Sources/MustardKit/Views/RootView.swift:88`

- [ ] **Step 1: Strip `AgentConsoleView`**

1. Delete the `@AppStorage` lines for `vaultPath`, `meetingVaultPath`, `trustRaw`
   (11–13) and the `trust` computed property (line 20). **Keep**
   `autoOpenSource` (line 14) — `select(_:)` still reads it; only the toggle UI moved.
2. Add the settings route after the `@Environment` properties:

```swift
    /// Jumps to the Settings screen (RootView owns the route) — all console
    /// config moved there (settings spec 2026-08-12).
    private let onOpenSettings: (() -> Void)?

    public init(onOpenSettings: (() -> Void)? = nil) {
        self.onOpenSettings = onOpenSettings
    }
```

   (This replaces the existing `public init() {}`.)
3. In `masterColumn`, delete the `sourceRow`, `meetingSourceRow`, and
   `SourceSettingsView()` lines and the `agent.lastError` block (lines 61–69) —
   the error now shows in Settings.
4. Delete the `sourceRow` and `meetingSourceRow` builders entirely (lines 169–258).
5. In `header`, replace the `Toggle` (lines 160–164) with a gear:

```swift
            Button {
                onOpenSettings?()
            } label: {
                Image(systemName: "gearshape")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Sources, trust and hotkeys moved to Settings.")
```

6. Update the empty-state line (sweep is no longer on this screen):

```swift
                    emptyLine("Nothing waiting on you. Run a sweep from Settings or ⌘K.")
```

7. Update the file's doc comment (lines 5–7) to say: console is pure triage;
   config lives in SettingsView.

- [ ] **Step 2: Wire the route in `RootView`** (line 88):

```swift
                    case .agent: AgentConsoleView(onOpenSettings: { screen = .settings })
```

- [ ] **Step 3: Build and full test**

Run: `swift build` → exit 0; `swift test` → exit 0

- [ ] **Step 4: Commit**

```bash
git add Sources/MustardKit/Views/AgentConsoleView.swift Sources/MustardKit/Views/RootView.swift
git commit -m "feat(agent): console is pure triage — config moved to Settings, gear links there

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 13: App wiring — store creation, dynamic shortcuts, global rebind routing

**Files:**
- Modify: `Sources/Mustard/MustardApp.swift`
- Modify: `Sources/MustardKit/Views/RootView.swift:126-140`

- [ ] **Step 1: `MustardApp` — create and inject the store**

Add to the `@State` block (after `notchNav`, line ~130):

```swift
    @State private var hotKeys = HotKeyBindingsStore()
```

In `body`, add the environment (with the other `.environment` lines on `RootView()`):

```swift
                .environment(hotKeys)
```

At the END of the `.task` block (after the `dictation` block, line ~279), add:

```swift
                    // Route saved global chords into the owning coordinator's
                    // live rebind (Settings → Hotkeys). Coordinators are stable
                    // class instances for the app's lifetime, captured here
                    // once they all exist.
                    let capture = voiceCapture
                    let dictating = dictation
                    let rewriting = rewrite
                    hotKeys.applyGlobal = { action, chord in
                        switch action {
                        case .pushToTalk:
                            capture?.rebindHotKey(keyCode: chord.keyCode, modifiers: chord.carbonModifiers)
                        case .dictation:
                            dictating?.rebindHotKey(keyCode: chord.keyCode, modifiers: chord.carbonModifiers)
                        case .rewrite:
                            if #available(macOS 26.0, *) {
                                rewriting?.rebindHotKey(keyCode: chord.keyCode, modifiers: chord.carbonModifiers)
                            } else {
                                nil
                            }
                        default:
                            nil
                        }
                    }
```

Replace the hardcoded `.commands` chords (lines 283–290):

```swift
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Toggle Hover Panel") { hoverPanel?.toggle() }
                    .keyboardShortcut(hotKeys.shortcut(for: .hover))
                Button("Toggle Notch") { notch?.toggle() }
                    .keyboardShortcut(hotKeys.shortcut(for: .notch))
            }
        }
```

- [ ] **Step 2: `RootView` — dynamic hidden triggers**

Add to the properties (near `@Environment(NotchNavigation.self)`, line 65):

```swift
    @Environment(HotKeyBindingsStore.self) private var hotKeys
```

Replace the three hardcoded `.keyboardShortcut` literals in the hidden-button
background (lines 126–140):

```swift
        .background {
            Group {
                // Hidden trigger: opens the command bar while the window is key.
                // Chords are user-set (Settings → Hotkeys) and update live.
                Button("") { showCommandBar.toggle() }
                    .keyboardShortcut(hotKeys.shortcut(for: .commandBar))
                // Hidden trigger: toggles the source inspector.
                Button("") { sourcePanel.isPresented.toggle() }
                    .keyboardShortcut(hotKeys.shortcut(for: .sourceInspector))
                // Hidden trigger: opens full-text note search (polish pack B).
                // Closes the command bar first — the two palettes must never stack.
                Button("") { showCommandBar = false; showNoteSearch.toggle() }
                    .keyboardShortcut(hotKeys.shortcut(for: .noteSearch))
            }
            .opacity(0)
        }
```

- [ ] **Step 3: Build, full test, and preview fix-ups**

Run: `swift build` → exit 0; `swift test` → exit 0.
Any `#Preview` that renders `RootView` (or a view subtree using the store) needs
`.environment(HotKeyBindingsStore())` — fix compile errors as they surface.

- [ ] **Step 4: Commit**

```bash
git add Sources/Mustard/MustardApp.swift Sources/MustardKit/Views/RootView.swift
git commit -m "feat(hotkeys): dynamic shortcuts app-wide; global chords rebind live from Settings

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 14: Point stale chord copy at Settings → Hotkeys

**Files:**
- Modify: `Sources/MustardKit/Views/VoiceSetupView.swift` (~line 184)

- [ ] **Step 1: Replace the conflict copy** in `shortcutRow(purpose:)`:

```swift
                        Text("Another app already owns \(entry.chord). Change Mustard's chord in Settings → Hotkeys, or free it in the other app.")
```

- [ ] **Step 2: Sweep for other hardcoded chord hints**

Run: `grep -rn "⌃⌥\|⌘⇧\|defaults write\|voiceHotKeyCode" Sources/ --include="*.swift" | grep -v "HotKey\|Tests"`

For each hit that is a **user-facing UI string naming one of the eight chords**
(not a code comment or log): if the view already has environment access to
`HotKeyBindingsStore`, replace the literal with
`hotKeys.chord(for: .<action>).description`; if it would need new plumbing,
leave it and list the file in the PR body under "known stale chord hints".
Code comments and doc comments stay as-is.

- [ ] **Step 3: Build**

Run: `swift build` → exit 0

- [ ] **Step 4: Commit**

```bash
git add -A Sources/
git commit -m "fix(voice): chord-conflict copy points at Settings → Hotkeys

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 15: Spec amendment, full verification, PR, merge

**Files:**
- Modify: `docs/superpowers/specs/2026-08-12-settings-hotkey-customization-design.md` (§5, one line)

- [ ] **Step 1: Amend spec §5** — replace the sentence
  "Push-to-talk/dictation rebind is deferred while a hold is active (the
  hold-epoch guard stays intact — rebind applies when idle)." with:

```markdown
  Push-to-talk/dictation rebind first ends any active hold through the normal
  release path (the capture commits — transcript never lost), then re-registers;
  `unregister()` alone would clear the hold flag without firing `onRelease`.
```

- [ ] **Step 2: Full verification**

```bash
swift test
```
Expected: exit 0, all tests pass (~1,660+: the pre-existing ~1,634 plus the new
hotkey suites). Then:

```bash
swift build && ./build-app.sh
```
Expected: exit 0 for both; `build/Mustard.app` produced.

- [ ] **Step 3: Commit, push, PR**

```bash
git add docs/superpowers/specs/2026-08-12-settings-hotkey-customization-design.md
git commit -m "docs(spec): rebind ends an active hold through the release path

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push -u origin claude/settings-hotkey-customization-eff415
```

Create the PR against `main` with `gh pr create`, body summarizing: settings
consolidation, bare console, 8 customizable hotkeys, live rebind, legacy-key
compat; include the test delta and any "known stale chord hints" from Task 14.
End the body with the standard generated-with line.

- [ ] **Step 4: Fresh-context review + merge (repo dev-loop rules)**

Follow `.agent-loop/checks.yml` (swift test + swift build already green) and run
a fresh-context review per `.agent-loop/review-rubric.md`. This change is UI +
local hotkeys — no irreversible outward actions — so it auto-merges on a passing
review. Append the digest entry to `.agent-loop/digest.md` with the ready
`git revert <merge-sha>` line, in an isolated worktree if other sessions are
active (parallel-session digest collisions are a known trap).

**Eye-check to request in the final chat message (only Leon can do these):**
1. Settings screen: sections render calm and ordered (Sources & Agent / Calendar / Voice / Hotkeys).
2. Agent console: bare triage + gear jumps to Settings.
3. One live global rebind: change push-to-talk to something else in Settings → Hotkeys, hold the new chord anywhere, speak — pill appears; old chord dead.
4. One in-app rebind: change ⌘K, verify the new chord opens the command bar and the menu items show updated shortcuts (⌘⇧H/⌘⇧N live-update is the one SwiftUI-observation risk flagged in the spec).
