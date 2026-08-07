import SwiftUI

/// Renders the Today spine: days flowing forward, each a merged chronological agenda on
/// a continuous rail. Ownership is carried by dot colour (grey event / blue you / purple
/// agent); today's elapsed items dim; a coral "now" line marks the present. Tapping a
/// task opens the detail drawer; the dot toggles a task's done state.
public struct TimelineSpineView: View {
    private let days: [SpineDay]
    private let now: Date
    private let onToggleDone: (MustardTask) -> Void
    private let onOpen: (MustardTask) -> Void

    public init(days: [SpineDay], now: Date,
                onToggleDone: @escaping (MustardTask) -> Void,
                onOpen: @escaping (MustardTask) -> Void) {
        self.days = days
        self.now = now
        self.onToggleDone = onToggleDone
        self.onOpen = onOpen
    }

    /// A single rendered line of the spine: a band marker, the now line, or an item.
    private enum Row: Identifiable {
        case band(TimeBand)
        case now
        case item(AgendaItem)
        var id: String {
            switch self {
            case .band(let b): "band:\(b.rawValue)"
            case .now: "now"
            case .item(let i): "item:\(i.id)"
            }
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: 0) {
                    Text(headerText(day.label))
                        .font(Theme.Fonts.label)
                        .tracking(0.6)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.bottom, 10)
                    ForEach(rows(for: day)) { row in
                        rowView(row, isToday: day.label == .today)
                    }
                }
            }
        }
    }

    // MARK: Row assembly (presentation sequencing)

    /// Ordered rows for a day: soft band markers (TODAY only) when the band changes among
    /// timed items, and the coral now line inserted before the first still-upcoming item.
    private func rows(for day: SpineDay) -> [Row] {
        let isToday = day.label == .today
        var out: [Row] = []
        var lastBand: TimeBand?
        var nowInserted = false
        for item in day.items {
            if isToday, !nowInserted, let t = item.time, t >= now {
                out.append(.now)
                nowInserted = true
            }
            if isToday, let band = TimeBand.of(item.time), band != lastBand {
                out.append(.band(band))
                lastBand = band
            }
            out.append(.item(item))
        }
        return out
    }

    @ViewBuilder private func rowView(_ row: Row, isToday: Bool) -> some View {
        switch row {
        case .band(let band):
            Text(band.label.uppercased())
                .font(Theme.Fonts.caption)
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.textFaint)
                .padding(.leading, 58)
                .padding(.top, 6)
                .padding(.bottom, 8)
        case .now:
            HStack(spacing: 6) {
                Text(now.formatted(.dateTime.hour().minute()))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.now)
                    .frame(width: 44, alignment: .trailing)
                Circle().fill(Theme.Palette.now).frame(width: 7, height: 7)
                Rectangle().fill(Theme.Palette.nowLine).frame(height: 1)
            }
            .padding(.vertical, 4)
        case .item(let item):
            SpineItemRow(
                item: item,
                isPast: isToday && TimelineSpine.isPast(item, relativeTo: now),
                onToggleDone: onToggleDone,
                onOpen: onOpen
            )
        }
    }

    private func headerText(_ label: SpineDayLabel) -> String {
        switch label {
        case .today: "TODAY"
        case .tomorrow: "TOMORROW"
        case .other(let d): d.formatted(.dateTime.weekday(.abbreviated).day()).uppercased()
        }
    }
}

/// One item on the spine: time gutter · coloured dot (a done-toggle for tasks) · title
/// with an agent-stage suffix and optional area tag.
private struct SpineItemRow: View {
    let item: AgendaItem
    let isPast: Bool
    let onToggleDone: (MustardTask) -> Void
    let onOpen: (MustardTask) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timeText)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 2)

            dot.padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(item.isDone ? Theme.Palette.textMuted : Theme.Palette.textPrimary)
                        .strikethrough(item.isDone, color: Theme.Palette.strikethrough)
                    if let suffix = agentSuffix {
                        Text("· \(suffix)")
                            .font(Theme.Fonts.meta)
                            .foregroundStyle(Theme.Palette.agentText)
                    }
                }
                if let tag = item.tagLabel {
                    Text(tag)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(isPast ? 0.5 : 1)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            if case let .task(t) = item.kind { onOpen(t) }
        }
    }

    private var timeText: String {
        guard let time = item.time else { return "" }
        return time.formatted(.dateTime.hour().minute())
    }

    @ViewBuilder private var dot: some View {
        switch item.kind {
        case .event:
            Circle().fill(Theme.Palette.textTertiary).frame(width: 8, height: 8)
        case .task(let t):
            Button {
                onToggleDone(t)
            } label: {
                Image(systemName: item.isDone ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(item.isDone ? Theme.Palette.done
                                     : (t.owner == .agent ? Theme.Palette.agent : Theme.Palette.accent))
            }
            .buttonStyle(.plain)
        }
    }

    /// Short agent-stage suffix for an agent-owned task (mirrors `DelegationBadge`).
    private var agentSuffix: String? {
        guard case let .task(t) = item.kind, t.owner == .agent else { return nil }
        switch t.stage {
        case .forAgent: return "for agent"
        case .needsApproval: return "approve"
        case .queued: return "queued"
        case .inProgress: return "working"
        case .needsInput: return "reply"
        case .needsReview: return "review"
        default: return nil
        }
    }
}
