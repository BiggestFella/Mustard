#if os(macOS)
import SwiftUI
import SwiftData

/// One approval-gated action proposal (meeting recorder Task 8, BAK-300):
/// editable title/date/area, evidence chips that seek playback, and
/// Approve / Reject. Approval goes through `MeetingActionApproval` — exactly
/// one local Inbox task, never an outward action.
public struct MeetingActionProposalView: View {
    @Environment(\.modelContext) private var context
    @Bindable private var proposal: MeetingActionProposal
    @Query(sort: \Area.name) private var areas: [Area]
    private let onSeekEvidence: (String) -> Void

    public init(
        proposal: MeetingActionProposal,
        onSeekEvidence: @escaping (String) -> Void
    ) {
        self.proposal = proposal
        self.onSeekEvidence = onSeekEvidence
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch proposal.state {
            case .pending: pendingBody
            case .approved: approvedBody
            case .rejected: rejectedBody
            }
        }
        .padding(12)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Pending (editable, gated)

    private var pendingBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Task title", text: $proposal.title)
                .textFieldStyle(.plain)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textPrimary)
            if let notes = proposal.notes, !notes.isEmpty {
                Text(notes)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 14) {
                schedulePicker
                areaPicker
                if let owner = proposal.owner {
                    Text("for \(owner)")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
            }
            evidenceChips
            HStack(spacing: 10) {
                Button("Approve") {
                    MeetingActionApproval.approve(proposal, context: context)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
                .controlSize(.small)
                Button("Reject") {
                    MeetingActionApproval.reject(proposal, context: context)
                }
                .buttonStyle(.plain)
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private var approvedBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.done)
            VStack(alignment: .leading, spacing: 2) {
                Text(proposal.createdTask?.title ?? proposal.title)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Approved — on your board")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer()
        }
    }

    private var rejectedBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle")
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(proposal.title)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textTertiary)
                .strikethrough()
            Spacer()
        }
    }

    // MARK: - Pieces

    @ViewBuilder private var schedulePicker: some View {
        if let date = proposal.scheduledFor {
            HStack(spacing: 4) {
                DatePicker("", selection: Binding(
                    get: { date },
                    set: { proposal.scheduledFor = $0 }
                ), displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.compact)
                Button {
                    proposal.scheduledFor = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                proposal.scheduledFor = Calendar.current.date(
                    bySettingHour: 9, minute: 0, second: 0,
                    of: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now)
            } label: {
                Label("Schedule", systemImage: "calendar")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var areaPicker: some View {
        Picker("Area", selection: Binding(
            get: { proposal.areaName ?? "" },
            set: { proposal.areaName = $0.isEmpty ? nil : $0 }
        )) {
            Text("No area").tag("")
            ForEach(areas.map(\.name), id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .font(Theme.Fonts.caption)
        .fixedSize()
    }

    @ViewBuilder private var evidenceChips: some View {
        if !proposal.supportingSegmentUIDs.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.textTertiary)
                ForEach(Array(proposal.supportingSegmentUIDs.enumerated()), id: \.offset) { index, uid in
                    Button("evidence \(index + 1)") {
                        onSeekEvidence(uid)
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.accent)
                }
            }
        }
    }
}
#endif
