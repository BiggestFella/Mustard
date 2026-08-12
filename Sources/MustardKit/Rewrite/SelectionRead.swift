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
