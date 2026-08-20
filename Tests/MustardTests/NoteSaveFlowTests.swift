import XCTest
@testable import MustardKit

final class NoteSaveFlowTests: XCTestCase {
    private func ref(_ path: String) -> NoteRef {
        NoteRef(project: "p", workingDirectory: "/wd", relativePath: path)
    }

    // MARK: - Dirty gate

    func test_cleanNote_doesNotWrite() {
        let plan = NoteSaveFlow.plan(content: "same", baseline: "same",
                                     savedRef: ref("a.md"), currentRef: ref("a.md"),
                                     contentRef: ref("a.md"))
        XCTAssertFalse(plan.shouldWrite)
        XCTAssertFalse(plan.shouldAdvanceBaseline)
    }

    func test_cleanNote_offScreen_stillDoesNotWrite() {
        // Dirty gate wins even when the saved note is no longer current.
        let plan = NoteSaveFlow.plan(content: "same", baseline: "same",
                                     savedRef: ref("a.md"), currentRef: ref("b.md"),
                                     contentRef: ref("a.md"))
        XCTAssertFalse(plan.shouldWrite)
        XCTAssertFalse(plan.shouldAdvanceBaseline)
    }

    // MARK: - Baseline-advance rule

    func test_dirtyNote_onScreen_writesAndAdvancesBaseline() {
        // Explicit save / autosave-on-disappear: saved note is the one on screen.
        let plan = NoteSaveFlow.plan(content: "new", baseline: "old",
                                     savedRef: ref("a.md"), currentRef: ref("a.md"),
                                     contentRef: ref("a.md"))
        XCTAssertTrue(plan.shouldWrite)
        XCTAssertTrue(plan.shouldAdvanceBaseline)
    }

    func test_dirtyNote_offScreen_writesButDoesNotAdvanceBaseline() {
        // Save-on-switch: targets the OLD ref while @State still holds that
        // note's text, so we write — but the in-view baseline must NOT advance
        // (it will belong to the new note once .task reloads).
        let plan = NoteSaveFlow.plan(content: "new", baseline: "old",
                                     savedRef: ref("a.md"), currentRef: ref("b.md"),
                                     contentRef: ref("a.md"))
        XCTAssertTrue(plan.shouldWrite)
        XCTAssertFalse(plan.shouldAdvanceBaseline)
    }

    // MARK: - Content-ownership gate (⌘S-during-switch race)

    func test_dirtyBuffer_belongingToOtherNote_doesNotWrite() {
        // ⌘S in the gap: `ref` has already flipped to B, but @State still
        // holds A's dirty text. Writing would persist A over B.md.
        let plan = NoteSaveFlow.plan(content: "A's edit", baseline: "A's disk",
                                     savedRef: ref("b.md"), currentRef: ref("b.md"),
                                     contentRef: ref("a.md"))
        XCTAssertFalse(plan.shouldWrite)
        XCTAssertFalse(plan.shouldAdvanceBaseline)
    }

    func test_dirtyBuffer_unknownOwner_doesNotWrite() {
        // Reload in flight: contentRef is cleared until .task finishes.
        let plan = NoteSaveFlow.plan(content: "stale", baseline: "older",
                                     savedRef: ref("b.md"), currentRef: ref("b.md"),
                                     contentRef: nil)
        XCTAssertFalse(plan.shouldWrite)
        XCTAssertFalse(plan.shouldAdvanceBaseline)
    }
}
