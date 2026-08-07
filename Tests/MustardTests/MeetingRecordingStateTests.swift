import XCTest
@testable import MustardKit

/// Pure meeting-recorder lifecycle transitions (meeting recorder, Task 2).
/// Every date is pinned — no ambient clock.
final class MeetingRecordingStateTests: XCTestCase {
    /// 2026-07-29T00:00:00Z, pinned.
    private let startDate = Date(timeIntervalSince1970: 1_753_747_200)

    private func apply(_ event: MeetingRecordingEvent,
                       to state: MeetingRecordingState) -> MeetingRecordingState? {
        state.applying(event)
    }

    // MARK: - Happy path

    func test_prepare_fromIdle() {
        XCTAssertEqual(apply(.prepare, to: .idle), .preparing)
    }

    func test_userConfirmedStart_fromPreparing_recordsWithStartDate() {
        XCTAssertEqual(apply(.userConfirmedStart(at: startDate), to: .preparing),
                       .recording(startedAt: startDate))
    }

    func test_pause_fromRecording() {
        XCTAssertEqual(apply(.pause, to: .recording(startedAt: startDate)), .paused)
    }

    func test_resume_fromPaused_restoresInjectedSessionStart() {
        // The coordinator passes back the original session start (from the
        // manifest) so elapsed time stays truthful across a pause.
        XCTAssertEqual(apply(.resume(at: startDate), to: .paused),
                       .recording(startedAt: startDate))
    }

    func test_stop_fromRecording_beginsAudioFinalization() {
        XCTAssertEqual(apply(.stop, to: .recording(startedAt: startDate)), .finalizingAudio)
    }

    func test_stop_fromPaused_beginsAudioFinalization() {
        XCTAssertEqual(apply(.stop, to: .paused), .finalizingAudio)
    }

    func test_finalizePipeline_audioThenTranscriptThenDigest() {
        XCTAssertEqual(apply(.audioFinalized, to: .finalizingAudio), .finalizingTranscript)
        XCTAssertEqual(apply(.transcriptFinalized, to: .finalizingTranscript), .summarizing)
        XCTAssertEqual(apply(.digestReady, to: .summarizing), .ready)
    }

    // MARK: - Consent gate (only explicit confirmation starts recording)

    func test_userConfirmedStart_isTheOnlyEventThatEntersRecordingFromPreparing() {
        let others: [MeetingRecordingEvent] = [
            .prepare, .pause, .resume(at: startDate), .stop,
            .audioFinalized, .transcriptFinalized, .digestReady, .recover,
        ]
        for event in others {
            XCTAssertNil(apply(event, to: .preparing), "\(event) must not leave preparing")
        }
    }

    func test_userConfirmedStart_rejectedFromIdle_withoutPrepare() {
        XCTAssertNil(apply(.userConfirmedStart(at: startDate), to: .idle))
    }

    // MARK: - Double start

    func test_doubleStart_rejectedWhileRecording() {
        XCTAssertNil(apply(.userConfirmedStart(at: startDate.addingTimeInterval(60)),
                           to: .recording(startedAt: startDate)))
    }

    func test_start_rejectedWhilePaused_resumeIsTheOnlyWayBack() {
        XCTAssertNil(apply(.userConfirmedStart(at: startDate), to: .paused))
    }

    func test_start_rejectedDuringFinalization() {
        XCTAssertNil(apply(.userConfirmedStart(at: startDate), to: .finalizingAudio))
        XCTAssertNil(apply(.userConfirmedStart(at: startDate), to: .finalizingTranscript))
        XCTAssertNil(apply(.userConfirmedStart(at: startDate), to: .summarizing))
    }

    // MARK: - Failure

    func test_fail_fromActiveStates_carriesReason() {
        let active: [MeetingRecordingState] = [
            .preparing, .recording(startedAt: startDate), .paused,
            .finalizingAudio, .finalizingTranscript, .summarizing,
        ]
        for state in active {
            XCTAssertEqual(apply(.fail(reason: "disk full"), to: state),
                           .failed("disk full"), "fail must be reachable from \(state)")
        }
    }

    func test_fail_rejectedFromIdleReadyAndFailed() {
        XCTAssertNil(apply(.fail(reason: "x"), to: .idle))
        XCTAssertNil(apply(.fail(reason: "x"), to: .ready))
        XCTAssertNil(apply(.fail(reason: "x"), to: .failed("earlier")))
    }

    // MARK: - Interruption → partial → recover

    func test_interrupted_whileRecording_preservesPartial() {
        XCTAssertEqual(apply(.interrupted(reason: "process terminated"),
                             to: .recording(startedAt: startDate)),
                       .partial("process terminated"))
    }

    func test_interrupted_duringFinalization_preservesPartial() {
        XCTAssertEqual(apply(.interrupted(reason: "crash"), to: .finalizingAudio),
                       .partial("crash"))
        XCTAssertEqual(apply(.interrupted(reason: "crash"), to: .finalizingTranscript),
                       .partial("crash"))
        XCTAssertEqual(apply(.interrupted(reason: "crash"), to: .summarizing),
                       .partial("crash"))
    }

    func test_partial_isPreserved_againstStrayEvents() {
        // After an interruption the partial state must survive everything except
        // an explicit recover or a terminal fail.
        let partial = MeetingRecordingState.partial("crash")
        let stray: [MeetingRecordingEvent] = [
            .prepare, .userConfirmedStart(at: startDate), .pause,
            .resume(at: startDate), .stop, .audioFinalized,
            .transcriptFinalized, .digestReady, .interrupted(reason: "again"),
        ]
        for event in stray {
            XCTAssertNil(apply(event, to: partial), "\(event) must not disturb partial")
        }
    }

    func test_recover_fromPartial_resumesAtAudioFinalization() {
        XCTAssertEqual(apply(.recover, to: .partial("crash")), .finalizingAudio)
    }

    func test_recover_rejectedFromNonPartialStates() {
        XCTAssertNil(apply(.recover, to: .idle))
        XCTAssertNil(apply(.recover, to: .recording(startedAt: startDate)))
        XCTAssertNil(apply(.recover, to: .ready))
        XCTAssertNil(apply(.recover, to: .failed("x")))
    }

    func test_fail_fromPartial_whenRecoveryIsImpossible() {
        XCTAssertEqual(apply(.fail(reason: "audio unreadable"), to: .partial("crash")),
                       .failed("audio unreadable"))
    }

    // MARK: - Terminal states

    func test_readyAndFailed_areTerminal() {
        let all: [MeetingRecordingEvent] = [
            .prepare, .userConfirmedStart(at: startDate), .pause,
            .resume(at: startDate), .stop, .audioFinalized, .transcriptFinalized,
            .digestReady, .interrupted(reason: "x"), .recover,
        ]
        for event in all {
            XCTAssertNil(apply(event, to: .ready), "\(event) must not leave ready")
        }
        for event in all {
            XCTAssertNil(apply(event, to: .failed("x")), "\(event) must not leave failed")
        }
    }
}
