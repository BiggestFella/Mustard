// Gated with `RewriteDraft`/`RewriteCoordinator`: the review carries model
// output, and guided generation is macOS-only in this package.
#if os(macOS)
import Foundation

/// What the card is showing. One value, so the view is a pure function of it.
@available(macOS 26.0, iOS 26.0, *)
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
@available(macOS 26.0, iOS 26.0, *)
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
#endif
