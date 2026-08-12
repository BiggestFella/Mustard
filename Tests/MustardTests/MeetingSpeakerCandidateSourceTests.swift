import XCTest
import SwiftData
@testable import MustardKit

/// Candidate assembly for meeting speaker attribution (BAK-335): past
/// meeting-action owners union the user's custom vocabulary. `CalendarEvent`
/// does not model attendees (verified: it has no participant list), so it
/// contributes nothing here — see MeetingSpeakerCandidateSource's doc
/// comment and task.md for the verdict.
final class MeetingSpeakerCandidateSourceTests: XCTestCase {

    @MainActor
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: MeetingRecord.self, MeetingActionProposal.self,
            configurations: config)
        return ModelContext(container)
    }

    @MainActor
    func test_fetch_gathersPastProposalOwners() throws {
        let ctx = try makeContext()
        let meeting = MeetingRecord(title: "Standup")
        ctx.insert(meeting)
        let proposal = MeetingActionProposal(title: "Ping Thales", owner: "Fahad")
        proposal.meeting = meeting
        ctx.insert(proposal)
        try ctx.save()

        let candidates = MeetingSpeakerCandidateSource.fetch(context: ctx, userTerms: [])

        XCTAssertTrue(candidates.contains("Fahad"))
    }

    @MainActor
    func test_fetch_unionsUserTerms() throws {
        let ctx = try makeContext()

        let candidates = MeetingSpeakerCandidateSource.fetch(context: ctx, userTerms: ["Jerry"])

        XCTAssertTrue(candidates.contains("Jerry"))
    }

    @MainActor
    func test_fetch_deduplicatesCaseInsensitively() throws {
        let ctx = try makeContext()
        let meeting = MeetingRecord(title: "Standup")
        ctx.insert(meeting)
        let proposal = MeetingActionProposal(title: "Ping Thales", owner: "Fahad")
        proposal.meeting = meeting
        ctx.insert(proposal)
        try ctx.save()

        let candidates = MeetingSpeakerCandidateSource.fetch(context: ctx, userTerms: ["fahad"])

        XCTAssertEqual(
            candidates.filter { $0.lowercased() == "fahad" }.count, 1,
            "the same name from two sources must not appear twice")
    }

    @MainActor
    func test_fetch_dropsNilAndBlankOwners() throws {
        let ctx = try makeContext()
        let meeting = MeetingRecord(title: "Standup")
        ctx.insert(meeting)
        let noOwner = MeetingActionProposal(title: "No owner", owner: nil)
        noOwner.meeting = meeting
        let blankOwner = MeetingActionProposal(title: "Blank owner", owner: "   ")
        blankOwner.meeting = meeting
        ctx.insert(noOwner)
        ctx.insert(blankOwner)
        try ctx.save()

        let candidates = MeetingSpeakerCandidateSource.fetch(context: ctx, userTerms: [])

        XCTAssertTrue(candidates.isEmpty)
    }

    @MainActor
    func test_fetch_noSources_returnsEmpty() throws {
        let ctx = try makeContext()

        let candidates = MeetingSpeakerCandidateSource.fetch(context: ctx, userTerms: [])

        XCTAssertTrue(candidates.isEmpty)
    }
}
