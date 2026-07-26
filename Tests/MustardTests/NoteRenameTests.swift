import XCTest
@testable import MustardKit

final class NoteRenameTests: XCTestCase {
    private let resolveToOld: (String) -> String? = { target in
        // Old note lives at notes/Old.md; links by "Old" (or alias) resolve to it.
        target.caseInsensitiveCompare("Old") == .orderedSame ? "notes/Old.md" : nil
    }

    func test_rewrite_plain_heading_alias_and_embed_forms() {
        let content = """
        plain [[Old]] mid
        heading [[Old#Section]] end
        alias [[Old|see this]] end
        embed ![[Old]] end
        untouched [[Other]] end
        """
        let out = NoteRename.rewrite(content: content, resolve: resolveToOld,
                                     oldPath: "notes/Old.md", newTarget: "New")
        XCTAssertTrue(out.contains("[[New]] mid"))
        XCTAssertTrue(out.contains("[[New#Section]] end"))
        XCTAssertTrue(out.contains("[[New|see this]] end"))
        XCTAssertTrue(out.contains("![[New]] end"))
        XCTAssertTrue(out.contains("[[Other]] end"))
    }

    func test_rewrite_skips_fenced_code() {
        let content = "real [[Old]]\n```\ncode [[Old]] stays\n```\n"
        let out = NoteRename.rewrite(content: content, resolve: resolveToOld,
                                     oldPath: "notes/Old.md", newTarget: "New")
        XCTAssertTrue(out.contains("real [[New]]"))
        XCTAssertTrue(out.contains("code [[Old]] stays"))
    }

    func test_retitle_updates_frontmatter_title_and_first_heading() {
        let content = "---\ntitle: Old\ntags: []\n---\n\n# Old\n\nbody [[keep]]\n"
        let out = NoteRename.retitle(content: content, newTitle: "Fresh Name")
        XCTAssertTrue(out.contains("title: Fresh Name"))
        XCTAssertTrue(out.contains("# Fresh Name"))
        XCTAssertTrue(out.contains("body [[keep]]"))
    }

    func test_plan_composes_newpath_retitle_and_linkedits() {
        let others = [
            (relativePath: "notes/Ref.md", content: "see [[Old]] here"),
            (relativePath: "notes/None.md", content: "no links"),
        ]
        let plan = NoteRename.plan(
            oldRelativePath: "notes/Old.md",
            oldContent: "---\ntitle: Old\n---\n\n# Old\n",
            newTitle: "New",
            others: others,
            existingPaths: ["notes/Ref.md", "notes/None.md"]) // old path excluded by caller
        XCTAssertEqual(plan.newRelativePath, "notes/New.md")
        XCTAssertTrue(plan.renamedNoteContent.contains("title: New"))
        XCTAssertEqual(plan.linkEdits.map(\.relativePath), ["notes/Ref.md"]) // only the note that changed
        XCTAssertTrue(plan.linkEdits.first!.newContent.contains("[[New]]"))
    }
}
