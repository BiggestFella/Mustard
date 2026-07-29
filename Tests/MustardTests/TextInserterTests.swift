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
        var externalBumpAfterWrite = false

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
                settle: {})
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
