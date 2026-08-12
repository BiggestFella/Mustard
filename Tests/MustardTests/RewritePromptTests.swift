import XCTest
@testable import MustardKit

/// Prompt assembly. Phase 2's voice profile enters through `styleRules` and
/// nowhere else, which is why that parameter exists now with an empty default.
final class RewritePromptTests: XCTestCase {

    func test_instructions_combineTheBandTextAndTheIntentFragment() {
        let instructions = RewritePrompt.instructions(
            intent: .tighten, bandInstructions: "BAND RULES", styleRules: [])
        XCTAssertTrue(instructions.contains("BAND RULES"))
        XCTAssertTrue(instructions.contains(RewriteIntent.tighten.instructionFragment))
    }

    func test_instructions_includeStyleRulesWhenPresent() {
        let instructions = RewritePrompt.instructions(
            intent: .warmer, bandInstructions: "BAND RULES",
            styleRules: ["Use contractions.", "Never open with pleasantries."])
        XCTAssertTrue(instructions.contains("Use contractions."))
        XCTAssertTrue(instructions.contains("Never open with pleasantries."))
    }

    func test_instructions_omitTheStyleSection_whenThereAreNoRules() {
        let instructions = RewritePrompt.instructions(
            intent: .warmer, bandInstructions: "BAND RULES", styleRules: [])
        XCTAssertFalse(instructions.contains(RewritePrompt.styleHeading),
                       "An empty style section is wasted context on a small window.")
    }

    func test_prompt_carriesTheSelectionVerbatimInsideDelimiters() {
        let selection = "Just wanted to check in re: the SOW"
        let prompt = RewritePrompt.prompt(selection: selection)
        XCTAssertTrue(prompt.contains(selection), "The selection must not be paraphrased or escaped.")
        XCTAssertTrue(prompt.contains(RewritePrompt.selectionOpenDelimiter))
        XCTAssertTrue(prompt.contains(RewritePrompt.selectionCloseDelimiter))
    }

    func test_promptFeatureName_isStable() {
        XCTAssertEqual(RewritePrompt.feature, "rewrite",
                       "PromptCatalog resource names derive from this.")
    }

    func test_bandResources_existForTheShippedBands() {
        // The catalog falls back downward only, so the base band must exist.
        let available: Set<String> = ["rewrite-26", "rewrite-27"]
        XCTAssertEqual(
            PromptCatalog.bestResource(feature: RewritePrompt.feature, band: .macOS26_4) {
                available.contains($0)
            },
            "rewrite-26",
            "26.4 has no dedicated prompt and must fall back to 26, never up to 27.")
    }

    func test_shippedBandResources_areActuallyInTheBundle() {
        // The test above proves the fallback rule with a fake catalog; this one
        // proves the files were registered as resources and can be loaded.
        for band in [PromptBand.macOS26, .macOS27] {
            let name = PromptCatalog.resourceName(feature: RewritePrompt.feature, band: band)
            let url = Bundle.module.url(forResource: name, withExtension: "txt")
            XCTAssertNotNil(url, "\(name).txt must ship in the bundle")
            let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            XCTAssertTrue(text.contains("Preserve meaning exactly"),
                          "\(name).txt must carry the meaning-preservation rule")
        }
    }
}
