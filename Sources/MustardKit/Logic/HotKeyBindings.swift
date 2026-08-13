import Foundation

/// One customizable shortcut. The global (Carbon) actions keep the
/// UserDefaults keys they have always had — `PushToTalkHotKey`/`RewriteHotKey`/
/// `ClipsHotKey` read them at init — so pre-existing manual overrides survive
/// this feature with no migration. In-app actions get namespaced keys.
public enum HotKeyAction: String, CaseIterable, Identifiable, Sendable {
    case pushToTalk, dictation, rewrite, clips
    case hover, notch, commandBar, sourceInspector, noteSearch
    case triageApprove, triageIgnore, triageSnooze, triageNext, triagePrevious

    public var id: String { rawValue }

    public enum Scope: Equatable, Sendable, CaseIterable {
        /// Registered with Carbon; works anywhere on the Mac.
        case global
        /// A SwiftUI `.keyboardShortcut`; works while Mustard is frontmost.
        case inApp
        /// A local key monitor inside the Agent console only. Single keys are
        /// allowed here (triage is a rhythm) because the console suppresses them
        /// whenever a text field has focus — see `TriageShortcuts.shouldHandle`.
        case triage
    }

    public var scope: Scope {
        switch self {
        case .pushToTalk, .dictation, .rewrite, .clips: .global
        case .hover, .notch, .commandBar, .sourceInspector, .noteSearch: .inApp
        case .triageApprove, .triageIgnore, .triageSnooze, .triageNext, .triagePrevious: .triage
        }
    }

    public var label: String {
        switch self {
        case .pushToTalk: "Push-to-talk capture"
        case .dictation: "System dictation"
        case .rewrite: "Rewrite selection"
        case .clips: "Clipboard history"
        case .hover: "Hover panel"
        case .notch: "Notch"
        case .commandBar: "Command bar"
        case .sourceInspector: "Source inspector"
        case .noteSearch: "Note search"
        case .triageApprove: "Approve & run"
        case .triageIgnore: "Ignore"
        case .triageSnooze: "Snooze"
        case .triageNext: "Next recommendation"
        case .triagePrevious: "Previous recommendation"
        }
    }

    public var defaultChord: HotKeyChord {
        switch self {
        case .pushToTalk: HotKeyChord(keyCode: 49, carbonModifiers: 0x1800)  // ⌃⌥Space
        case .dictation: HotKeyChord(keyCode: 2, carbonModifiers: 0x1800)  // ⌃⌥D
        case .rewrite: HotKeyChord(keyCode: 15, carbonModifiers: 0x1800)  // ⌃⌥R
        case .clips: HotKeyChord(keyCode: 9, carbonModifiers: 0x1800)  // ⌃⌥V
        case .hover: HotKeyChord(keyCode: 4, carbonModifiers: 0x300)  // ⌘⇧H
        case .notch: HotKeyChord(keyCode: 45, carbonModifiers: 0x300)  // ⌘⇧N
        case .commandBar: HotKeyChord(keyCode: 40, carbonModifiers: 0x100)  // ⌘K
        case .sourceInspector: HotKeyChord(keyCode: 1, carbonModifiers: 0x300)  // ⌘⇧S
        case .noteSearch: HotKeyChord(keyCode: 3, carbonModifiers: 0x300)  // ⌘⇧F
        // Bare keys, console-only: A(pprove) · X (kill it) · S(nooze) · J/K to walk.
        case .triageApprove: HotKeyChord(keyCode: 0, carbonModifiers: 0)  // A
        case .triageIgnore: HotKeyChord(keyCode: 7, carbonModifiers: 0)  // X
        case .triageSnooze: HotKeyChord(keyCode: 1, carbonModifiers: 0)  // S
        case .triageNext: HotKeyChord(keyCode: 38, carbonModifiers: 0)  // J
        case .triagePrevious: HotKeyChord(keyCode: 40, carbonModifiers: 0)  // K
        }
    }

    public var codeKey: String {
        switch self {
        case .pushToTalk: "voiceHotKeyCode"
        case .dictation: "dictationHotKeyCode"
        case .rewrite: "rewriteHotKeyCode"
        case .clips: "clipsHotKeyCode"
        default: "hotkey.\(rawValue).code"
        }
    }

    public var modifiersKey: String {
        switch self {
        case .pushToTalk: "voiceHotKeyModifiers"
        case .dictation: "dictationHotKeyModifiers"
        case .rewrite: "rewriteHotKeyModifiers"
        case .clips: "clipsHotKeyModifiers"
        default: "hotkey.\(rawValue).modifiers"
        }
    }

    /// The `PushToTalkHotKey.registrationBoard` purpose key (global actions only).
    public var registrationPurpose: String? {
        switch self {
        case .pushToTalk: "Task capture"
        case .dictation: "Dictation"
        case .rewrite: "Rewrite"
        case .clips: "Clips"
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
    case keyReservedWithoutModifier

    public var message: String {
        switch self {
        case .needsModifier: "Add ⌘, ⌃ or ⌥"
        case .keyNotSupportedInApp: "That key can't be an in-app shortcut"
        case .keyReservedWithoutModifier: "That key needs a modifier"
        }
    }
}

public enum HotKeyValidation {
    /// Space, Return and Tab drive the focused control (and the list), so they
    /// can never be a bare triage key.
    private static let reservedBareKeys: Set<UInt32> = [49, 36, 48]

    /// Shift alone is not enough — an unmodified (or shift-only) key would
    /// fire while typing. In-app chords must also be expressible as a SwiftUI
    /// KeyEquivalent; global Carbon chords take any key code. Triage chords are
    /// the exception to the modifier rule: they are matched by a monitor that
    /// stands down while any text field has focus, so a single letter is safe.
    public static func validate(_ chord: HotKeyChord, scope: HotKeyAction.Scope) -> HotKeyValidationError? {
        if scope == .triage {
            let bare = chord.carbonModifiers & (0x1000 | 0x800 | 0x100) == 0
            if bare, reservedBareKeys.contains(chord.keyCode) { return .keyReservedWithoutModifier }
            return nil
        }
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
