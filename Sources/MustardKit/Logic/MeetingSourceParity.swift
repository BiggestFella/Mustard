import Foundation

/// Pure finalize-time check (BAK-332), born from a real incident: a meeting
/// finished with `status = ready`, `audioFinalized = true`, 413 persisted
/// "you" transcript segments — and zero mic bytes on disk. The writer for
/// one source silently never wrote anything while the same buffers kept
/// transcribing successfully; nothing in the pipeline compared what the
/// transcript proved happened against what audio actually finalized. This
/// unit is that comparison.
///
/// A channel only counts as lost when there is POSITIVE evidence it was
/// active — persisted transcript segments for its channel — yet no audio
/// ever finalized for it. A source that was never started, or one that
/// legitimately captured no speech all meeting, is never flagged: without
/// transcript evidence, an empty finalized track is indistinguishable from a
/// quiet meeting, and this unit only reports a PROVEN mismatch, never a
/// hunch.
public enum MeetingSourceParity {
    /// The outcome of comparing what was promised, what was proven active by
    /// the transcript, and what actually finalized to disk.
    public struct Verdict: Equatable, Sendable {
        /// Capture sources (named by the user-facing `MeetingAudioSource`,
        /// not the internal track channel) that produced transcript evidence
        /// but never landed a finalized audio file. Sorted for determinism.
        public let missing: [MeetingAudioSource]

        public init(missing: [MeetingAudioSource]) {
            self.missing = missing
        }

        public var isClean: Bool { missing.isEmpty }

        /// A user-facing message naming exactly the lost channel(s) — never
        /// silent, never vague. `nil` when the verdict is clean.
        public var userMessage: String? {
            guard !missing.isEmpty else { return nil }
            let names = missing.map(\.displayName)
            let joined: String
            switch names.count {
            case 1: joined = names[0]
            default: joined = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
            }
            return "\(joined) audio was not saved — the transcript is unaffected."
        }
    }

    /// Compare the sources the meeting was started with against the sources
    /// with transcript evidence of activity and the sources whose audio
    /// actually finalized. A started source missing a finalized file is only
    /// flagged when its channel is also present in `transcribedChannels`.
    public static func evaluate(
        startedSources: [MeetingAudioSource],
        transcribedChannels: Set<MeetingSegmentSource>,
        finalizedChannels: Set<MeetingSegmentSource>
    ) -> Verdict {
        let missing = startedSources.filter { source in
            let channel = source.trackChannel
            return transcribedChannels.contains(channel) && !finalizedChannels.contains(channel)
        }
        return Verdict(missing: missing.sorted { $0.rawValue < $1.rawValue })
    }
}

extension MeetingAudioSource {
    /// The user-facing name for this capture source (Voice Setup / meeting UI
    /// copy convention: "Microphone" / "System Audio").
    public var displayName: String {
        switch self {
        case .microphone: "Microphone"
        case .systemAudio: "System Audio"
        }
    }
}
