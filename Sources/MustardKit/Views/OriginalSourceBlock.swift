import SwiftUI

/// Shared original-source block for triage detail surfaces (BAK-265).
/// Label is source-aware; long bodies collapse behind "Show more" and scroll
/// once expanded so they do not dominate the sheet. Pure SwiftUI — also
/// compiled into the iOS companion (see `project.yml`).
public struct OriginalSourceBlock: View {
    let text: String
    let source: String
    let sourceURL: String?
    /// Expanded long-body viewport — matches the proposed-draft editor max height.
    var expandedMaxHeight: CGFloat = 220

    @State private var expanded = false

    public init(text: String, source: String, sourceURL: String?,
                expandedMaxHeight: CGFloat = 220) {
        self.text = text
        self.source = source
        self.sourceURL = sourceURL
        self.expandedMaxHeight = expandedMaxHeight
    }

    public init(rec: Recommendation, expandedMaxHeight: CGFloat = 220) {
        self.init(text: rec.originalSource ?? "", source: rec.source,
                  sourceURL: rec.sourceURL, expandedMaxHeight: expandedMaxHeight)
    }

    private var collapsible: Bool { OriginalSourceDisplay.isCollapsible(text) }
    private var shown: String {
        (collapsible && !expanded) ? OriginalSourceDisplay.collapsed(text) : text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(OriginalSourceDisplay.sectionLabel(source: source, sourceURL: sourceURL))
                .font(Theme.Fonts.sectionHeader)
                .tracking(0.06)
                .foregroundStyle(Theme.Palette.textTertiary)
            if collapsible && expanded {
                ScrollView {
                    Text(text)
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: expandedMaxHeight)
            } else {
                Text(shown)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .textSelection(.enabled)
            }
            if collapsible {
                Button(expanded ? "Show less" : "Show more") {
                    withAnimation(Theme.Motion.expand) { expanded.toggle() }
                }
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.accent)
                .buttonStyle(.plain)
            }
        }
    }
}
