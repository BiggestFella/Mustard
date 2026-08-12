import Foundation

/// Every reason a rewrite does not happen. Typed, exhaustive, and each case
/// carries its own user-facing copy — nothing about a refusal is silent, and
/// the card always has something specific to say.
public enum RewriteRefusal: Error, Equatable, Sendable {
    /// Accessibility is not granted; Voice Setup routes to System Settings.
    case accessibilityPermissionMissing
    /// A password-shaped field. Refused unconditionally, before any read.
    case secureField
    /// The focused element is not something we rewrite. Carries the role so
    /// the cross-app matrix grows from real data.
    case unsupportedRole(String)
    /// Nothing is selected. A hint, not an error.
    case noSelection
    /// All three read rungs failed. Carries the application name for the copy.
    case unreadableSelection(application: String)
    /// The selection is longer than the context window allows.
    case overBudget(words: Int, limit: Int)
    /// Focus or element identity moved between the snapshot and the accept.
    case focusChanged
    /// The on-device model could not run. Wraps PR #101's failure vocabulary.
    case model(LocalModelFailure)
    /// The write-back did not land. The original is untouched.
    case writeFailed(String)

    /// Sentence-case, no exclamation marks, says what happened and what to do.
    public var message: String {
        switch self {
        case .accessibilityPermissionMissing:
            return "Rewrite needs Accessibility access. Open Voice Setup to grant it."
        case .secureField:
            return "This looks like a password field — rewrite never touches those."
        case .unsupportedRole(let role):
            return "That isn't an editable text field (\(role))."
        case .noSelection:
            return "Select the text you want rewritten, then press ⌃⌥R."
        case .unreadableSelection(let application):
            return "Couldn't read the selection in \(application)."
        case .overBudget(let words, let limit):
            return "That selection is \(words) words; rewrite handles up to \(limit). Select less."
        case .focusChanged:
            return "The text moved before the rewrite was applied. Nothing was changed."
        case .model(let failure):
            return failure.rewriteMessage
        case .writeFailed(let reason):
            return "Couldn't write the rewrite back — \(reason). Your original is unchanged."
        }
    }
}

extension LocalModelFailure {
    /// Rewrite-flavoured copy for the shared on-device failure vocabulary.
    var rewriteMessage: String {
        switch self {
        case .appleIntelligenceDisabled:
            return "Apple Intelligence is switched off. Turn it on in System Settings."
        case .deviceNotEligible:
            return "This Mac can't run the on-device model."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again shortly."
        case .unsupportedLocale:
            return "The on-device model doesn't support this language yet."
        case .contextOverflow:
            return "That selection is too long for the on-device model. Select less."
        case .unavailable(let reason):
            return "Rewrite is unavailable — \(reason)."
        }
    }
}
