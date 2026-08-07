import XCTest
@testable import MustardKit

/// The dictation insertion orchestrator (Dictation Task 3, BAK-289): secure
/// rejection first, focus revalidation, AX direct insertion, then the
/// lossless pasteboard fallback. All seams are closures — no AX, no real
/// pasteboard, no key events.
@MainActor
final class TextInserterTests: XCTestCase {

    // MARK: - Fixtures

    private func target(secure: Bool = false) -> FocusedTextTarget {
        FocusedTextTarget(
            applicationPID: 42,
            elementIdentifier: "42#token#AXTextField#Notes",
            selectedRange: NSRange(location: 3, length: 0),
            precedingCharacter: "o",
            followingCharacter: nil,
            isSecure: secure)
    }

    /// Everything succeeds by default; tests flip one seam at a time.
    private final class Harness {
        var stillFocused = true
        var directInsertSucceeds = true
        var pasteSucceeds = true
        /// Three-state, mirroring `focusedValueContains`: true = the text is
        /// there, false = readable and absent, nil = unreadable (web areas).
        /// A list because one insertion can verify twice (direct, then paste)
        /// and the answers differ — that is exactly the Slack case. The last
        /// entry repeats for any further calls.
        var verifyResults: [Bool?] = [true]
        var externalBumpAfterWrite = false

        var verifyCallCount = 0
        var directInsertReceived: (FocusedTextTarget, String)?
        var wroteTranscript: String?
        var restored: PasteboardSnapshot?
        var pastedToPID: pid_t?

        let snapshot = PasteboardSnapshot(
            items: [PasteboardItemSnapshot(types: ["public.utf8-plain-text": Data("old".utf8)])],
            changeCount: 7)
        private(set) var currentCount = 7

        var inserter: TextInserter {
            TextInserter(
                stillFocused: { _ in self.stillFocused },
                directInsert: { target, text in
                    self.directInsertReceived = (target, text)
                    return self.directInsertSucceeds
                },
                readPasteboard: { self.snapshot },
                writeTranscript: { text in
                    self.wroteTranscript = text
                    self.currentCount += 1
                    let writeCount = self.currentCount
                    if self.externalBumpAfterWrite { self.currentCount += 1 }
                    return writeCount
                },
                currentChangeCount: { self.currentCount },
                restorePasteboard: { self.restored = $0 },
                sendPaste: { pid in
                    self.pastedToPID = pid
                    return self.pasteSucceeds
                },
                settle: {},
                verifyInserted: { _, _ in
                    defer { self.verifyCallCount += 1 }
                    return self.verifyResults[
                        min(self.verifyCallCount, self.verifyResults.count - 1)]
                })
        }
    }

    // MARK: - Direct insertion

    func test_writableTarget_insertsDirectly_withoutTouchingThePasteboard() async {
        let harness = Harness()
        let outcome = await harness.inserter.insert("hello", into: target())

        XCTAssertEqual(outcome, .insertedDirectly)
        XCTAssertEqual(harness.directInsertReceived?.1, "hello")
        XCTAssertNil(harness.wroteTranscript, "direct insertion must not touch the clipboard")
        XCTAssertNil(harness.pastedToPID)
    }

    /// The Slack/Chromium failure seen on hardware: the AX write reports
    /// success, the text never lands, and the old code claimed "Inserted" while
    /// silently dropping the words. A contradicted write must fall through to
    /// the paste path, not be trusted.
    func test_directInsertClaimingSuccess_butTextAbsent_fallsThroughToPaste() async {
        let harness = Harness()
        harness.directInsertSucceeds = true        // AX said .success …
        harness.verifyResults = [false, true]      // … the value proves otherwise, then ⌘V lands

        let outcome = await harness.inserter.insert("hello", into: target())

        XCTAssertEqual(outcome, .insertedByPaste, "a contradicted AX write must not be reported as inserted")
        XCTAssertEqual(harness.pastedToPID, 42)
    }

    /// An unreadable value cannot confirm the write, so the direct path — which
    /// has a working fallback behind it — must not be given the benefit of the
    /// doubt. (The paste path, being last, still may: see the test below.)
    func test_directInsert_withUnknowableVerification_fallsThroughToPaste() async {
        let harness = Harness()
        harness.verifyResults = [nil]

        let outcome = await harness.inserter.insert("hello", into: target())

        XCTAssertEqual(outcome, .insertedByPaste)
    }

