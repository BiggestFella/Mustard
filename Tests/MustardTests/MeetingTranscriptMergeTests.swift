import XCTest
import AVFoundation
@testable import MustardKit

/// Two-source transcript merging (Meetings Task 5, BAK-297): the pure merge
/// (ordering, tie-breaks, provisional replacement, stable IDs) and the
/// transcription service's dual-live vs sequential-fallback decision. Speech
/// sessions are stubs; no analyzer runs.
@MainActor
final class MeetingTranscriptMergeTests: XCTestCase {

    // MARK: - Fixtures

    private func seg(
        _ id: String, _ text: String,
        start: Double, end: Double,
        source: VoiceAudioSource, final: Bool = true
    ) -> VoiceTranscriptSegment {
        VoiceTranscriptSegment(
            id: id, text: text, startSeconds: start, endSeconds: end,
            isFinal: final, confidence: nil, source: source)
    }

    // MARK: - Merge: ordering

    func test_merge_interleavesOverlappingAndAdjacentSegmentsByStart() {
        let you = [
            seg("y1", "so my plan is", start: 0.0, end: 2.0, source: .microphone),
            seg("y2", "yes exactly", start: 6.0, end: 7.0, source: .microphone),
        ]
        let meeting = [
            seg("m1", "what's the plan", start: 1.5, end: 3.0, source: .meeting),
            seg("m2", "ship friday then", start: 3.0, end: 5.5, source: .meeting),
        ]

        let merged = MeetingTranscriptMerge.merged(you: you, meeting: meeting)

        XCTAssertEqual(merged.map(\.id), ["y1", "m1", "m2", "y2"])
    }

    func test_merge_equalTimestamps_tieBreakYouBeforeMeeting_thenID() {
        let you = [seg("y1", "mm", start: 1.0, end: 2.0, source: .microphone)]
        let meeting = [seg("m1", "mm", start: 1.0, end: 2.0, source: .meeting)]

        let merged = MeetingTranscriptMerge.merged(you: you, meeting: meeting)

        XCTAssertEqual(merged.map(\.id), ["y1", "m1"], "equal spans put You first, deterministically")
        XCTAssertEqual(
            MeetingTranscriptMerge.merged(you: you, meeting: meeting).map(\.id),
            ["y1", "m1"],
            "re-merging is stable")
    }

    // MARK: - Merge: provisional replacement & finals-only

