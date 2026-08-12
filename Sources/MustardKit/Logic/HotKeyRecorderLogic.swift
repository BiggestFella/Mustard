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
