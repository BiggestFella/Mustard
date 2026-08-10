import XCTest
import MustardShims
@testable import MustardKit

/// `MSTDCatchException` exists because AVFAudio signals runtime
/// misconfiguration by raising Objective-C exceptions (`installTapOnBus:`
/// with a stale device format, observed 2026-08-11), and an NSException
/// unwinding through Swift-concurrency frames corrupts executor tracking —
/// a delayed SIGSEGV in `MainActor.assumeIsolated`, not a catchable error.
final class ObjCExceptionGuardTests: XCTestCase {
    func test_raisedException_isCaughtAndReturned() {
        let raised = MSTDCatchException {
            NSException(
                name: .invalidArgumentException,
                reason: "hw format mismatch",
                userInfo: nil
            ).raise()
        }
        XCTAssertEqual(raised?.name, .invalidArgumentException)
        XCTAssertEqual(raised?.reason, "hw format mismatch")
    }

    func test_normalBlock_runs_andReturnsNil() {
        var ran = false
        let raised = MSTDCatchException { ran = true }
        XCTAssertNil(raised)
        XCTAssertTrue(ran)
    }

    func test_audioEngineFailure_readsAsAFriendlyPillMessage() {
        let error = VoiceSessionError.audioEngineFailure("hw format mismatch")
        XCTAssertEqual(
            error.localizedDescription,
            "The microphone couldn't start (hw format mismatch) — try again.")
    }

    func test_audioFormatUnavailable_readsAsAFriendlyPillMessage() {
        XCTAssertEqual(
            VoiceSessionError.audioFormatUnavailable.localizedDescription,
            "The microphone's audio format is changing — try again in a moment.")
    }
}
