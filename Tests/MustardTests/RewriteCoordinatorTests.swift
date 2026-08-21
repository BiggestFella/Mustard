import XCTest
@testable import MustardKit

/// The coordinator's phase machine, driven entirely by stubs. This is where the
/// spec's ordering guarantees are pinned: the gate runs before the read, the
/// write happens only after an explicit accept, and a failed write leaves the
/// original alone.
@available(macOS 26.0, *)
@MainActor
final class RewriteCoordinatorTests: XCTestCase {

    private func target(isSecure: Bool = false) -> FocusedTextTarget {
        FocusedTextTarget(
            applicationPID: 501, elementIdentifier: "e",
            selectedRange: NSRange(location: 0, length: 20),
            precedingCharacter: nil, followingCharacter: nil, isSecure: isSecure)
    }

    /// Records what the coordinator did, in order.
    final class Journal: @unchecked Sendable { var events: [String] = [] }

    private func coordinator(
        journal: Journal = Journal(),
        snapshot: FocusedTextTarget? = nil,
        role: String = "AXTextArea",
        hasAccessibility: Bool = true,
        read: SelectionRead = .text("I just wanted to quickly check in about the SOW"),
        draft: Result<RewriteDraft, Error> = .success(
            RewriteDraft(rewritten: "Can you send the SOW?", changeNote: "cut hedging")),
        reassert: SelectionRestorer.Outcome = .reasserted,
        write: TextInsertionOutcome = .insertedDirectly
    ) -> RewriteCoordinator {
        RewriteCoordinator(
            snapshotFocus: { journal.events.append("snapshot"); return snapshot ?? self.target() },
            focusedRole: { role },
            hasAccessibility: { hasAccessibility },
            applicationName: { _ in "Mail" },
            maxWords: { 1024 },
            bandInstructions: { "BAND" },
            readSelection: { _ in
                journal.events.append("read")
                return SelectionLadder.Resolution(read: read, rung: .axSelectedText)
            },
            generate: { _, _ in
                journal.events.append("generate")
                return try draft.get()
            },
            reassertSelection: { _ in journal.events.append("reassert"); return reassert },
            writeBack: { _, _ in journal.events.append("write"); return write })
    }

    // MARK: - Main-thread isolation (the 2026-08-21 SIGTRAP)

    /// The rewrite write-back is dictation's `TextInserter`, so ⌃⌥R shares the
    /// crash: an AX write serviced in-process re-enters NSTextView and trips
    /// HIToolbox's `dispatch_assert_queue(main)`. Every OS-facing seam of the
    /// coordinator — snapshot, read, re-assert, write — must therefore run on
    /// the main actor.
    ///
    /// Honest scope: with the seam types now `@MainActor` the compiler inserts
    /// the hop, so this cannot fail today; the runtime bite is in the callees
    /// (`TextInserterTests` / `AccessibilitySelectionReaderTests`, both of
    /// which DO fail without the fix). It stays as a guard for the plausible
    /// next mistake — making `accept()`/`invoke()` nonisolated, which would put
    /// the synchronous seams back on a cooperative thread.
    func test_everyOSFacingSeam_runsOnTheMainActor() async {
        let offMain = Journal()
        func note(_ seam: String) {
            if !Thread.isMainThread { offMain.events.append(seam) }
        }
        let sut = RewriteCoordinator(
            snapshotFocus: { note("snapshot"); return self.target() },
            focusedRole: { note("role"); return "AXTextArea" },
            hasAccessibility: { note("accessibility"); return true },
            applicationName: { _ in note("applicationName"); return "Mail" },
            maxWords: { 1024 },
            bandInstructions: { "BAND" },
            readSelection: { _ in
                note("read")
                return SelectionLadder.Resolution(read: .text("hedged sentence"), rung: .axSelectedText)
            },
            generate: { _, _ in RewriteDraft(rewritten: "Tight sentence", changeNote: "cut") },
            reassertSelection: { _ in note("reassert"); return .reasserted },
            writeBack: { _, _ in note("write"); return .insertedDirectly })

        await sut.invoke(intent: .tighten)
        await sut.accept()

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertEqual(offMain.events, [],
                       "AX/AppKit seams must run on the main actor: HIToolbox traps otherwise")
    }

    // MARK: - Ordering

    func test_invoke_gatesBeforeReading_soASecureFieldIsNeverRead() async {
        let journal = Journal()
        let sut = coordinator(journal: journal, snapshot: target(isSecure: true))

        await sut.invoke(intent: .tighten)

        XCTAssertEqual(sut.phase, .refused(.secureField))
        XCTAssertEqual(journal.events, ["snapshot"],
                       "No read may occur for a secure field — rung 3 would synthesize ⌘C.")
    }

