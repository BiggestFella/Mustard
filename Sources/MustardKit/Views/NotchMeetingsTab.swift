#if os(macOS)
import SwiftUI
import SwiftData

/// Meetings tab: recorder (moved from Today), upcoming meetings, recent
/// recordings. Consent stays in `MeetingCaptureCoordinator` — this renders
/// and dispatches only. The notch is intentionally dark: explicit hex, never
/// `Theme` (see CLAUDE.md).
struct NotchMeetingsTab: View {
    @Environment(NotchNavigation.self) private var nav
    @Query(sort: \CalendarEvent.start) private var events: [CalendarEvent]
    @Query(sort: \MeetingRecord.createdAt, order: .reverse) private var meetings: [MeetingRecord]

    private var upcoming: [CalendarEvent] {
        events.filter { $0.start > .now && Calendar.current.isDateInToday($0.start) }
            .prefix(3).map { $0 }
    }

    private var recent: [MeetingRecord] {
        meetings.filter { $0.status != .preparing }.prefix(10).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                MeetingRecordingNotchView()

                if !upcoming.isEmpty {
                    sectionHeader("UPCOMING")
                    ForEach(upcoming, id: \.persistentModelID) { event in
                        HStack(spacing: 8) {
                            Text(event.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 44, alignment: .leading)
                            Text(event.title)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                            Spacer()
                            if let join = event.joinURL, let url = URL(string: join) {
                                Link("Join", destination: url)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(hex: "#6E9FFF"))
                            }
                        }
                    }
                }

                sectionHeader("RECENT RECORDINGS")
                if recent.isEmpty {
                    Text("No recordings yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
                ForEach(recent, id: \.uid) { meeting in
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meeting.title.isEmpty ? "Meeting" : meeting.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1)
                            Text(subtitle(for: meeting))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                        statusBadge(meeting.status)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { nav.pendingMeetingUID = meeting.uid }
                }
            }
        }
        .frame(maxHeight: 340)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.08)
            .foregroundStyle(.white.opacity(0.4))
    }

    private func subtitle(for meeting: MeetingRecord) -> String {
        var parts: [String] = []
        if let started = meeting.startedAt {
            parts.append(started.formatted(date: .abbreviated, time: .shortened))
            if let ended = meeting.endedAt {
                let minutes = Int(ended.timeIntervalSince(started) / 60)
                parts.append("\(minutes) min")
            }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusBadge(_ status: MeetingStatus) -> some View {
        let (label, hex): (String, String) = switch status {
        case .ready: ("Ready", "#5DCAA5")
        case .partial: ("Partial", "#FFBD2E")
        case .failed: ("Failed", "#FF5F57")
        case .recording: ("Recording", "#FF5F57")
        default: ("…", "#FFFFFF")
        }
        Text(label)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Color(hex: hex))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(hex: hex).opacity(0.15), in: Capsule())
    }
}
#endif
