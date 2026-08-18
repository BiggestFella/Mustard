import XCTest
import AppKit
import SwiftUI
@testable import MustardKit

/// IME / marked-text interaction with the slash menu (BAK-242). The decision
/// lives in `SlashMenu.allowsInteraction`; these tests pin the coordinator
/// wiring — commit must not splice while `hasMarkedText()` is true.
@MainActor
final class MarkdownTextViewIMETests: XCTestCase {

    func test_performSlashCommand_withMarkedText_leavesBufferUnchanged() {
        var text = "/"
        var menu: SlashMenuState? = SlashMenuState(
            query: "",
            triggerRange: NSRange(location: 0, length: 1),
            anchor: .zero
        )
        let parent = MarkdownTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            slashMenu: Binding(get: { menu }, set: { menu = $0 })
        )
        let coordinator = MarkdownTextView.Coordinator(parent)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        textView.string = "/"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.textView = textView

        textView.setMarkedText(
            "你",
            selectedRange: NSRange(location: 0, length: 1),
            replacementRange: NSRange(location: 1, length: 0)
        )
        XCTAssertTrue(
            textView.hasMarkedText(),
            "precondition: setMarkedText must establish an IME composition"
        )

        let before = textView.string
        let heading = SlashMenu.items(query: "").first { $0.id == "h1" }!
        coordinator.performSlashCommand(heading)

        XCTAssertEqual(textView.string, before)
        XCTAssertNotNil(menu, "refused commit must not dismiss the menu")
    }

    func test_performSlashCommand_withoutMarkedText_splicesHeading() {
        var text = "/"
        var menu: SlashMenuState? = SlashMenuState(
            query: "",
            triggerRange: NSRange(location: 0, length: 1),
            anchor: .zero
        )
        let parent = MarkdownTextView(
            text: Binding(get: { text }, set: { text = $0 }),
            slashMenu: Binding(get: { menu }, set: { menu = $0 })
        )
        let coordinator = MarkdownTextView.Coordinator(parent)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        textView.string = "/"
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        coordinator.textView = textView

        XCTAssertFalse(textView.hasMarkedText())
        let heading = SlashMenu.items(query: "").first { $0.id == "h1" }!
        coordinator.performSlashCommand(heading)

        XCTAssertEqual(textView.string, "# ")
        XCTAssertNil(menu)
    }
}
