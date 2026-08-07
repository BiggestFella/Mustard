import Foundation

/// One command in the editor's "/" menu (Craft spec 2026-07-06/2026-07-12, Phase
/// 2b then Phase 2 / BAK-251). `group` is display-only metadata (which quiet-caps
/// section `SlashMenuView` renders the row under) — it never affects filtering or
/// keyboard order: `items(query:)` still returns one flat array in group-then-
/// declaration order, and the view/coordinator keep treating it as such.
public struct SlashCommand: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let icon: String
    public let kind: Kind
    public let group: Group

    /// `heading`'s `Int` is the level (1...4 — the four levels this menu offers;
    /// see `BlockKind.heading`'s doc for why the underlying model doesn't clamp to
    /// this range, it's just what THIS menu happens to offer).
    public enum Kind: Equatable {
        case heading(Int)
        case quote
        case bulletList, numberedList, checkList
        case paragraph
        case codeBlock
        case divider
        case table
        case image
        case linkToNote, subpage, askAgent
    }

    /// Display grouping, matching the reference shot's section order (Craft spec
    /// 2026-07-12): Headings, Basic blocks, Advanced, Media.
    public enum Group: String, CaseIterable, Equatable {
        case headings = "Headings"
        case basicBlocks = "Basic blocks"
        case advanced = "Advanced"
        case media = "Media"
    }

    public init(id: String, title: String, icon: String, kind: Kind, group: Group) {
        self.id = id
        self.title = title
        self.icon = icon
        self.kind = kind
        self.group = group
    }
}

/// Pure query → commands for the editor's "/" menu (Craft spec, 2b then Phase 2 /
/// BAK-251), plus trigger detection and the markdown each command splices.
/// Insertions are the ONLY source text this menu produces — pinned byte-exact in
/// SlashMenuTests (markdown-as-truth: `NoteDecoration` stays read-only;
/// `BlockReorder.move` and `insertion(for:noteTitle:)` are the two source-producing
/// functions in the whole editor).
///
/// Shape mirrors `CommandBarEngine` (static item list, `items(query:)` filter) so
/// the two command surfaces stay conceptually one pattern.
public enum SlashMenu {

    private static let commands: [SlashCommand] = [
        // MARK: Headings
        SlashCommand(id: "h1", title: "Heading 1", icon: "textformat.size", kind: .heading(1), group: .headings),
        SlashCommand(id: "h2", title: "Heading 2", icon: "textformat.size", kind: .heading(2), group: .headings),
        SlashCommand(id: "h3", title: "Heading 3", icon: "textformat.size", kind: .heading(3), group: .headings),
        SlashCommand(id: "h4", title: "Heading 4", icon: "textformat.size", kind: .heading(4), group: .headings),

        // MARK: Basic blocks
        SlashCommand(id: "quote", title: "Quote", icon: "quote.opening", kind: .quote, group: .basicBlocks),
        SlashCommand(id: "bullet", title: "Bullet List", icon: "list.bullet", kind: .bulletList, group: .basicBlocks),
        SlashCommand(id: "numbered", title: "Numbered List", icon: "list.number", kind: .numberedList, group: .basicBlocks),
        SlashCommand(id: "checklist", title: "Check List", icon: "checkmark.square", kind: .checkList, group: .basicBlocks),
        SlashCommand(id: "paragraph", title: "Paragraph", icon: "paragraphsign", kind: .paragraph, group: .basicBlocks),
        SlashCommand(id: "codeblock", title: "Code Block", icon: "chevron.left.forwardslash.chevron.right", kind: .codeBlock, group: .basicBlocks),
        SlashCommand(id: "divider", title: "Divider", icon: "minus", kind: .divider, group: .basicBlocks),

        // MARK: Advanced
        SlashCommand(id: "table", title: "Table", icon: "tablecells", kind: .table, group: .advanced),
        SlashCommand(id: "link", title: "Link to note", icon: "link", kind: .linkToNote, group: .advanced),
        SlashCommand(id: "subpage", title: "Sub-page", icon: "doc.badge.plus", kind: .subpage, group: .advanced),
        SlashCommand(id: "agent", title: "Ask the agent", icon: "sparkles", kind: .askAgent, group: .advanced),

        // MARK: Media (syntax-only — no thumbnail; see `NoteDecoration.isImageLine`)
        SlashCommand(id: "image", title: "Image", icon: "photo", kind: .image, group: .media),
    ]

    /// Filter: case-insensitive PREFIX match against any whitespace-separated word
    /// of the title. Deliberately not `CommandBarEngine`'s substring-contains —
    /// with these titles, "he" would leak "Ask *the* agent" in via "the", which is
    /// exactly the wrong row two keystrokes into "heading". Word-prefix matches
    /// how a slash query is actually typed (the start of the command you mean).
    /// "he" now legitimately matches all four Heading rows (each title's first
    /// word is "Heading") — that's the filter doing its job, not a regression;
    /// a query of exactly "1"/"2"/"3"/"4" narrows to one row via the digit word.
    public static func items(query: String) -> [SlashCommand] {
        guard !query.isEmpty else { return commands }
        let lowered = query.lowercased()
        return commands.filter { command in
            command.title.split(whereSeparator: { $0.isWhitespace }).contains { word in
                word.lowercased().hasPrefix(lowered)
            }
        }
    }

