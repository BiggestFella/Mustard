import Foundation

/// Deterministic contextual whitespace for system-wide dictation. Given the
/// finalized transcript and the snapshotted target, produces the exact string
/// the inserter must place — or nil when nothing may be inserted at all.
///
/// Rules (from the dictation design spec):
/// - Secure/password targets never yield an insertion.
/// - An empty transcript never yields an insertion (an empty replacement would
///   silently delete a selection).
/// - Replacing a nonempty selection inserts exactly the transcript — the
///   selection already owned its boundaries.
/// - At an empty cursor, a single space is added on a side only when the
///   adjacent character *and* the transcript's character on that side are both
///   word characters (letters/digits). Newlines, existing spaces, and
///   punctuation — opening or closing — therefore never attract a space.
public enum DictationWhitespace {
    /// The exact replacement string for `target`, or nil when insertion must
    /// not happen (secure target, empty transcript).
    public static func insertion(text: String, target: FocusedTextTarget) -> String? {
        guard !target.isSecure else { return nil }
        guard let first = text.first, let last = text.last else { return nil }

        // A nonempty selection is replaced verbatim.
        if let range = target.selectedRange, range.length > 0 { return text }

        var result = text
        if let before = target.precedingCharacter, isWord(before), isWord(first) {
            result = " " + result
        }
        if let after = target.followingCharacter, isWord(after), isWord(last) {
            result += " "
        }
        return result
    }

    /// Word characters are the only pair that requires separation: letters and
    /// digits. Everything else (whitespace, newlines, punctuation) separates
    /// itself.
    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
