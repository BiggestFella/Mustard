#if os(macOS)
import SwiftUI
import SwiftData

/// The searchable, correctable transcript (meeting recorder Task 8, BAK-300).
/// Raw text is immutable evidence — corrections live on `correctedText` and
/// render with an "edited" mark; clearing a correction reverts to the raw
/// words. Tapping a timestamp seeks playback via `onSeek`.
public struct MeetingTranscriptView: View {
    @Environment(\.modelContext) private var context
    private let meeting: MeetingRecord
    private let highlightedUID: String?
    private let onSeek: (MeetingTranscriptSegment) -> Void
    @State private var query = ""
    @State private var editingUID: String?
    @State private var correctionText = ""

    public init(
        meeting: MeetingRecord,
        highlightedUID: String?,
        onSeek: @escaping (MeetingTranscriptSegment) -> Void
    ) {
        self.meeting = meeting
        self.highlightedUID = highlightedUID
        self.onSeek = onSeek
    }

    /// Speaker candidates for the per-row correction menu (BAK-335) — same
    /// assembly the coordinator attributes against at finalize, so the menu
    /// never offers a name attribution couldn't have produced on its own.
    private var candidates: [String] {
        MeetingSpeakerCandidateSource.fetch(
            context: context, userTerms: VoiceLexiconUserTerms.load())
    }

    private var segments: [MeetingTranscriptSegment] {
        let all = (meeting.segments ?? [])
            .sorted { ($0.startSeconds, $0.uid) < ($1.startSeconds, $1.uid) }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return all }
        return all.filter { segment in
            segment.rawText.localizedCaseInsensitiveContains(trimmed)
                || (segment.correctedText?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("TRANSCRIPT")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                TextField("Search transcript…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Fonts.caption)
                    .frame(width: 180)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(segments, id: \.uid) { segment in
                row(segment)
            }
            if segments.isEmpty {
                Text(query.isEmpty ? "No transcript." : "No matches.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private func row(_ segment: MeetingTranscriptSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                onSeek(segment)
            } label: {
                Text(MeetingReviewView.timestamp(segment.startSeconds))
                    .font(Theme.Fonts.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
            speakerLabel(segment)
                .frame(width: 64, alignment: .leading)

            if editingUID == segment.uid {
                TextField("Correction", text: $correctionText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .onSubmit { saveCorrection(segment) }
                    .onExitCommand { editingUID = nil }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(segment.correctedText ?? segment.rawText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if segment.correctedText != nil {
                        Text("edited")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .help("Raw: \(segment.rawText)")
                    }
                }
                .onTapGesture(count: 2) {
                    editingUID = segment.uid
                    correctionText = segment.correctedText ?? segment.rawText
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            segment.uid == highlightedUID ? Theme.Palette.accent.opacity(0.10) : .clear,
            in: RoundedRectangle(cornerRadius: 6))
    }

    /// A correction identical to the raw text (or empty) clears back to raw.
    private func saveCorrection(_ segment: MeetingTranscriptSegment) {
        let trimmed = correctionText.trimmingCharacters(in: .whitespacesAndNewlines)
        segment.correctedText = (trimmed.isEmpty || trimmed == segment.rawText) ? nil : trimmed
        try? context.save()
        editingUID = nil
    }

    /// "You" for the you channel (never editable — it's Leon by
    /// construction); the attributed speaker or "Mtg" for the meeting
    /// channel, correctable via a small menu (BAK-335). Render-and-dispatch
    /// only — the menu writes straight to the persisted segment.
    @ViewBuilder
    private func speakerLabel(_ segment: MeetingTranscriptSegment) -> some View {
        if segment.source == .you {
            Text("You")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
        } else {
            Menu {
                Button("None") { setSpeaker(nil, on: segment) }
                ForEach(candidates, id: \.self) { candidate in
                    Button(candidate) { setSpeaker(candidate, on: segment) }
                }
            } label: {
                Text(segment.speaker ?? "Mtg")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
    }

    private func setSpeaker(_ speaker: String?, on segment: MeetingTranscriptSegment) {
        segment.speaker = speaker
        try? context.save()
    }
}
#endif
