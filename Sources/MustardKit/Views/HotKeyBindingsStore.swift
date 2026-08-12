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
