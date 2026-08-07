#if os(macOS)
import SwiftUI

/// The meeting-start suggestion prompt (meeting recorder Task 9, BAK-301),
/// rendered inside the expanded notch: Start · Not now · Don't prompt for
/// this event. Start goes through the SAME manual consent path as the
/// Start Meeting button — a suggestion can never begin capture by itself.
public struct MeetingStartPromptView: View {
    @Environment(MeetingSuggestionMonitor.self) private var monitor: MeetingSuggestionMonitor?
    @Environment(MeetingCaptureCoordinator.self) private var recorder: MeetingCaptureCoordinator?

    public init() {}

    public var body: some View {
        if let monitor, let recorder,
           let suggestion = monitor.suggestion,
           recorder.state == .idle {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: "#FF5F57"))
                    Text("Looks like \(suggestion.title) is starting")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                HStack(spacing: 12) {
                    Button("Record…") {
                        // The consent prompt still gates everything.
                        Task { await recorder.requestStart(title: suggestion.title) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    Button("Not now") { monitor.snooze(suggestion) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                    Button("Don't prompt for this") { monitor.dismiss(suggestion) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }
}
#endif
