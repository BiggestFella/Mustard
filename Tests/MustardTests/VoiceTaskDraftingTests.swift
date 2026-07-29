import XCTest
@testable import MustardKit

/// Pure validation + merge rules for generated voice-task drafts (Voice Suite,
/// modern voice-task capture). Everything here is deterministic: pinned UTC
/// calendar, no ambient clock/zone, no model in sight.
final class VoiceTaskDraftingTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func isoDate(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    // MARK: - Title validation

    func test_title_trimsSurroundingWhitespace() {
        XCTAssertEqual(VoiceTaskDrafting.validatedTitle("  buy milk  "), "buy milk")
    }

    func test_title_collapsesInternalWhitespaceRuns() {
        XCTAssertEqual(VoiceTaskDrafting.validatedTitle("buy  milk\nnow"), "buy milk now")
    }

    func test_title_rejectsEmpty() {
        XCTAssertNil(VoiceTaskDrafting.validatedTitle(""))
    }

    func test_title_rejectsWhitespaceOnly() {
        XCTAssertNil(VoiceTaskDrafting.validatedTitle("  \n \t "))
    }

    // MARK: - Notes validation

    func test_notes_trimmed() {
        XCTAssertEqual(VoiceTaskDrafting.validatedNotes("  call after lunch \n"), "call after lunch")
    }

    func test_notes_nilAndBlankRejected() {
        XCTAssertNil(VoiceTaskDrafting.validatedNotes(nil))
        XCTAssertNil(VoiceTaskDrafting.validatedNotes("   \n"))
    }

    // MARK: - Allowed-area validation

    func test_area_exactMatchKept() {
        XCTAssertEqual(
            VoiceTaskDrafting.validatedArea("Code Heroes", allowedAreas: ["Code Heroes", "Personal"]),
            "Code Heroes")
    }

    func test_area_caseInsensitiveMatchCanonicalizesToAllowedSpelling() {
        XCTAssertEqual(
            VoiceTaskDrafting.validatedArea("  code heroes ", allowedAreas: ["Code Heroes"]),
            "Code Heroes")
    }

    func test_area_unknownRejected() {
        XCTAssertNil(VoiceTaskDrafting.validatedArea("Marketing", allowedAreas: ["Code Heroes"]))
    }

    func test_area_nilAndEmptyAllowListRejected() {
        XCTAssertNil(VoiceTaskDrafting.validatedArea(nil, allowedAreas: ["Code Heroes"]))
        XCTAssertNil(VoiceTaskDrafting.validatedArea("Code Heroes", allowedAreas: []))
    }

    // MARK: - URL validation (deterministic — never trusted from model output)

    func test_urls_validHTTPSAccepted() {
        XCTAssertEqual(
            VoiceTaskDrafting.validatedURLs(["https://example.com/x?y=1"]),
            [URL(string: "https://example.com/x?y=1")!])
    }

    func test_urls_trimmedBeforeParsing() {
        XCTAssertEqual(
            VoiceTaskDrafting.validatedURLs(["  http://example.com \n"]),
            [URL(string: "http://example.com")!])
    }

    func test_urls_invalidRejected() {
        XCTAssertEqual(VoiceTaskDrafting.validatedURLs([
            "not a url",            // free text
            "example.com",          // no scheme
            "ftp://example.com",    // non-web scheme
            "https://",             // no host
            "",                     // empty
        ]), [])
    }

    func test_urls_keepValidDropInvalid_preserveOrder_dedupe() {
        XCTAssertEqual(VoiceTaskDrafting.validatedURLs([
            "https://a.example",
            "nope",
            "https://b.example",
            "https://a.example",   // duplicate
        ]), [URL(string: "https://a.example")!, URL(string: "https://b.example")!])
    }

    // MARK: - Pinned UTC date conversion (injected calendar — never ambient)

    func test_date_dayOnlyLandsAtNineInInjectedZone() {
        // Date-only follows the quick-capture convention: 09:00 in the pinned zone.
        XCTAssertEqual(
            VoiceTaskDrafting.scheduledDate(fromISO8601: "2026-07-30", calendar: utc),
            isoDate("2026-07-30T09:00:00Z"))
    }

    func test_date_fullTimestampWithOffsetIsExact() {
        XCTAssertEqual(
            VoiceTaskDrafting.scheduledDate(fromISO8601: "2026-07-30T14:30:00Z", calendar: utc),
            isoDate("2026-07-30T14:30:00Z"))
        XCTAssertEqual(
            VoiceTaskDrafting.scheduledDate(fromISO8601: "2026-07-31T09:00:00+10:00", calendar: utc),
            isoDate("2026-07-30T23:00:00Z"))
    }

    func test_date_rolloverDayRejected() {
        // Feb 30 must not silently roll to March.
        XCTAssertNil(VoiceTaskDrafting.scheduledDate(fromISO8601: "2026-02-30", calendar: utc))
    }

    func test_date_malformedRejected() {
        XCTAssertNil(VoiceTaskDrafting.scheduledDate(fromISO8601: nil, calendar: utc))
        XCTAssertNil(VoiceTaskDrafting.scheduledDate(fromISO8601: "", calendar: utc))
        XCTAssertNil(VoiceTaskDrafting.scheduledDate(fromISO8601: "tomorrow", calendar: utc))
        XCTAssertNil(VoiceTaskDrafting.scheduledDate(fromISO8601: "30-07-2026", calendar: utc))
        XCTAssertNil(VoiceTaskDrafting.scheduledDate(fromISO8601: "2026-13-01", calendar: utc))
        XCTAssertNil(VoiceTaskDrafting.scheduledDate(fromISO8601: "2026-07-30T25:00:00Z", calendar: utc))
    }

    // MARK: - Whole-draft validation

    func test_validated_buildsDraftFromRawGeneratedStrings() {
        let draft = VoiceTaskDrafting.validated(
            title: "  Ship the  prep release ",
            notes: " email Kamil first ",
            areaName: "code heroes",
            scheduledISO8601: "2026-07-30",
            urls: ["https://example.com/ticket", "junk"],
            allowedAreas: ["Code Heroes"],
            calendar: utc)
        XCTAssertEqual(draft, VoiceTaskDraft(
            title: "Ship the prep release",
            notes: "email Kamil first",
            areaName: "Code Heroes",
            scheduledDate: isoDate("2026-07-30T09:00:00Z"),
            urls: [URL(string: "https://example.com/ticket")!]))
    }

    func test_validated_rejectsWholeDraftOnEmptyTitle() {
        XCTAssertNil(VoiceTaskDrafting.validated(
            title: "   ",
            notes: "notes",
            areaName: nil,
            scheduledISO8601: nil,
            urls: [],
            allowedAreas: [],
            calendar: utc))
    }

    func test_validated_dropsInvalidOptionalFields_keepsDraft() {
        let draft = VoiceTaskDrafting.validated(
            title: "Buy milk",
            notes: nil,
            areaName: "Unknown Area",
            scheduledISO8601: "not a date",
            urls: ["nope"],
            allowedAreas: ["Code Heroes"],
            calendar: utc)
        XCTAssertEqual(draft, VoiceTaskDraft(title: "Buy milk"))
    }

    // MARK: - Revisions

    func test_revisions_defaultToZeroForEveryField() {
        let r = VoiceTaskFieldRevisions()
        for field in VoiceTaskField.allCases {
            XCTAssertEqual(r[field], 0)
        }
    }

    func test_revisions_bumpIncrementsOnlyThatField() {
        var r = VoiceTaskFieldRevisions()
        r.bump(.title)
        r.bump(.title)
        r.bump(.urls)
        XCTAssertEqual(r[.title], 2)
        XCTAssertEqual(r[.urls], 1)
        XCTAssertEqual(r[.notes], 0)
    }

    func test_shouldApply_trueWhenRevisionUnchangedSinceRequest() {
        XCTAssertTrue(VoiceTaskDrafting.shouldApply(
            field: .title, current: [:], atRequest: [:]))
        XCTAssertTrue(VoiceTaskDrafting.shouldApply(
            field: .title, current: [.title: 3], atRequest: [.title: 3]))
    }

    func test_shouldApply_falseWhenUserEditedAfterRequest() {
        XCTAssertFalse(VoiceTaskDrafting.shouldApply(
            field: .title, current: [.title: 2], atRequest: [.title: 1]))
    }

    func test_shouldApply_checksOnlyTheAskedField() {
        // A title edit must not block a schedule apply.
        XCTAssertTrue(VoiceTaskDrafting.shouldApply(
            field: .schedule, current: [.title: 5], atRequest: [:]))
    }

    // MARK: - Merge

    func testLateModelTitleDoesNotOverwriteUserEdit() {
        let merged = VoiceTaskDrafting.merge(
            generated: .init(title: "Generated"),
            into: .init(title: "My title"),
            revisions: [.title: 2],
            requestRevisions: [.title: 1])
        XCTAssertEqual(merged.title, "My title")
    }

    func test_merge_appliesUntouchedFields() {
        let merged = VoiceTaskDrafting.merge(
            generated: VoiceTaskDraft(
                title: "Ship prep release",
                notes: "email first",
                areaName: "Code Heroes",
                scheduledDate: isoDate("2026-07-30T09:00:00Z"),
                urls: [URL(string: "https://example.com")!]),
            into: VoiceTaskDraft(title: "ship the prep release thing"),
            revisions: [:],
            requestRevisions: [:])
        XCTAssertEqual(merged, VoiceTaskDraft(
            title: "Ship prep release",
            notes: "email first",
            areaName: "Code Heroes",
            scheduledDate: isoDate("2026-07-30T09:00:00Z"),
            urls: [URL(string: "https://example.com")!]))
    }

    func test_merge_perFieldPrecedence_editedFieldKept_othersApplied() {
        // Leon edited the title mid-flight; the generated schedule still lands.
        let merged = VoiceTaskDrafting.merge(
            generated: VoiceTaskDraft(
                title: "Generated title",
                scheduledDate: isoDate("2026-07-30T09:00:00Z")),
            into: VoiceTaskDraft(title: "My title"),
            revisions: [.title: 1],
            requestRevisions: [:])
        XCTAssertEqual(merged.title, "My title")
        XCTAssertEqual(merged.scheduledDate, isoDate("2026-07-30T09:00:00Z"))
    }

    func test_merge_invalidGeneratedTitleNeverClearsCurrent() {
        let merged = VoiceTaskDrafting.merge(
            generated: .init(title: "   "),
            into: .init(title: "My title"),
            revisions: [:],
            requestRevisions: [:])
        XCTAssertEqual(merged.title, "My title")
    }

    func test_merge_absentGeneratedFieldsNeverClearUserValues() {
        // The generator proposed nothing for notes/area/schedule/urls: keep Leon's.
        let current = VoiceTaskDraft(
            title: "My title",
            notes: "my notes",
            areaName: "Code Heroes",
            scheduledDate: isoDate("2026-07-30T09:00:00Z"),
            urls: [URL(string: "https://example.com")!])
        let merged = VoiceTaskDrafting.merge(
            generated: VoiceTaskDraft(title: "Generated"),
            into: current,
            revisions: [:],
            requestRevisions: [:])
        XCTAssertEqual(merged, VoiceTaskDraft(
            title: "Generated",
            notes: "my notes",
            areaName: "Code Heroes",
            scheduledDate: isoDate("2026-07-30T09:00:00Z"),
            urls: [URL(string: "https://example.com")!]))
    }

    func test_merge_userEditedURLsNotReplacedByLateResult() {
        let mine = [URL(string: "https://mine.example")!]
        let merged = VoiceTaskDrafting.merge(
            generated: VoiceTaskDraft(title: "T", urls: [URL(string: "https://model.example")!]),
            into: VoiceTaskDraft(title: "T", urls: mine),
            revisions: [.urls: 1],
            requestRevisions: [:])
        XCTAssertEqual(merged.urls, mine)
    }

    func test_merge_blankGeneratedNotesDoNotOverwrite() {
        let merged = VoiceTaskDrafting.merge(
            generated: VoiceTaskDraft(title: "T", notes: "   "),
            into: VoiceTaskDraft(title: "T", notes: "my notes"),
            revisions: [:],
            requestRevisions: [:])
        XCTAssertEqual(merged.notes, "my notes")
    }
}
