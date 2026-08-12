import AppKit
import SwiftUI

/// Pure availability policy for the manual settings action. The automatic-refresh
/// preference deliberately does not participate in Phase 6A manual refreshes.
public enum CodeHeroesQueueRefreshPresentation {
    public static func canRefresh(
        settings: CodeHeroesQueueSettings,
        isImporting: Bool
    ) -> Bool {
        !isImporting
            && !settings.repositoryRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.queuePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Pure presentation policy shared by the Code Heroes projection card and detail view.
/// Repository paths are shown as Finder-reveal affordances, never loaded or copied.
public enum CodeHeroesDecisionPresentation {
    /// Local task mutations exposed across compact surfaces such as Week and Notch.
    /// Repository projections deny every action; ordinary tasks keep existing behavior.
    public enum LocalAction: CaseIterable {
        case toggleCompletion
        case schedule
        case unschedule
        case drag
        case delete
        case resizeEstimate
        case delegate
    }

    public struct SourceFile: Equatable, Identifiable {
        public let label: String
        public let path: String
        public var id: String { path }

        public init(label: String, path: String) {
            self.label = label
            self.path = path
        }
    }

    public static let badgeText = "Code Heroes · repository decision · read-only"
    public static let readOnlyExplanation =
        "This card mirrors a repository decision. Resolve it in the Code Heroes repository; local deletion or stage changes are presentation-only, and the next refresh may restore source-derived state."

    /// Today/List completion and reopen are local mutations, so repository projections
    /// never expose them. Ordinary tasks retain their existing toggle behavior.
    public static func allowsLocalCompletion(for task: MustardTask) -> Bool {
        allows(.toggleCompletion, for: task)
    }

    public static func allows(_: LocalAction, for task: MustardTask) -> Bool {
        return !CodeHeroesDecisionPolicy.isProjection(task)
    }

    /// Imported references are absolute local paths validated by the adapter. Keep this UI
    /// boundary narrow: reject relative paths, URLs, and duplicate references.
    public static func sourceFiles(for task: MustardTask) -> [SourceFile] {
        guard CodeHeroesDecisionPolicy.isProjection(task) else { return [] }

        var result: [SourceFile] = []
        var seen: Set<String> = []
        func append(label: String, rawPath: String?) {
            guard let rawPath else { return }
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/"), URL(string: trimmed)?.scheme == nil else { return }
            let path = URL(fileURLWithPath: trimmed).standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            result.append(.init(label: label, path: path))
        }

        append(label: "Queue", rawPath: task.sourceURL)
        for link in task.links { append(label: link.label, rawPath: link.url) }
        return result
    }
}

/// Identifies a repository decision and, when validated local references exist, offers a
/// non-mutating menu that reveals each source in Finder.
struct CodeHeroesDecisionBadge: View {
    let task: MustardTask

    private var sourceFiles: [CodeHeroesDecisionPresentation.SourceFile] {
        CodeHeroesDecisionPresentation.sourceFiles(for: task)
    }

    var body: some View {
        if sourceFiles.isEmpty {
            badgeLabel
                .accessibilityLabel(CodeHeroesDecisionPresentation.badgeText)
        } else {
            HStack(alignment: .top, spacing: 4) {
                badgeLabel
                    .layoutPriority(1)
                    .accessibilityLabel(CodeHeroesDecisionPresentation.badgeText)
                Menu {
                    ForEach(sourceFiles) { source in
                        Button {
                            reveal(source)
                        } label: {
                            Label("Reveal \(source.label) in Finder", systemImage: "folder")
                        }
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.agentText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Show repository decision sources")
                .accessibilityLabel("Repository decision sources")
                .accessibilityHint("Shows source files in Finder")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var badgeLabel: some View {
        Text(CodeHeroesDecisionPresentation.badgeText)
            .font(.system(size: 9.5, weight: .semibold))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .foregroundStyle(Theme.Palette.agentText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.Palette.agentTintLight, in: RoundedRectangle(cornerRadius: 7))
    }

    private func reveal(_ source: CodeHeroesDecisionPresentation.SourceFile) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)])
    }
}

/// Expanded source list for the read-only detail view. It uses the same Finder-only
/// behavior as the badge menu and intentionally has no add/remove controls.
struct CodeHeroesDecisionSourceLinks: View {
    let task: MustardTask

    private var sourceFiles: [CodeHeroesDecisionPresentation.SourceFile] {
        CodeHeroesDecisionPresentation.sourceFiles(for: task)
    }

    var body: some View {
        if !sourceFiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("SOURCES")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
                ForEach(sourceFiles) { source in
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: source.path)])
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "doc.text")
                            Text(source.label).font(Theme.Fonts.meta)
                            Text(source.path)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.right.circle")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.accent)
                    .help("Reveal \(source.label) in Finder")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
