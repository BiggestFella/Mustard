import Foundation

/// Reads the text a user has selected in the focused element. Every edge is an
/// injected closure, so the sequencing below is unit-tested without AX, the
/// pasteboard, or synthesized key events.
///
/// The ordering is a safety property, not an optimisation: rungs 1 and 2 are
/// passive reads, and rung 3 posts ⌘C key events into someone else's
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
