import Foundation

public enum MeetingExportError: Error, Equatable {
    /// The destination already holds these file names; the caller confirms
    /// before re-exporting with `overwrite: true`.
    case wouldOverwrite([String])
}

/// Export one meeting to a user-chosen destination (meeting recorder Task 10,
/// BAK-302): a Markdown document (metadata, summary, decisions, unresolved
/// questions, actions, timestamped transcript) plus the mixed audio when it
/// still exists. Nothing is ever overwritten without confirmation.
public enum MeetingExportService {
    /// The export document. Pure.
    public static func markdown(for meeting: MeetingRecord) -> String {
        var lines: [String] = []
        lines.append("# \(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)")
        lines.append("")
        if let startedAt = meeting.startedAt {
            lines.append("- Started: \(startedAt.formatted(date: .long, time: .shortened))")
        }
        if let endedAt = meeting.endedAt {
            lines.append("- Ended: \(endedAt.formatted(date: .long, time: .shortened))")
        }
        if !meeting.captureSources.isEmpty {
            lines.append("- Sources: \(meeting.captureSources.joined(separator: ", "))")
        }
        if let promptVersion = meeting.promptVersion {
            lines.append("- Digest: \(promptVersion) on \(meeting.osBuild ?? "unknown build")")
        }
        if let summary = meeting.summaryText, !summary.isEmpty {
            lines.append("")
            lines.append("## Summary")
            lines.append(summary)
        }
        if !meeting.decisions.isEmpty {
            lines.append("")
            lines.append("## Decisions")
            lines.append(contentsOf: meeting.decisions.map { "- \($0)" })
        }
        if !meeting.unresolvedQuestions.isEmpty {
            lines.append("")
            lines.append("## Unresolved questions")
            lines.append(contentsOf: meeting.unresolvedQuestions.map { "- \($0)" })
        }
        let proposals = (meeting.proposals ?? []).sorted { $0.uid < $1.uid }
        if !proposals.isEmpty {
            lines.append("")
            lines.append("## Actions")
            for proposal in proposals {
                let status: String
                switch proposal.state {
                case .pending: status = "proposed"
                case .approved: status = "approved"
                case .rejected: status = "rejected"
                }
                lines.append("- [\(status)] \(proposal.title)")
            }
        }
        let segments = (meeting.segments ?? [])
            .sorted { ($0.startSeconds, $0.uid) < ($1.startSeconds, $1.uid) }
        if !segments.isEmpty {
            lines.append("")
            lines.append("## Transcript")
            for segment in segments {
                let channel = segment.source == .you ? "You" : "Meeting"
                lines.append(
                    "[\(timestamp(segment.startSeconds))] \(channel): \(segment.correctedText ?? segment.rawText)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Write the Markdown (+ audio when present) into `destination`.
    /// Returns the written URLs; throws `wouldOverwrite` before touching
    /// anything when a target exists and `overwrite` is false.
    @MainActor
    @discardableResult
    public static func export(
        _ meeting: MeetingRecord,
        store: MeetingAudioStore,
        to destination: URL,
        overwrite: Bool = false,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        let base = baseName(for: meeting)
        let markdownURL = destination.appendingPathComponent("\(base).md")
        let audioSource = audioURL(for: meeting, store: store, fileManager: fileManager)
        let audioTarget = audioSource.map { _ in destination.appendingPathComponent("\(base).m4a") }

        // Conflicts are collected BEFORE anything is written.
        let targets = [markdownURL] + (audioTarget.map { [$0] } ?? [])
        let conflicts = targets.filter { fileManager.fileExists(atPath: $0.path) }
        if !conflicts.isEmpty, !overwrite {
            throw MeetingExportError.wouldOverwrite(conflicts.map(\.lastPathComponent))
        }

        try markdown(for: meeting).data(using: .utf8)?
            .write(to: markdownURL, options: .atomic)
        var written = [markdownURL]
        if let audioSource, let audioTarget {
            if fileManager.fileExists(atPath: audioTarget.path) {
                try fileManager.removeItem(at: audioTarget)
            }
            try fileManager.copyItem(at: audioSource, to: audioTarget)
            written.append(audioTarget)
        }
        return written
    }

    // MARK: - Helpers

    /// The mixed playback track when it exists, else the You track.
    private static func audioURL(
        for meeting: MeetingRecord, store: MeetingAudioStore, fileManager: FileManager
    ) -> URL? {
        let candidates: [MeetingAudioFile] =
            meeting.playbackAudioPath != nil ? [.playback, .you] :
            meeting.youAudioPath != nil ? [.you] : []
        for file in candidates {
            if let url = try? store.fileURL(for: file, meetingUID: meeting.uid),
               fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func baseName(for meeting: MeetingRecord) -> String {
        let title = meeting.title.isEmpty ? "Meeting" : meeting.title
        let slug = title
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let day = (meeting.startedAt ?? meeting.createdAt)
            .formatted(.iso8601.year().month().day())
        return "\(day) \(slug.isEmpty ? "Meeting" : slug)"
    }

    private static func timestamp(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
