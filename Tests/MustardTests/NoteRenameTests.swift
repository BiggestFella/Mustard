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

    func test_rewrite_target_is_new_file_stem_on_collision() {
        // notes/New.md already exists → renamed file becomes notes/New 2.md, and inbound
        // links must point at the *stem* "New 2" (not the display title "New", which would
        // resolve to the pre-existing New.md). Review C1.
        let others = [(relativePath: "notes/Ref.md", content: "see [[Old]] here")]
        let plan = NoteRename.plan(
            oldRelativePath: "notes/Old.md",
            oldContent: "# Old\n",
            newTitle: "New",
            others: others,
            existingPaths: ["notes/New.md", "notes/Ref.md"]) // New.md already taken
        XCTAssertEqual(plan.newRelativePath, "notes/New 2.md")
        XCTAssertEqual(plan.linkEdits.first?.newContent, "see [[New 2]] here")
    }

    func test_rewrite_target_is_sanitized_stem() {
        // "A/B" sanitizes to file stem "A-B"; links must use the resolvable stem.
        let others = [(relativePath: "notes/Ref.md", content: "x [[Old]] y")]
        let plan = NoteRename.plan(
            oldRelativePath: "notes/Old.md", oldContent: "# Old\n", newTitle: "A/B",
            others: others, existingPaths: ["notes/Ref.md"])
        XCTAssertEqual(plan.newRelativePath, "notes/A-B.md")
        XCTAssertEqual(plan.linkEdits.first?.newContent, "x [[A-B]] y")
    }

    func test_retitle_ignores_hash_in_frontmatter_and_leading_fence() {
        let content = "---\ntitle: Old\n# reserved for phase B\n---\n\n```\n# not a heading\n```\n\n# Real\n"
        let out = NoteRename.retitle(content: content, newTitle: "Fresh")
        XCTAssertTrue(out.contains("title: Fresh"))
        XCTAssertTrue(out.contains("# reserved for phase B"), "frontmatter comment left intact")
        XCTAssertTrue(out.contains("# not a heading"), "fenced code line left intact")
        XCTAssertTrue(out.contains("# Fresh"), "the real body H1 is the one retitled")
    }

    func test_retitle_updates_frontmatter_title_on_crlf() {
        let content = "---\r\ntitle: Old\r\n---\r\n\r\n# Old\r\n"
        let out = NoteRename.retitle(content: content, newTitle: "Fresh Name")
        XCTAssertTrue(out.contains("title: Fresh Name"), "CRLF frontmatter title still updated")
        XCTAssertTrue(out.contains("# Fresh Name"))
    }

    func test_plan_rewrites_self_links_in_renamed_note() {
        let plan = NoteRename.plan(
            oldRelativePath: "notes/Old.md",
            oldContent: "# Old\n\nsee [[Old#Notes]] above\n",
            newTitle: "New",
            others: [],
            existingPaths: [])
        XCTAssertTrue(plan.renamedNoteContent.contains("[[New#Notes]]"),
                      "a self-link must follow the rename")
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
