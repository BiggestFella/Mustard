import Foundation
import AVFoundation

/// Framework-facing voice service seams (Voice Core). This file is the only
/// place the shared voice contracts touch AVFoundation — the value types it
/// exchanges stay in the pure `VoiceTypes.swift`. Live adapters (the
/// SpeechAnalyzer-backed session) conform to these protocols; tests inject
/// deterministic stubs instead.

/// A transcription session: check readiness, prepare assets, then stream
/// audio buffers in and transcript segments out. Implementations own the
/// recognizer lifecycle; callers only ever see Mustard value types plus the
/// AVFoundation buffer they already hold from the audio tap.
public protocol VoiceTranscribing: Sendable {
    func readiness() async -> VoiceReadiness
    func prepare() async throws
    func start(source: VoiceAudioSource) async throws -> AsyncThrowingStream<VoiceTranscriptSegment, Error>
    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) async throws
    func finish() async throws -> [VoiceTranscriptSegment]
    func cancel() async
}
