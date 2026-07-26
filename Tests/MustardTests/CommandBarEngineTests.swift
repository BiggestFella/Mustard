import XCTest
@testable import MustardKit

final class CommandBarEngineTests: XCTestCase {
    func test_emptyQuery_offersDefaultActions() {
        let items = CommandBarEngine.items(query: "")
        XCTAssertEqual(items.map(\.kind), [.planDay, .goToday, .goBoard, .goWeek, .goNotes, .goAgent, .sweep, .reindexNotes, .searchNotes])
    }

    func test_freeText_offersAddTaskFirst() {
        let items = CommandBarEngine.items(query: "Reply to Kamil")
        XCTAssertEqual(items.first?.kind, .addTask("Reply to Kamil"))
        XCTAssertTrue(items.first!.title.contains("Reply to Kamil"))
    }

    func test_query_filtersCommands() {
        let items = CommandBarEngine.items(query: "age")
        XCTAssertTrue(items.contains { $0.kind == .goAgent })
        XCTAssertFalse(items.contains { $0.kind == .goToday })
    }

    func test_sweepMatches() {
        let items = CommandBarEngine.items(query: "swe")
        XCTAssertTrue(items.contains { $0.kind == .sweep })
    }

    func test_whitespaceOnly_treatedAsEmpty() {
        XCTAssertEqual(CommandBarEngine.items(query: "   ").map(\.kind), [.planDay, .goToday, .goBoard, .goWeek, .goNotes, .goAgent, .sweep, .reindexNotes, .searchNotes])
    }

    func test_boardMatches() {
        XCTAssertTrue(CommandBarEngine.items(query: "board").contains { $0.kind == .goBoard })
    }

    func test_notesCommands() {
        XCTAssertTrue(CommandBarEngine.items(query: "notes").contains { $0.kind == .goNotes })
        XCTAssertTrue(CommandBarEngine.items(query: "reindex").contains { $0.kind == .reindexNotes })
        XCTAssertTrue(CommandBarEngine.items(query: "search").contains { $0.kind == .searchNotes })
    }

    func test_planDayCommand_present() {
        XCTAssertTrue(CommandBarEngine.items(query: "plan").contains { $0.kind == .planDay })
    }
}