    func test_invoke_reachesReviewWithoutWriting() async {
        let journal = Journal()
        let sut = coordinator(journal: journal)

        await sut.invoke(intent: .tighten)

        guard case .reviewing(let review) = sut.phase else {
            return XCTFail("expected reviewing, got \(sut.phase)")
        }
        XCTAssertEqual(review.rewritten, "Can you send the SOW?")
        XCTAssertEqual(review.original, "I just wanted to quickly check in about the SOW")
        XCTAssertEqual(review.intent, .tighten)
        XCTAssertEqual(journal.events, ["snapshot", "read", "generate"],
                       "Nothing is written until the user accepts.")
    }

    // MARK: - Refusals

    func test_invoke_refusesMissingAccessibility_withoutReading() async {
        let journal = Journal()
        let sut = coordinator(journal: journal, hasAccessibility: false)

        await sut.invoke(intent: .tighten)

        XCTAssertEqual(sut.phase, .refused(.accessibilityPermissionMissing))
        XCTAssertEqual(journal.events, ["snapshot"])
    }

    func test_invoke_refusesAnUnreadableSelection_namingTheApplication() async {
        let sut = coordinator(read: .unreadable)
        await sut.invoke(intent: .tighten)
        XCTAssertEqual(sut.phase, .refused(.unreadableSelection(application: "Mail")))
    }

    func test_invoke_mapsAModelFailure() async {
        let sut = coordinator(draft: .failure(LocalModelFailure.appleIntelligenceDisabled))
        await sut.invoke(intent: .tighten)
        XCTAssertEqual(sut.phase, .refused(.model(.appleIntelligenceDisabled)))
    }

    // MARK: - Accept

    func test_accept_reassertsTheRangeThenWrites() async {
        let journal = Journal()
        let sut = coordinator(journal: journal)
        await sut.invoke(intent: .tighten)

        await sut.accept()

        XCTAssertEqual(journal.events, ["snapshot", "read", "generate", "reassert", "write"],
                       "The range is re-asserted immediately before the write, in that order.")
        XCTAssertEqual(sut.phase, .idle, "A successful write closes the card.")
    }

    func test_accept_refusesToWrite_whenFocusMoved() async {
        let journal = Journal()
        let sut = coordinator(journal: journal, reassert: .focusChanged)
        await sut.invoke(intent: .tighten)

        await sut.accept()

        XCTAssertFalse(journal.events.contains("write"))
        XCTAssertEqual(sut.phase, .refused(.focusChanged))
    }

    func test_accept_keepsTheRewriteOnScreen_whenTheWriteFails() async {
        let sut = coordinator(write: .recoverable("the app didn't accept the paste"))
        await sut.invoke(intent: .tighten)

        await sut.accept()

        guard case .reviewing(let review) = sut.phase else {
            return XCTFail("A failed write must keep the card open, got \(sut.phase)")
        }
        XCTAssertEqual(review.rewritten, "Can you send the SOW?")
        XCTAssertEqual(review.writeFailure, "the app didn't accept the paste")
    }

    func test_accept_doesNothing_whenThereIsNoReview() async {
        let journal = Journal()
        let sut = coordinator(journal: journal)

        await sut.accept()

        XCTAssertEqual(journal.events, [], "An accept with no open card is a no-op, not a crash.")
    }

    // MARK: - Discard and re-invoke

    func test_discard_returnsToIdle_withoutWriting() async {
        let journal = Journal()
        let sut = coordinator(journal: journal)
        await sut.invoke(intent: .tighten)

        sut.discard()

        XCTAssertEqual(sut.phase, .idle)
        XCTAssertFalse(journal.events.contains("write"))
    }

    func test_reinvoke_whileReviewing_regeneratesAgainstTheSameOriginal() async {
        let journal = Journal()
        let sut = coordinator(journal: journal)
        await sut.invoke(intent: .tighten)

        await sut.invoke(intent: .tighten)

        XCTAssertEqual(journal.events, ["snapshot", "read", "generate", "generate"],
                       "Another take re-generates; it must not re-snapshot or re-read.")
    }

    func test_changeIntent_regeneratesWithTheNewIntent() async {
        let sut = coordinator()
        await sut.invoke(intent: .tighten)

        await sut.change(intent: .warmer)

        guard case .reviewing(let review) = sut.phase else {
            return XCTFail("expected reviewing")
        }
        XCTAssertEqual(review.intent, .warmer)
    }
}
