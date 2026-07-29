#if os(macOS)
import SwiftUI
import SwiftData
import AVFoundation

/// Mixed-track playback for one meeting (meeting recorder Task 8): a thin
/// AVAudioPlayer wrapper the review surface drives — play/pause, scrub, and
/// evidence-timestamp seeking.
@MainActor
@Observable
public final class MeetingPlaybackController {
    private var player: AVAudioPlayer?
    public private(set) var isPlaying = false
    public private(set) var loadedPath: String?

    public init() {}

    public var duration: TimeInterval { player?.duration ?? 0 }
    public var currentTime: TimeInterval { player?.currentTime ?? 0 }

    public func load(relativePath: String?) {
        guard let relativePath, relativePath != loadedPath else { return }
        let url = URL.applicationSupportDirectory
            .appending(path: "Mustard", directoryHint: .isDirectory)
            .appending(path: relativePath)
        player?.stop()
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        loadedPath = relativePath
        isPlaying = false
    }

    public func toggle() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    public func seek(to seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), max(0, player.duration - 0.1))
        if !isPlaying {
            player.play()
            isPlaying = true
        }
    }
}

/// Meeting review (meeting recorder Task 8, BAK-300): recordings list →
/// playback, digest (summary/decisions/questions, retry states), approval-
/// gated proposals, and the searchable, correctable transcript. Selecting
/// evidence seeks playback and highlights the segment.
public struct MeetingReviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(MeetingCaptureCoordinator.self) private var recorder: MeetingCaptureCoordinator?
    @Query(sort: \MeetingRecord.createdAt, order: .reverse) private var meetings: [MeetingRecord]
    @State private var selectedUID: String?
    @State private var playback = MeetingPlaybackController()
    @State private var highlightedSegmentUID: String?

    public init() {}

    private var selected: MeetingRecord? {
        meetings.first { $0.uid == selectedUID } ?? meetings.first
    }

    public var body: some View {
        HStack(spacing: 0) {
            list
            Divider().overlay(Theme.Palette.hairline)
            if let meeting = selected {
                detail(meeting)
            } else {
                emptyState
            }
        }
        .background(Theme.Palette.bg)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Meetings")
                    .font(Theme.Fonts.header)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.bottom, 10)
                ForEach(meetings, id: \.uid) { meeting in
                    Button {
                        selectedUID = meeting.uid
                        highlightedSegmentUID = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                if let startedAt = meeting.startedAt {
                                    Text(startedAt.formatted(date: .abbreviated, time: .shortened))
                                }
                                statusBadge(meeting)
                            }
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selected?.uid == meeting.uid ? Theme.Palette.surface : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .frame(width: 260)
    }

    @ViewBuilder
    private func statusBadge(_ meeting: MeetingRecord) -> some View {
        switch meeting.status {
        case .ready: Text("Ready")
        case .partial: Text("Interrupted").foregroundStyle(Theme.Palette.warning)
        case .failed: Text("Failed").foregroundStyle(Theme.Palette.warning)
        case .recording: Text("Recording…").foregroundStyle(Theme.Palette.accent)
        case .finalizing: Text("Finishing…")
        case .preparing: Text("Preparing…")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "mic")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text("No meetings recorded yet")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text("Start one from the notch — hover it and press Start Meeting.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Detail

    private func detail(_ meeting: MeetingRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(meeting)
                playbackBar(meeting)
                digestSection(meeting)
                proposalsSection(meeting)
                MeetingTranscriptView(
                    meeting: meeting,
                    highlightedUID: highlightedSegmentUID,
                    onSeek: { segment in
                        highlightedSegmentUID = segment.uid
                        playback.seek(to: segment.startSeconds)
                    })
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .onAppear { playback.load(relativePath: meeting.playbackAudioPath ?? meeting.youAudioPath) }
        .onChange(of: meeting.uid) {
            playback.load(relativePath: meeting.playbackAudioPath ?? meeting.youAudioPath)
        }
    }

    private func header(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)
                .font(Theme.Fonts.header)
                .foregroundStyle(Theme.Palette.textPrimary)
            HStack(spacing: 8) {
                if let startedAt = meeting.startedAt {
                    Text(startedAt.formatted(date: .complete, time: .shortened))
                }
                if let message = meeting.errorMessage {
                    Text(message).foregroundStyle(Theme.Palette.warning)
                }
            }
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    @ViewBuilder
    private func playbackBar(_ meeting: MeetingRecord) -> some View {
        if meeting.playbackAudioPath != nil || meeting.youAudioPath != nil {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                HStack(spacing: 12) {
                    Button {
                        playback.toggle()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .buttonStyle(.plain)
                    Slider(
                        value: Binding(
                            get: { playback.currentTime },
                            set: { playback.seek(to: $0) }),
                        in: 0...max(1, playback.duration))
                    Text(Self.timestamp(playback.currentTime) + " / " + Self.timestamp(playback.duration))
                        .font(Theme.Fonts.caption.monospacedDigit())
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func digestSection(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("DIGEST")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
                switch meeting.digestStatus {
                case .generating:
                    ProgressView().controlSize(.mini)
                case .failed, .pending:
                    if meeting.status == .ready, recorder != nil {
                        Button(meeting.digestStatus == .failed ? "Retry digest" : "Generate digest") {
                            Task { await recorder?.retryDigest(for: meeting) }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Palette.accent)
                    }
                case .ready:
                    EmptyView()
                }
            }
            if let summary = meeting.summaryText, !summary.isEmpty {
                Text(summary)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            } else if meeting.digestStatus == .failed {
                Text("The on-device digest failed — the recording and transcript are unaffected.")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            if !meeting.decisions.isEmpty {
                bulletList("Decisions", meeting.decisions)
            }
            if !meeting.unresolvedQuestions.isEmpty {
                bulletList("Unresolved", meeting.unresolvedQuestions)
            }
        }
    }

    private func bulletList(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Palette.textSecondary)
            ForEach(items, id: \.self) { item in
                Text("•  \(item)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        }
    }

    @ViewBuilder
    private func proposalsSection(_ meeting: MeetingRecord) -> some View {
        let proposals = (meeting.proposals ?? []).sorted { $0.uid < $1.uid }
        if !proposals.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("PROPOSED TASKS — YOUR CALL")
                    .font(.system(size: 10, weight: .semibold)).tracking(0.06)
                    .foregroundStyle(Theme.Palette.textTertiary)
                ForEach(proposals, id: \.uid) { proposal in
                    MeetingActionProposalView(proposal: proposal) { evidenceUID in
                        highlightedSegmentUID = evidenceUID
                        if let segment = (meeting.segments ?? []).first(where: { $0.uid == evidenceUID }) {
                            playback.seek(to: segment.startSeconds)
                        }
                    }
                }
            }
        }
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
#endif
