import XCTest
@testable import MustardKit

/// Dictation latency marks (Talkify review, item 5). The whole point of this
/// unit is that we currently cannot say whether dictation feels slow because
/// of 200ms or 900ms — so the arithmetic that answers that question is pinned
/// here rather than being computed inline in the coordinator.
///
/// Time is fixed, never ambient: every mark is an explicit `Date` offset from
/// one origin.
final class DictationLatencyTests: XCTestCase {

    /// Fixed origin — no ambient clock, no timezone sensitivity.
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        origin.addingTimeInterval(seconds)
    }

    // MARK: - Startup (press → listening)

    func test_startup_isPressToListeningInWholeMilliseconds() {
        var marks = DictationLatency()
        marks.markPressed(at(0))
        marks.markListening(at(0.412))

        XCTAssertEqual(marks.startupMilliseconds, 412)
    }

    func test_startup_roundsToNearestMillisecond() {
        var marks = DictationLatency()
        marks.markPressed(at(0))
        marks.markListening(at(0.4126))

        XCTAssertEqual(marks.startupMilliseconds, 413)
    }

    func test_startup_isNilBeforeListeningIsMarked() {
        var marks = DictationLatency()
        marks.markPressed(at(0))

        XCTAssertNil(marks.startupMilliseconds)
    }

    func test_startup_isNilWhenPressWasNeverMarked() {
        var marks = DictationLatency()
        marks.markListening(at(0.4))

        XCTAssertNil(marks.startupMilliseconds)
    }

    /// A clock that appears to run backwards (wall-clock adjustment mid-hold)
    /// must produce no measurement rather than a negative one — a bogus
    /// number in the log is worse than a missing one.
    func test_startup_isNilWhenListeningPrecedesPress() {
        var marks = DictationLatency()
        marks.markPressed(at(1.0))
        marks.markListening(at(0.5))

        XCTAssertNil(marks.startupMilliseconds)
    }

    // MARK: - Finish (release → inserted)

    func test_finish_isReleaseToInsertedInWholeMilliseconds() {
        var marks = DictationLatency()
        marks.markPressed(at(0))
        marks.markListening(at(0.2))
        marks.markReleased(at(3.0))
        marks.markInserted(at(3.75))

        XCTAssertEqual(marks.finishMilliseconds, 750)
    }

    func test_finish_isNilBeforeInsertionIsMarked() {
        var marks = DictationLatency()
        marks.markReleased(at(3.0))

        XCTAssertNil(marks.finishMilliseconds)
    }

    func test_finish_isNilWhenInsertedPrecedesRelease() {
        var marks = DictationLatency()
        marks.markReleased(at(3.0))
        marks.markInserted(at(2.0))

        XCTAssertNil(marks.finishMilliseconds)
    }

    // MARK: - Held duration (press → release)

    func test_heldMilliseconds_isPressToRelease() {
        var marks = DictationLatency()
        marks.markPressed(at(0))
        marks.markReleased(at(2.5))

        XCTAssertEqual(marks.heldMilliseconds, 2_500)
    }

    // MARK: - Summary line

    func test_summary_reportsEveryAvailableMeasurement() {
        var marks = DictationLatency()
        marks.markPressed(at(0))
        marks.markListening(at(0.31))
        marks.markReleased(at(4.0))
        marks.markInserted(at(4.62))

        XCTAssertEqual(marks.summary, "startup=310ms held=4000ms finish=620ms")
    }

    /// A hold that never inserted (recovery path) still reports what it knows.
    func test_summary_omitsMeasurementsThatAreNotAvailable() {
        var marks = DictationLatency()
        marks.markPressed(at(0))
        marks.markListening(at(0.31))
        marks.markReleased(at(4.0))

        XCTAssertEqual(marks.summary, "startup=310ms held=4000ms")
    }

    func test_summary_isNilWhenNothingIsMeasurable() {
        let marks = DictationLatency()

        XCTAssertNil(marks.summary)
    }

    // MARK: - Reset between holds

    /// Every press starts a fresh measurement; a previous hold's release or
    /// insertion must never leak into the next hold's numbers.
    func test_markPressed_clearsThePreviousHoldsMarks() {
        var marks = DictationLatency()
        marks.markPressed(at(0))
        marks.markListening(at(0.31))
        marks.markReleased(at(4.0))
        marks.markInserted(at(4.62))

        marks.markPressed(at(10.0))

        XCTAssertNil(marks.startupMilliseconds)
        XCTAssertNil(marks.heldMilliseconds)
        XCTAssertNil(marks.finishMilliseconds)
        XCTAssertNil(marks.summary)
    }
}
