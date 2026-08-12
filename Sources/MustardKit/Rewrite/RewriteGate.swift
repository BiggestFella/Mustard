import Foundation

/// The rewrite gate, deliberately split into two decisions around the read.
///
/// `admits` runs FIRST, on the focus snapshot alone. Read rung 3 synthesizes a
/// ⌘C keystroke into the target application, so a secure field has to be
/// refused before the ladder ever runs — not after.
///
/// `accepts` runs SECOND, on the text that came back.
public enum RewriteGate {

    /// Pre-read admission. Returns nil when the target may be read.
    /// Secure is checked first and unconditionally: if a password field also
    /// lacks permission, the refusal the user must see is the secure one.
    public static func admits(
        target: FocusedTextTarget,
        role: String?,
        hasAccessibility: Bool
    ) -> RewriteRefusal? {
        if target.isSecure { return .secureField }
        guard hasAccessibility else { return .accessibilityPermissionMissing }
        guard RewriteRoles.admits(role: role) else {
            return .unsupportedRole(role ?? "unknown")
        }
        // A KNOWN zero-length range is a bare cursor. A nil range is merely
        // withheld (web areas do this routinely) and the ⌘C rung can still
        // recover the selection, so nil must not be refused here.
        if let range = target.selectedRange, range.length == 0 { return .noSelection }
        return nil
    }

    /// Post-read acceptance. Trims the selection, and refuses empty,
    /// unreadable, and oversized selections with specific copy.
    public static func accepts(
        read: SelectionRead,
        application: String,
        maxWords: Int
    ) -> Result<String, RewriteRefusal> {
        switch read {
        case .unreadable:
            return .failure(.unreadableSelection(application: application))
        case .empty:
            return .failure(.noSelection)
        case .text(let raw):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.noSelection) }
            let words = RewriteBudget.wordCount(trimmed)
            guard words <= maxWords else {
                return .failure(.overBudget(words: words, limit: maxWords))
            }
            return .success(trimmed)
        }
    }
}
