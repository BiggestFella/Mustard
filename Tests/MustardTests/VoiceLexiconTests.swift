import XCTest
import SwiftData
@testable import MustardKit

final class VoiceLexiconTests: XCTestCase {

    // MARK: - Rank order

    func test_rankOrder_userTermsFirstThenAreasThenListsThenOwnersThenTitles() {
        let result = VoiceLexicon.terms(
            areas: ["Sandvik"],
            taskLists: ["Thales Onboarding"],
            taskTitles: ["Prep the Sandvik demo", "Prep the Sandvik pitch"],
            proposalOwners: ["Fahad"],
            userTerms: ["Cavehole"])
        // userTerms, then areas, then taskLists, then proposalOwners, then
        // title-derived terms — in that order, before dedup collapses repeats.
        XCTAssertEqual(result.first, "Cavehole")
        let cavIdx = result.firstIndex(of: "Cavehole")!
        let sandvikIdx = result.firstIndex(of: "Sandvik")!
        let thalesListIdx = result.firstIndex(of: "Thales Onboarding")!
        let fahadIdx = result.firstIndex(of: "Fahad")!
        XCTAssertLessThan(cavIdx, sandvikIdx)
        XCTAssertLessThan(sandvikIdx, thalesListIdx)
        XCTAssertLessThan(thalesListIdx, fahadIdx)
    }

    // MARK: - Case-insensitive dedup, first occurrence wins

    func test_dedup_caseInsensitive_firstOccurrenceWins() {
        let result = VoiceLexicon.terms(
            areas: ["Thales"],
            taskLists: ["THALES"],
            userTerms: ["thales"])
        // userTerms is ranked first, so its casing survives even though
        // areas/taskLists mention the same word in different casing.
        XCTAssertEqual(result.filter { $0.lowercased() == "thales" }, ["thales"])
    }

    // MARK: - Title heuristic positives

    func test_titleHeuristic_acronymStyleCode_keptEvenAsSingleton() {
        let result = VoiceLexicon.terms(taskTitles: ["Ship the DLA export"])
        XCTAssertTrue(result.contains("DLA"))
    }

    func test_titleHeuristic_secondAcronymStyleCode() {
        let result = VoiceLexicon.terms(taskTitles: ["File the CDSB report"])
        XCTAssertTrue(result.contains("CDSB"))
    }

    func test_titleHeuristic_repeatedCapitalizedWord_kept() {
        let result = VoiceLexicon.terms(taskTitles: [
            "Follow up with Thales on the SDK",
            "Thales asked for a status update"
        ])
        XCTAssertTrue(result.contains("Thales"))
    }

    // MARK: - Title heuristic negatives

    func test_titleHeuristic_sentenceInitialStopword_dropped() {
        let result = VoiceLexicon.terms(taskTitles: ["Fix the login bug", "Fix the logout bug"])
        XCTAssertFalse(result.contains("Fix"))
    }

    func test_titleHeuristic_commonStopwords_dropped() {
        let result = VoiceLexicon.terms(taskTitles: [
            "Add the new export", "Add the new import", "Update the docs", "Update the readme"
        ])
        XCTAssertFalse(result.contains("Add"))
        XCTAssertFalse(result.contains("New"))
        XCTAssertFalse(result.contains("Update"))
        XCTAssertFalse(result.contains("The"))
    }

    func test_titleHeuristic_singletonCapitalizedWord_dropped() {
        let result = VoiceLexicon.terms(taskTitles: ["Talk to Priya about onboarding"])
        // "Priya" is capitalized but not acronym-style and appears only once.
        XCTAssertFalse(result.contains("Priya"))
    }

    // MARK: - Length bounds

    func test_lengthBounds_tooShortTermDropped() {
        let result = VoiceLexicon.terms(userTerms: ["A", "Bo"])
        XCTAssertFalse(result.contains("A"))
        XCTAssertTrue(result.contains("Bo"))
    }

