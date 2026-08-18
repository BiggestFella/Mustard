import SwiftUI

/// Non-scrolling markdown block stack — renders the parsed blocks through the pure
/// `MarkdownBlocks.parse`, isolating `[[wikilinks]]` as tappable link runs.
/// Extracted from the preview so other surfaces can render agent markdown inline;
/// hosts with no wikilink graph pass `{ _ in nil }` / `{ _ in }`.
///
/// `resolve` colours wikilinks (accent when the target resolves, tertiary when it
/// dangles); a tap routes the raw target through `onWikilinkTap`, and the host
/// navigates to it or offers to create it (BAK-152).
struct MarkdownBlocksView: View {
    /// Frontmatter-stripped markdown. Named `content` (not `body`) to avoid
    /// colliding with SwiftUI's required `var body`.
    let content: String
    let resolve: (String) -> NoteRef?
    let onWikilinkTap: (String) -> Void
    /// Paragraph/list/quote type — hosts pick `Theme.Fonts.reading` for long-form
    /// content (Craft pass Phase 1); headings and code keep their own sizes.
    var bodyFont: Font = Theme.Fonts.body

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlocks.parse(content).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Wikilink taps ride the shared mustard-note:// scheme (WikilinkURL — one
        // encoding with the live editor's NSTextStorage links).
        .environment(\.openURL, OpenURLAction { url in
            if let target = WikilinkURL.target(from: url) {
                onWikilinkTap(target)
                return .handled
            }
            return .systemAction
        })
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, runs):
            flowingText(runs)
                .font(.system(size: headingSize(level), weight: .medium))
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.top, headingTopPadding(level))

        case let .paragraph(runs):
            flowingText(runs)
                .font(bodyFont)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .bullet(runs, indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Theme.Palette.textTertiary)
                flowingText(runs)
                    .font(bodyFont)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineSpacing(3)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(indent) * 16)

        case let .ordered(runs, indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("·").foregroundStyle(Theme.Palette.textTertiary)
                flowingText(runs)
                    .font(bodyFont)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineSpacing(3)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(indent) * 16)

        case let .quote(runs):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Theme.Palette.hairline)
                    .frame(width: 2)
                flowingText(runs)
                    .font(bodyFont)
                    .foregroundStyle(Theme.Palette.onSurfaceSoft)
                    .lineSpacing(3)
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .code(code):
            Text(code)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Theme.Palette.textPrimary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 6))

        case .rule:
            Divider().overlay(Theme.Palette.hairline)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 18
        default: return 15.5
        }
    }

    private func headingTopPadding(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 8
        case 2: return 6
        default: return 4
        }
    }

    // MARK: - Inline runs → one flowing Text

    /// Concatenate a block's runs into a single `Text` so bold/italic/inline-code
    /// (via `AttributedString(markdown:)`) and wikilinks flow as one wrapped line.
    private func flowingText(_ runs: [InlineRun]) -> Text {
        runs.reduce(Text("")) { acc, run in
            switch run {
            case let .text(s):
                return acc + Text(inlineMarkdown: s)
            case let .wikilink(target, alias):
                return acc + wikilinkText(target: target, alias: alias)
            }
        }
    }

    private func wikilinkText(target: String, alias: String?) -> Text {
        var attributed = AttributedString(alias ?? target)
        if let url = WikilinkURL.url(for: target) {
            attributed.link = url
        }
        attributed.foregroundColor = resolve(target) != nil
            ? Theme.Palette.accent
            : Theme.Palette.textTertiary
        attributed.underlineStyle = .single
        return Text(attributed)
    }
}

extension Text {
    /// Renders inline markdown (**bold**, *italic*, `code`) via `AttributedString`.
    /// `.inlineOnlyPreservingWhitespace` keeps this a single-line inline transform —
    /// no block parsing, no whitespace collapsing — with a plain-string fallback if
    /// the string isn't valid inline markdown.
    init(inlineMarkdown string: String) {
        if let attributed = try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            self = Text(attributed)
        } else {
            self = Text(string)
        }
    }
}
