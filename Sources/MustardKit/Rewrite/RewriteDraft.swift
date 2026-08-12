// Guided generation is a Mac feature: the iOS companion compiles MustardKit
// sources directly at an iOS 17 floor where FoundationModels (and @Generable)
// do not exist, so this whole unit is macOS-only — matching
// `GeneratedVoiceTaskDraft`.
#if os(macOS)
import Foundation
import FoundationModels

/// The model's typed output. Guided generation means we never parse prose:
/// the framework constrains the model to this shape.
///
/// `changeNote` is one short line for the card ("cut hedging, 41 → 21 words").
/// It is explanatory only — never applied to the user's document.
@Generable
public struct RewriteDraft: Sendable {
    @Guide(description: "The rewritten text only. No preamble, no quotes, no explanation.")
    public var rewritten: String

    @Guide(description: "One short line naming what changed. Under 12 words.")
    public var changeNote: String

    /// Explicit, because a public struct does not get a public memberwise
    /// init — the tests construct this directly.
    public init(rewritten: String, changeNote: String) {
        self.rewritten = rewritten
        self.changeNote = changeNote
    }
}
#endif
