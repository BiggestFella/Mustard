import Foundation

/// Selection-length budget. `contextSize` is reported in tokens by
/// `SystemLanguageModel`; a rewrite has to fit instructions, the selection,
/// AND a rewrite of roughly the selection's size in the same window. A
/// quarter of the window in words is a deliberately conservative allowance
/// (English averages under a token per word, so a quarter in words is well
/// under half the window in tokens).
public enum RewriteBudget {
    /// Never refuse everything because the model reported a nonsense context.
    public static let floorWords = 400

    public static func maxWords(contextSize: Int) -> Int {
        max(floorWords, contextSize / 4)
    }

    /// Whitespace-separated runs. Deliberately crude: it only has to be a
    /// stable, explainable number to show the user in a refusal.
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}
