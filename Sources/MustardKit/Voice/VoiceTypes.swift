import Foundation

/// Framework-independent voice contracts (Voice Core). These are the value
/// types every Mustard voice feature exchanges — push-to-talk, meeting
/// capture, and anything that consumes a transcript stream. Deliberately
/// pure Foundation: the Apple Speech / AVFoundation edges live behind the
/// protocols in `VoiceServices.swift`, so features and their tests never
/// touch a microphone or a live model.

/// Where the audio for a transcription session comes from.
public enum VoiceAudioSource: String, Codable, Sendable {
    case microphone, meeting
}

/// One span of transcribed speech. Provisional (volatile) results arrive with
/// `isFinal == false` and may be replaced by a later segment with the same
/// `id`; stable results are final and never revised. `confidence` is optional
/// because not every recognizer path scores its output — absence is distinct
/// from a score of zero.
public struct VoiceTranscriptSegment: Equatable, Sendable {
    public let id: String
    public let text: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let isFinal: Bool
    public let confidence: Double?
    public let source: VoiceAudioSource

    public init(
        id: String,
        text: String,
        startSeconds: Double,
        endSeconds: Double,
        isFinal: Bool,
        confidence: Double?,
        source: VoiceAudioSource
    ) {
        self.id = id
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.isFinal = isFinal
        self.confidence = confidence
        self.source = source
    }
}

/// Whether on-device transcription can start right now, and if not, why.
/// `unavailable` carries a human-readable reason for the setup surface.
public enum VoiceReadiness: Equatable, Sendable {
    case ready
    case needsAssetDownload
    case permissionDenied
    case unsupportedLocale
    case unavailable(String)
}
