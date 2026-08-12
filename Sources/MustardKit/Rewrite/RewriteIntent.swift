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