    func test_merge_sameIDProvisionalIsReplacedByItsFinal() {
        let you = [
            seg("y1", "so my pl", start: 0.0, end: 1.0, source: .microphone, final: false),
            seg("y1", "so my plan is", start: 0.0, end: 2.0, source: .microphone, final: true),
        ]

        let merged = MeetingTranscriptMerge.merged(you: you, meeting: [])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.text, "so my plan is")
        XCTAssertTrue(merged.first?.isFinal ?? false)
    }

    func test_merge_provisionalOnlySegments_areDropped() {
        let meeting = [seg("m1", "half a tho", start: 0, end: 1, source: .meeting, final: false)]
        XCTAssertTrue(MeetingTranscriptMerge.merged(you: [], meeting: meeting).isEmpty)
    }

    // MARK: - Stable persistent IDs

    func test_persistentID_isNamespacedBySource_andStable() {
        let you = seg("seg-0.000", "hello", start: 0, end: 1, source: .microphone)
        let meeting = seg("seg-0.000", "hi there", start: 0, end: 1, source: .meeting)

        XCTAssertEqual(MeetingTranscriptMerge.persistentID(for: you), "microphone:seg-0.000")
        XCTAssertEqual(MeetingTranscriptMerge.persistentID(for: meeting), "meeting:seg-0.000")
        XCTAssertNotEqual(
            MeetingTranscriptMerge.persistentID(for: you),
            MeetingTranscriptMerge.persistentID(for: meeting),
            "the same recognizer id from two sources must never collide")
    }

    // MARK: - Service: mode decision + sequential fallback

    private final class StubSession: VoiceTranscribing, @unchecked Sendable {
        let finals: [VoiceTranscriptSegment]
        let startError: Error?
        private(set) var appended = 0
        private(set) var finished = false

        init(finals: [VoiceTranscriptSegment], startError: Error? = nil) {
            self.finals = finals
            self.startError = startError
        }

        func readiness() async -> VoiceReadiness { .ready }
        func prepare() async throws {}
        func start(source: VoiceAudioSource) async throws -> AsyncThrowingStream<VoiceTranscriptSegment, Error> {
            if let startError { throw startError }
            return AsyncThrowingStream { $0.finish() }
        }
        func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) async throws { appended += 1 }
        func finish() async throws -> [VoiceTranscriptSegment] {
            finished = true
            return finals
        }
        func cancel() async {}
    }

    private func pcm() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        return buffer
    }

    func test_bothSessionsStart_runsDualLive() async throws {
        let you = StubSession(finals: [seg("y1", "hello", start: 0, end: 1, source: .microphone)])
        let meeting = StubSession(finals: [seg("m1", "hi", start: 0.5, end: 1.5, source: .meeting)])
        var handed = [you, meeting]
        let service = MeetingTranscriptionService(
            makeSession: { handed.removeFirst() },
            isInsufficientResources: { _ in false },
            transcribeFile: { _ in XCTFail("dual-live never post-processes a file"); return [] })

        try await service.start()
        XCTAssertEqual(service.mode, .dualLive)

        try await service.append(pcm(), channel: .you)
        try await service.append(pcm(), channel: .meeting)
        XCTAssertEqual(you.appended, 1)
        XCTAssertEqual(meeting.appended, 1)

        let merged = try await service.stop(meetingAudioFile: nil)
        XCTAssertEqual(merged.map(\.id), ["y1", "m1"])
    }

    func test_insufficientResources_fallsBackToLiveYouThenMeetingFile() async throws {
        struct ResourceError: Error {}
        let you = StubSession(finals: [seg("y1", "hello", start: 0, end: 1, source: .microphone)])
        let failing = StubSession(finals: [], startError: ResourceError())
        var handed: [StubSession] = [you, failing]
        var fileTranscribed: URL?
        let service = MeetingTranscriptionService(
            makeSession: { handed.removeFirst() },
            isInsufficientResources: { $0 is ResourceError },
            transcribeFile: { url in
                fileTranscribed = url
                return [self.seg("m1", "hi", start: 0.5, end: 1.5, source: .meeting)]
            })

        try await service.start()
        XCTAssertEqual(service.mode, .liveYouThenMeetingFile)

        // The Meeting channel keeps RECORDING (writer's job); the service just
        // has nowhere live to send it, so appends for it are dropped here.
        try await service.append(pcm(), channel: .you)
        try await service.append(pcm(), channel: .meeting)
        XCTAssertEqual(you.appended, 1)

        let meetingFile = URL(fileURLWithPath: "/tmp/meeting.m4a")
        let merged = try await service.stop(meetingAudioFile: meetingFile)

        XCTAssertEqual(fileTranscribed, meetingFile, "the meeting track is transcribed after Stop")
        XCTAssertEqual(merged.map(\.id), ["y1", "m1"], "both sources still merge")
    }

    func test_nonResourceStartError_propagates() async {
        struct OtherError: Error {}
        let you = StubSession(finals: [])
        let failing = StubSession(finals: [], startError: OtherError())
        var handed: [StubSession] = [you, failing]
        let service = MeetingTranscriptionService(
            makeSession: { handed.removeFirst() },
            isInsufficientResources: { _ in false },
            transcribeFile: { _ in [] })

        do {
            try await service.start()
            XCTFail("a non-resource failure must not silently degrade")
        } catch {}
    }
}
