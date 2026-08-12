import Foundation

/// Builds the instructions and prompt for one rewrite. Pure — the band text
/// is passed in, having been loaded from a `PromptCatalog` resource by the
/// coordinator, so nothing here touches `Bundle`.
///
/// Phase 2 (voice profile) enters through `styleRules` and nowhere else.
public enum RewritePrompt {
    /// Feeds `PromptCatalog.resourceName(feature:band:)` → "rewrite-27" etc.
    public static let feature = "rewrite"

    public static let styleHeading = "How this person writes:"
    public static let selectionOpenDelimiter = "<<<SELECTION"
    public static let selectionCloseDelimiter = "SELECTION>>>"

    public static func instructions(
        intent: RewriteIntent,
        bandInstructions: String,
        styleRules: [String] = []
    ) -> String {
        var parts = [bandInstructions, intent.instructionFragment]
        if !styleRules.isEmpty {
            parts.append(([styleHeading] + styleRules.map { "- \($0)" }).joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    /// The selection goes in verbatim, inside delimiters, so the model can tell
    /// the text-to-rewrite from the instructions even when the selection itself
    /// contains instruction-shaped sentences.
    public static func prompt(selection: String) -> String {
        """
        Rewrite the text between the delimiters.

        \(selectionOpenDelimiter)
        \(selection)
        \(selectionCloseDelimiter)
        """
    }
}