    /// Non-nil (the query typed so far) when the caret sits in an active trigger:
    /// the line up to the caret must be exactly "/" + query, query containing no
    /// whitespace. "a /x" (mid-line slash) or "/x y" (query ended) is not a trigger —
    /// the menu only ever interrupts a line the user just started with "/".
    public static func activeQuery(linePrefix: String) -> String? {
        guard linePrefix.hasPrefix("/") else { return nil }
        let query = String(linePrefix.dropFirst())
        guard !query.contains(where: { $0.isWhitespace }) else { return nil }
        return query
    }

    /// Markdown to splice at line start + caret offset (UTF-16 units into `text`)
    /// after insertion. `.subpage`/`.linkToNote` interpolate the chosen/created
    /// note title. Every template is byte-pinned in SlashMenuTests, and every new
    /// (Phase 2 / BAK-251) template round-trips losslessly through
    /// `NoteDecoration.blocks(_:)` and classifies to the expected `BlockKind` —
    /// see the round-trip guard section of SlashMenuTests.
    ///
    /// "Ask the agent" deliberately just writes an `[!agent]` callout line — plain
    /// markdown the existing vault sweep already reads on its next pass. No new
    /// AgentService plumbing; the restraint is the feature (the file stays the
    /// only contract between the editor and the agent).
    public static func insertion(for kind: SlashCommand.Kind, noteTitle: String?) -> (text: String, caretOffset: Int) {
        switch kind {
        case .heading(let level):
            let clamped = max(1, min(level, 6))
            return atEnd(String(repeating: "#", count: clamped) + " ")
        case .quote:
            return atEnd("> ")
        case .bulletList:
            return atEnd("- ")
        case .numberedList:
            return atEnd("1. ")
        case .checkList:
            return atEnd("- [ ] ")
        case .paragraph:
            // Empty splice: the trigger's "/query" text is simply erased (the
            // caller replaces `triggerRange` with this text), leaving a plain
            // line with the caret where the trigger started — "dismisses to
            // plain text" per spec, no markdown written at all.
            return (text: "", caretOffset: 0)
        case .codeBlock:
            // Caret lands on the blank interior line (inside the fence), not at
            // the end — so typing starts the code immediately, same reasoning
            // as `.image`'s url-slot placement below.
            let text = "```\n\n```"
            return (text: text, caretOffset: ("```\n" as NSString).length)
        case .divider:
            return atEnd("---\n")
        case .table:
            // Minimal 2x2 markdown pipe table (header row + separator + one data
            // row) — full table LAYOUT is out of scope (spec); this only needs to
            // classify as `.table` (`NoteDecoration.isTableBlock`) and render as
            // plain text, which it already does with no further decoration work
            // (see NoteDecoration doc / this ticket's report). Caret lands at the
            // end — editing a specific cell already requires clicking into it,
            // same as any other multi-line template.
            return atEnd("| Header 1 | Header 2 |\n| --- | --- |\n| Cell 1 | Cell 2 |\n")
        case .image:
            // "![]()" — caret lands between the parens (the url slot) so typing
            // immediately fills in the URL; matches `NoteDecoration.isImageLine`'s
            // bare `![alt](url)` shape (empty alt here, same as an empty link).
            let text = "![]()"
            return (text: text, caretOffset: ("![](" as NSString).length)
        case .linkToNote:
            if let noteTitle, !noteTitle.isEmpty {
                return atEnd("[[\(noteTitle)]]")
            }
            // Empty brackets, caret between them — the user types the target and
            // the existing resolve/create-from-dangling flows take over.
            return (text: "[[]]", caretOffset: 2)
        case .subpage:
            // Deliberately a DANGLING link — no file is created by the splice
            // (deep-review: file-creation inside an undoable edit breaks ⌘Z
            // symmetry and mints orphans on undo→retry). Clicking the link runs
            // the existing confirmed create-from-dangling flow, which owns
            // collision dedupe. "Untitled" mirrors NoteCreation's fallback.
            let title = (noteTitle?.isEmpty == false) ? noteTitle! : "Untitled"
            return atEnd("[[\(title)]]\n")
        case .askAgent:
            return atEnd("> [!agent] ")
        }
    }

    /// Caret lands after the last inserted character. UTF-16 length, because the
    /// caller adds this to an NSTextView `selectedRange` location.
    private static func atEnd(_ text: String) -> (text: String, caretOffset: Int) {
        (text: text, caretOffset: (text as NSString).length)
    }
}