    func test_lengthBounds_tooLongTermDropped() {
        let longTerm = String(repeating: "x", count: 41)
        let okTerm = String(repeating: "y", count: 40)
        let result = VoiceLexicon.terms(userTerms: [longTerm, okTerm])
        XCTAssertFalse(result.contains(longTerm))
        XCTAssertTrue(result.contains(okTerm))
    }

    // MARK: - Cap enforcement

    func test_cap_enforced() {
        let areas = (0..<20).map { "Area\($0)" }
        let result = VoiceLexicon.terms(areas: areas, cap: 5)
        XCTAssertEqual(result.count, 5)
    }

    func test_cap_defaultIsOneHundred() {
        XCTAssertEqual(VoiceLexicon.defaultCap, 100)
    }

    // MARK: - User terms always survive the cap

    func test_userTerms_surviveCap_evenWhenOtherCategoriesOverflow() {
        let userTerms = (0..<10).map { "User\($0)" }
        let areas = (0..<50).map { "Area\($0)" }
        let result = VoiceLexicon.terms(areas: areas, userTerms: userTerms, cap: 10)
        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(Set(result), Set(userTerms))
    }

    // MARK: - Empty inputs

    func test_emptyInputs_returnsEmpty() {
        XCTAssertEqual(VoiceLexicon.terms(), [])
    }

    // MARK: - User-terms parsing (persisted as newline/comma-separated text)

    func test_parseUserTerms_splitsOnCommaAndNewlineAndTrims() {
        let raw = "Thales,  Sandvik\nFahad ,\n\nCavehole"
        XCTAssertEqual(VoiceLexicon.parseUserTerms(raw), ["Thales", "Sandvik", "Fahad", "Cavehole"])
    }

    func test_parseUserTerms_emptyString_returnsEmpty() {
        XCTAssertTrue(VoiceLexicon.parseUserTerms("").isEmpty)
    }

    // MARK: - Fetch-assembly seam (VoiceLexiconSource)

    @MainActor
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self,
            MeetingRecord.self, MeetingActionProposal.self,
            configurations: config)
        return ModelContext(container)
    }

    @MainActor
    func test_fetchAssembly_gathersAreasListsRecentTitlesAndOwners() throws {
        let ctx = try makeContext()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let area = Area(name: "Sandvik")
        ctx.insert(area)
        let list = TaskList(name: "Thales Rollout")
        ctx.insert(list)

        let recentTask = MustardTask(title: "Follow up with Fahad")
        recentTask.createdAt = now.addingTimeInterval(-60 * 60)  // 1 hour ago
        ctx.insert(recentTask)

        let staleTask = MustardTask(title: "Ancient task about Zylo")
        staleTask.createdAt = now.addingTimeInterval(-120 * 24 * 60 * 60)  // 120 days ago
        ctx.insert(staleTask)

        let meeting = MeetingRecord(title: "Standup")
        ctx.insert(meeting)
        let proposal = MeetingActionProposal(title: "Ping Thales", owner: "Fahad")
        proposal.meeting = meeting
        ctx.insert(proposal)

        try ctx.save()

        let lexicon = VoiceLexiconSource.fetch(context: ctx, now: now, userTerms: [])

        XCTAssertTrue(lexicon.contains("Sandvik"))
        XCTAssertTrue(lexicon.contains("Thales Rollout"))
        XCTAssertTrue(lexicon.contains("Fahad"))
        XCTAssertFalse(lexicon.contains("Zylo"), "tasks older than 90 days must not contribute terms")
    }

    @MainActor
    func test_fetchAssembly_userTermsRankFirst() throws {
        let ctx = try makeContext()
        let area = Area(name: "Sandvik")
        ctx.insert(area)
        try ctx.save()

        let lexicon = VoiceLexiconSource.fetch(context: ctx, now: .now, userTerms: ["Cavehole"])
        XCTAssertEqual(lexicon.first, "Cavehole")
    }
}
