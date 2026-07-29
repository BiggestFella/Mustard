import Foundation
import AVFoundation

/// Which capture feed a sample came from — ScreenCaptureKit's two audio
/// outputs (never `.screen`; no video is ever captured or stored).
public enum MeetingAudioSource: String, Equatable, CaseIterable, Sendable {
    case microphone
    case systemAudio

    /// The track a source records into: your mic is the You track, the other
    /// side playing through the Mac is the Meeting track.
    public var trackChannel: MeetingSegmentSource {
        switch self {
        case .microphone: .you
        case .systemAudio: .meeting
        }
    }
}

/// One captured PCM chunk stamped with its host-clock time. Both feeds share
/// the one host clock, so downstream merging can interleave by timestamp.
public struct MeetingAudioSample: @unchecked Sendable {
    public let source: MeetingAudioSource
    public let buffer: AVAudioPCMBuffer
    public let hostSeconds: Double

    public init(source: MeetingAudioSource, buffer: AVAudioPCMBuffer, hostSeconds: Double) {
        self.source = source
        self.buffer = buffer
        self.hostSeconds = hostSeconds
    }
}

/// The injected capture contract (meeting recorder Task 4). The live
/// conformance is `ScreenCaptureMeetingAudio`; tests inject stubs.
public protocol MeetingAudioCapturing: Sendable {
    func availableSources() async throws -> [MeetingAudioSource]
    func start(source: MeetingAudioSource) async throws -> AsyncThrowingStream<MeetingAudioSample, Error>
    func pause() async throws
    func resume() async throws
    func stop() async throws
}

/// Routes captured samples to their tracks and owns per-source stream
/// lifecycle (meeting recorder Task 4, BAK-296): system audio → Meeting,
/// microphone → You, timestamps untouched (one shared clock), a missing
/// source demands explicit confirmation before a degraded recording starts,
/// and a failing source pauses alone — recording never goes silent silently.
@MainActor
public final class MeetingAudioCapture {
    public enum StartDecision: Equatable, Sendable {
        case start(sources: [MeetingAudioSource])
        case needsConfirmation(missing: [MeetingAudioSource])
    }

    public enum SourceState: Equatable, Sendable {
        case idle
        case streaming
        case paused(String)
    }

    private let capturing: any MeetingAudioCapturing
    private let route: @MainActor (MeetingSegmentSource, MeetingAudioSample) -> Void
    private var states: [MeetingAudioSource: SourceState] = [:]
    private var consumeTasks: [MeetingAudioSource: Task<Void, Never>] = [:]

    public init(
        capturing: any MeetingAudioCapturing,
        route: @escaping @MainActor (MeetingSegmentSource, MeetingAudioSample) -> Void
    ) {
        self.capturing = capturing
        self.route = route
    }

    /// Whether recording may start with the requested sources — pure. Any
    /// requested-but-unavailable source demands explicit confirmation (a
    /// degraded recording is never started silently).
    public static func startDecision(
        requested: [MeetingAudioSource],
        available: [MeetingAudioSource]
    ) -> StartDecision {
        let missing = requested.filter { !available.contains($0) }
        return missing.isEmpty
            ? .start(sources: requested)
            : .needsConfirmation(missing: missing)
    }

    public func state(of source: MeetingAudioSource) -> SourceState {
        states[source] ?? .idle
    }

    /// Start streaming the given sources; each source's samples route to its
    /// track as they arrive. A stream failure pauses that source only — the
    /// other keeps flowing, and the pause is visible in `state(of:)`.
    public func start(sources: [MeetingAudioSource]) async throws {
        for source in sources {
            let stream = try await capturing.start(source: source)
            states[source] = .streaming
            consumeTasks[source] = Task { [weak self] in
                do {
                    for try await sample in stream {
                        guard let self else { return }
                        self.route(source.trackChannel, sample)
                    }
                    // The stream ended cleanly (stop) — idle, not paused.
                    self?.setState(.idle, for: source)
                } catch {
                    self?.setState(.paused(error.localizedDescription), for: source)
                }
            }
        }
    }

    public func stop() async {
        try? await capturing.stop()
        for task in consumeTasks.values { task.cancel() }
        consumeTasks = [:]
        states = [:]
    }

    private func setState(_ state: SourceState, for source: MeetingAudioSource) {
        states[source] = state
    }
}
