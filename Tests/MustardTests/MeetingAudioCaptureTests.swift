import XCTest
import AVFoundation
@testable import MustardKit

/// Two-source capture routing (Meetings Task 4, BAK-296): system audio routes
/// to the Meeting track, the microphone to the You track, timestamps pass
/// through on one shared clock, a missing source demands confirmation, and a
/// failing source pauses alone. The ScreenCaptureKit edge is stubbed.
@MainActor
final class MeetingAudioCaptureTests: XCTestCase {

    // MARK: - Fixtures

    private func pcm(frames: AVAudioFrameCount = 480) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    private func sample(_ source: MeetingAudioSource, at seconds: Double) -> MeetingAudioSample {
        MeetingAudioSample(source: source, buffer: pcm(), hostSeconds: seconds)
    }

    private final class StubCapturing: MeetingAudioCapturing, @unchecked Sendable {
        var available: [MeetingAudioSource] = [.microphone, .systemAudio]
        var continuations: [MeetingAudioSource: AsyncThrowingStream<MeetingAudioSample, Error>.Continuation] = [:]
        var started: [MeetingAudioSource] = []
        var stopped = false

        func availableSources() async throws -> [MeetingAudioSource] { available }

        func start(source: MeetingAudioSource) async throws -> AsyncThrowingStream<MeetingAudioSample, Error> {
            started.append(source)
            return AsyncThrowingStream { self.continuations[source] = $0 }
        }

        func pause() async throws {}
        func resume() async throws {}
        func stop() async throws { stopped = true }
    }

    private struct Routed: Equatable {
        let channel: MeetingSegmentSource
        let hostSeconds: Double
    }

    private func makeCapture(
        stub: StubCapturing, into routed: NSMutableArray
    ) -> MeetingAudioCapture {
        MeetingAudioCapture(capturing: stub) { channel, sample in
            routed.add(Routed(channel: channel, hostSeconds: sample.hostSeconds))
        }
    }

    private func drain() async {
        for _ in 0..<25 { await Task.yield() }
    }

    // MARK: - Channel mapping (pure)

    func test_channelMapping_micIsYou_systemAudioIsMeeting() {
        XCTAssertEqual(MeetingAudioSource.microphone.trackChannel, .you)
        XCTAssertEqual(MeetingAudioSource.systemAudio.trackChannel, .meeting)
    }

    // MARK: - Start decision (pure)

    func test_allRequestedSourcesAvailable_startsWithoutConfirmation() {
        XCTAssertEqual(
            MeetingAudioCapture.startDecision(
                requested: [.microphone, .systemAudio],
                available: [.microphone, .systemAudio]),
            .start(sources: [.microphone, .systemAudio]))
    }

    func test_missingSystemAudio_requiresConfirmation() {
        XCTAssertEqual(
            MeetingAudioCapture.startDecision(
                requested: [.microphone, .systemAudio],
                available: [.microphone]),
            .needsConfirmation(missing: [.systemAudio]))
    }

    // MARK: - Routing

    func test_samplesRouteToTheirChannels_withSharedClockTimestamps() async throws {
        let stub = StubCapturing()
        let routed = NSMutableArray()
        let capture = makeCapture(stub: stub, into: routed)

        try await capture.start(sources: [.microphone, .systemAudio])
        stub.continuations[.microphone]?.yield(sample(.microphone, at: 1.00))
        stub.continuations[.systemAudio]?.yield(sample(.systemAudio, at: 1.02))
        stub.continuations[.microphone]?.yield(sample(.microphone, at: 1.04))
        await drain()

        let samples = routed.compactMap { $0 as? Routed }
        XCTAssertEqual(samples.filter { $0.channel == .you }.map(\.hostSeconds), [1.00, 1.04])
        XCTAssertEqual(samples.filter { $0.channel == .meeting }.map(\.hostSeconds), [1.02])
    }

    // MARK: - Per-source failure isolation

    func test_sourceFailure_pausesOnlyTheAffectedStream() async throws {
        let stub = StubCapturing()
        let routed = NSMutableArray()
        let capture = makeCapture(stub: stub, into: routed)

        try await capture.start(sources: [.microphone, .systemAudio])
        stub.continuations[.systemAudio]?.finish(
            throwing: VoiceSessionError.audioFormatUnavailable)
        stub.continuations[.microphone]?.yield(sample(.microphone, at: 2.0))
        await drain()

        guard case .paused = capture.state(of: .systemAudio) else {
            return XCTFail("expected systemAudio paused, got \(capture.state(of: .systemAudio))")
        }
        XCTAssertEqual(capture.state(of: .microphone), .streaming)
        XCTAssertEqual(
            routed.compactMap { $0 as? Routed }.last,
            Routed(channel: .you, hostSeconds: 2.0),
            "the healthy source keeps flowing")
    }

    // MARK: - Stop

    func test_stop_stopsTheCapturer_andIdlesEverySource() async throws {
        let stub = StubCapturing()
        let capture = makeCapture(stub: stub, into: NSMutableArray())

        try await capture.start(sources: [.microphone])
        await capture.stop()

        XCTAssertTrue(stub.stopped)
        XCTAssertEqual(capture.state(of: .microphone), .idle)
        XCTAssertEqual(capture.state(of: .systemAudio), .idle)
    }
}
