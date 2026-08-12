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
