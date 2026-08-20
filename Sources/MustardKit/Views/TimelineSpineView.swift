import SwiftUI

/// Renders the Today spine: days flowing forward, each a merged chronological agenda.
/// Task items reuse the shared condensed `TimelineRow` (BAK-245 — time is a chip,
/// no left gutter). Calendar events stay on the spine as a matching chip row.
/// Today's elapsed items dim; a coral "now" line marks the present. Tapping a
/// task opens the detail drawer; the row checkbox toggles done.
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
                .padding(.leading, 8)
                .padding(.top, 6)
                .padding(.bottom, 8)
        case .now:
            HStack(spacing: 8) {
                Circle().fill(Theme.Palette.now).frame(width: 7, height: 7)
                Text(now.formatted(.dateTime.hour().minute()))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.now)
                Rectangle().fill(Theme.Palette.nowLine).frame(height: 1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        case .item(let item):
            let isPast = isToday && TimelineSpine.isPast(item, relativeTo: now)
            switch item.kind {
            case .task(let task):
                TimelineRow(
                    task: task,
                    onToggleDone: { onToggleDone(task) },
                    onOpen: { onOpen(task) }
                )
                .opacity(isPast ? 0.5 : 1)
            case .event:
                SpineEventRow(item: item, isPast: isPast)
            }
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

/// Calendar event on the spine: same condensed vocabulary as a task row (time is
/// a chip, no gutter) so meetings stay interleaved with work.
private struct SpineEventRow: View {
    let item: AgendaItem
    let isPast: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "calendar")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.top, 4)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: TaskRowDensity.condensed.rowSpacing) {
                Text(item.title)
                    .font(.system(size: TaskRowDensity.condensed.titleSize, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowMeta(spacing: 6) {
                    MetaChip(
                        systemImage: "clock",
                        TaskRowPresentation.eventTimeLabel(
                            isAllDay: item.time == nil,
                            start: item.time ?? .now,
                            calendar: .current
                        )
                    )
                    if let join = item.joinURL, let url = URL(string: join) {
                        Link(destination: url) {
                            MetaChip("Join ↗", tint: Theme.Palette.accent)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, TaskRowDensity.condensed.vPadding)
        .padding(.horizontal, 8)
        .opacity(isPast ? 0.5 : 1)
        .background(hovering ? Theme.Palette.titleBar : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.rMd))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Motion.settle, value: hovering)
    }
}
