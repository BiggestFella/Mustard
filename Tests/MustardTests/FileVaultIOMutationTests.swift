import XCTest
@testable import MustardKit

final class FileVaultIOMutationTests: XCTestCase {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mustard-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func test_move_relocates_file() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let io = FileVaultIO(root: root)
        try io.write("notes/Old.md", "# Old\n")
        try io.move(from: "notes/Old.md", to: "notes/New.md")
        XCTAssertNil(io.read("notes/Old.md"))
        XCTAssertEqual(io.read("notes/New.md"), "# Old\n")
    }

    func test_trash_removes_from_vault() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let io = FileVaultIO(root: root)
        try io.write("notes/Doomed.md", "bye\n")
        try io.trash("notes/Doomed.md")
        XCTAssertNil(io.read("notes/Doomed.md"))
        XCTAssertFalse(io.notePaths().contains("notes/Doomed.md"))
    }
}
