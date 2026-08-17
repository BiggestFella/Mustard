import SwiftUI

/// Shared opened-task chrome (BAK-244). Lives in SharedUI so the desktop
/// `TaskDetailSheet` and iOS `MobileTaskSheet` render the same read-first look.
/// Tokens only — `Theme.Fonts` / `Theme.Palette` / `Theme.Metrics`.

struct TaskStageBadge: View {
    let stage: TaskStage
    let owner: TaskOwner

    var body: some View {
        Text(stage.label.uppercased())
            .font(Theme.Fonts.sectionHeader)
            .tracking(0.06)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var color: Color {
        owner == .agent ? Theme.Palette.agentText : Theme.Palette.statusMutedText
    }
}

struct TaskDetailSectionLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(Theme.Fonts.sectionHeader)
            .tracking(0.08)
            .foregroundStyle(Theme.Palette.textTertiary)
    }
}

struct TaskDetailReadPropertyRow: View {
    let label: String
    let value: String
    var showDivider: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showDivider {
                Divider().overlay(Theme.Palette.hairline)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 96, alignment: .leading)
                Text(value)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Palette.onSurface)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
        }
    }
}

struct TaskDetailTagPills: View {
    let tags: [String]

    var body: some View {
        FlowMeta(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text("# \(tag)")
                    .font(Theme.Fonts.label)
                    .foregroundStyle(Theme.Palette.onSurfaceSoft)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Theme.Palette.bg, in: Capsule())
                    .overlay(Capsule().stroke(Theme.Palette.divider, lineWidth: 0.5))
            }
        }
    }
}

struct TaskDetailGlanceChips: View {
    let owner: TaskOwner
    let dueAt: Date?
    let scheduledAt: Date?
    let isTimed: Bool
    let estimateMinutes: Int
    let isDone: Bool

    var body: some View {
        let overdue = dueAt.map { $0 < .now && !isDone } ?? false
        FlowMeta(spacing: 6) {
            MetaChip(
                TaskDetailPresentation.ownerGlance(owner),
                tint: owner == .agent ? Theme.Palette.agentText : Theme.Palette.textSecondary
            )
            if isTimed, let when = scheduledAt {
                MetaChip(systemImage: "clock",
                         when.formatted(date: .abbreviated, time: .shortened))
            }
            if let due = dueAt {
                MetaChip(systemImage: "calendar",
                         "Due \(due.formatted(.dateTime.month(.abbreviated).day()))",
                         tint: overdue ? Theme.Palette.warnText : Theme.Palette.textSecondary)
            }
            if TaskDetailPresentation.showsGlanceEstimate(estimateMinutes) {
                MetaChip(systemImage: "timer", "\(estimateMinutes)m")
            }
        }
    }
}

struct TaskDetailCompleteCircle: View {
    let isDone: Bool
    let isAgent: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isDone ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(
                    isDone ? Theme.Palette.done
                    : (isAgent ? Theme.Palette.agent : Theme.Palette.textTertiary)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
    }
}

/// BAK-137 agent context: gated notice, confidence bars, WHY, draft.
/// Shown on the read surface (and kept visible while editing) whenever the
/// task carries agent provenance.
struct TaskDetailAgentContextBlock: View {
    let isGated: Bool
    let confidence: Double?
    let why: String
    let draft: String

    var body: some View {
        if TaskDetailPresentation.hasAgentContext(
            confidence: confidence, why: why, draft: draft, isGated: isGated
        ) {
            VStack(alignment: .leading, spacing: 12) {
                if isGated {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: "lock.fill").font(Theme.Fonts.caption)
                        Text("Gated action — always reviewed by you, whatever the trust level.")
                            .font(Theme.Fonts.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.Palette.statusMutedText)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(Theme.Palette.titleBar, in: RoundedRectangle(cornerRadius: Theme.Metrics.rMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Metrics.rMd)
                            .stroke(Theme.Palette.hairline, lineWidth: 0.5)
                    )
                }
                if let confidence {
                    HStack(spacing: 8) {
                        Text("Confidence")
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Text(String(format: "%.2f", confidence))
                            .font(Theme.Fonts.meta.weight(.semibold))
                            .foregroundStyle(Theme.confidenceColor(confidence))
                        HStack(spacing: 2) {
                            ForEach(0..<5, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(i < Int((confidence * 5).rounded(.down))
                                          ? Theme.confidenceColor(confidence)
                                          : Theme.Palette.confidenceUnfilled)
                                    .frame(width: 16, height: 5)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                if !why.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        TaskDetailSectionLabel(title: "Why")
                        Text(why)
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(Theme.Palette.onSurfaceSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        TaskDetailSectionLabel(title: "Draft")
                        Text(draft)
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(Theme.Palette.onSurface)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(13)
                            .elevation(.card, cornerRadius: Theme.Metrics.rLg)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TaskDetailSubtaskRow: View {
    let title: String
    let isDone: Bool
    var showRemove: Bool = false
    let onToggle: () -> Void
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: onToggle) {
                Image(systemName: isDone ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isDone ? Theme.Palette.done : Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Mark subtask not done" : "Mark subtask done")

            Text(title)
                .font(Theme.Fonts.meta)
                .strikethrough(isDone, color: Theme.Palette.strikethrough)
                .foregroundStyle(isDone ? Theme.Palette.textMuted : Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if showRemove, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textFaint)
                }
                .buttonStyle(.plain)
                .help("Remove subtask")
            }
        }
    }
}