    /// Neither path can place the text: the words must be preserved for the
    /// user rather than reported as inserted.
    func test_neitherPathDelivers_keepsTheTranscriptForRecovery() async {
        let harness = Harness()
        harness.verifyResults = [false, false]

        let outcome = await harness.inserter.insert("hello", into: target())

        guard case .recoverable = outcome else {
            return XCTFail("expected recoverable, got \(outcome)")
        }
    }

    /// The paste fallback is the last resort: when the value is unreadable
    /// there is nothing better to try, so an unknowable result is accepted
    /// rather than telling the user it failed when it probably worked.
    func test_pasteFallback_withUnknowableVerification_isAccepted() async {
        let harness = Harness()
        harness.directInsertSucceeds = false
        harness.verifyResults = [nil]

        let outcome = await harness.inserter.insert("hello", into: target())

        XCTAssertEqual(outcome, .insertedByPaste)
    }

    func test_confirmedDirectInsert_neverPastes() async {
        let harness = Harness()
        harness.verifyResults = [true]

        _ = await harness.inserter.insert("hello", into: target())

        XCTAssertNil(harness.pastedToPID, "a confirmed direct write must not also paste")
        XCTAssertEqual(harness.verifyCallCount, 1, "verified once, not re-verified after a paste")
    }

    // MARK: - Paste fallback

    func test_axUnsupported_fallsBackToPaste_andRestoresTheClipboard() async {
        let harness = Harness()
        harness.directInsertSucceeds = false

        let outcome = await harness.inserter.insert("hello", into: target())

        XCTAssertEqual(outcome, .insertedByPaste)
        XCTAssertEqual(harness.wroteTranscript, "hello")
        XCTAssertEqual(harness.pastedToPID, 42)
        XCTAssertEqual(harness.restored, harness.snapshot, "the multi-type clipboard comes back losslessly")
    }

    func test_newerExternalClipboardChange_isNeverOverwritten() async {
        let harness = Harness()
        harness.directInsertSucceeds = false
        harness.externalBumpAfterWrite = true

        let outcome = await harness.inserter.insert("hello", into: target())

        XCTAssertEqual(outcome, .insertedByPaste)
        XCTAssertNil(harness.restored, "an external write after ours must win")
    }

    func test_pasteFailure_isRecoverable_andStillRestores() async {
        let harness = Harness()
        harness.directInsertSucceeds = false
        harness.pasteSucceeds = false

        let outcome = await harness.inserter.insert("hello", into: target())

        guard case .recoverable = outcome else {
            return XCTFail("expected recoverable, got \(outcome)")
        }
        XCTAssertEqual(harness.restored, harness.snapshot)
    }

    func test_unverifiedPasteDelivery_isRecoverable_soTheTranscriptIsNeverLost() async {
        let harness = Harness()
        harness.directInsertSucceeds = false
        harness.verifyResults = [false]

        let outcome = await harness.inserter.insert("hello", into: target())

        guard case .recoverable = outcome else {
            return XCTFail("expected recoverable, got \(outcome)")
        }
        XCTAssertEqual(harness.restored, harness.snapshot, "the clipboard still restores")
    }

    // MARK: - Refusals (fail closed)

    func test_focusLoss_isRecoverable_andTouchesNothing() async {
        let harness = Harness()
        harness.stillFocused = false

        let outcome = await harness.inserter.insert("hello", into: target())

        guard case .recoverable = outcome else {
            return XCTFail("expected recoverable, got \(outcome)")
        }
        XCTAssertNil(harness.directInsertReceived)
        XCTAssertNil(harness.wroteTranscript)
    }

    func test_secureTarget_isRejected_beforeAnythingRuns() async {
        let harness = Harness()
        let outcome = await harness.inserter.insert("hunter2", into: target(secure: true))

        guard case .recoverable = outcome else {
            return XCTFail("expected recoverable, got \(outcome)")
        }
        XCTAssertNil(harness.directInsertReceived, "secure fields must never receive dictation")
        XCTAssertNil(harness.wroteTranscript)
        XCTAssertNil(harness.pastedToPID)
    }

    func test_emptyText_isRecoverable_withoutSideEffects() async {
        let harness = Harness()
        let outcome = await harness.inserter.insert("", into: target())

        guard case .recoverable = outcome else {
            return XCTFail("expected recoverable, got \(outcome)")
        }
        XCTAssertNil(harness.directInsertReceived)
    }
}
