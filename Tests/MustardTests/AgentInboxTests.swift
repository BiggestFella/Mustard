import XCTest
@testable import MustardKit

/// The "waiting on you" count behind the nudge / dock / badge (BAK-104).
final class AgentInboxTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    func test_waitingCount_pendingRecsPlusHumanAttentionTasks() {
        let r1 = Recommendation(title: "a") // default: pending, vault_note (not ignored)
        let r2 = Recommendation(title: "b")
        let question = MustardTask(title: "answer me"); question.stage = .needsInput
        let review = MustardTask(title: "review me"); review.stage = .needsReview
        let other = MustardTask(title: "planned"); other.stage = .planned

        XCTAssertEqual(
            AgentInbox.waitingCount(recommendations: [], tasks: [question, review], now: now),
            2
        )
        let n = AgentInbox.waitingCount(
            recommendations: [r1, r2], tasks: [question, review, other], now: now
        )
        XCTAssertEqual(n, 4) // 2 pending recs + 2 tasks needing human attention
    }

    func test_waitingCount_excludesSnoozedRecs() {
        let snoozed = Recommendation(title: "later")
        snoozed.snoozedUntil = now.addingTimeInterval(3600)
        let n = AgentInbox.waitingCount(recommendations: [snoozed], tasks: [], now: now)
        XCTAssertEqual(n, 0)
    }

    func test_waitingCount_emptyIsZero() {
        XCTAssertEqual(AgentInbox.waitingCount(recommendations: [], tasks: [], now: now), 0)
    }

    // MARK: dock text (BAK-106)

    func test_dockText_allClearWhenEmpty() {
        XCTAssertEqual(AgentInbox.dockText(recs: 0, items: 0), "All clear — nothing waiting on you")
    }

    func test_dockText_recsOnly_pluralizes() {
        XCTAssertEqual(AgentInbox.dockText(recs: 1, items: 0), "1 recommendation waiting on you")
        XCTAssertEqual(AgentInbox.dockText(recs: 2, items: 0), "2 recommendations waiting on you")
    }

    func test_dockText_itemsOnly_pluralizes() {
        XCTAssertEqual(AgentInbox.dockText(recs: 0, items: 1), "1 item waiting on you")
        XCTAssertEqual(AgentInbox.dockText(recs: 0, items: 2), "2 items waiting on you")
    }

    func test_dockText_both() {
        XCTAssertEqual(AgentInbox.dockText(recs: 1, items: 3), "1 recommendation and 3 items waiting on you")
    }

    // MARK: attention grouping (Task 11)

    func test_attention_emptyWhenNothingWaiting() {
        let planned = MustardTask(title: "p"); planned.stage = .planned
        let attention = AgentInbox.attention([planned])
        XCTAssertTrue(attention.inFlight.isEmpty)
        XCTAssertTrue(attention.questions.isEmpty)
        XCTAssertTrue(attention.reviews.isEmpty)
        XCTAssertTrue(attention.background.isEmpty)
    }

    // MARK: F27 — in-flight bucket + gate actions + unified count

    func test_attention_inFlight_allThreeGatesOldestFirst_excludingOthers() {
        let ap = MustardTask(title: "ap"); ap.stage = .needsApproval; ap.createdAt = Date(timeIntervalSince1970: 150)
        let q1 = MustardTask(title: "q1"); q1.stage = .needsInput; q1.createdAt = Date(timeIntervalSince1970: 200)
        let q2 = MustardTask(title: "q2"); q2.stage = .needsInput; q2.createdAt = Date(timeIntervalSince1970: 100)
        let r1 = MustardTask(title: "r1"); r1.stage = .needsReview; r1.createdAt = Date(timeIntervalSince1970: 300)
        let wip = MustardTask(title: "wip"); wip.stage = .inProgress
        let queued = MustardTask(title: "queued"); queued.stage = .queued

        let attention = AgentInbox.attention([q1, r1, wip, q2, ap, queued])

        // Oldest-first across all three gate stages: q2(100) ap(150) q1(200) r1(300)
        XCTAssertEqual(attention.inFlight.map(\.title), ["q2", "ap", "q1", "r1"])
    }

    func test_attention_inFlight_uidTiebreakOnEqualCreatedAt() {
        // Equal createdAt → ordered by uid ascending. Pin explicit inverted uids so a
        // broken (input-order-preserving) comparator fails deterministically, not ~50%.
        let a = MustardTask(title: "a"); a.stage = .needsReview
        a.createdAt = Date(timeIntervalSince1970: 500); a.uid = "2"
        let b = MustardTask(title: "b"); b.stage = .needsApproval
        b.createdAt = Date(timeIntervalSince1970: 500); b.uid = "1"
        let inFlight = AgentInbox.attention([a, b]).inFlight
        XCTAssertEqual(inFlight.map(\.title), ["b", "a"])   // uid "1" (b) before "2" (a)
    }

    func test_attentionTaskCount_includesNeedsApproval() {
        let ap = MustardTask(title: "ap"); ap.stage = .needsApproval
        let q = MustardTask(title: "q"); q.stage = .needsInput
        let rev = MustardTask(title: "rev"); rev.stage = .needsReview
        let planned = MustardTask(title: "p"); planned.stage = .planned

        XCTAssertEqual(AgentInbox.attentionTaskCount([ap, q, rev, planned]), 3)
    }

    func test_attentionTaskCount_matchesBoardWaitingCount() {
        // Defect #2, pinned: the console/hover/notch count must equal the board's
        // "N waiting on you" for the same task set (both derive from TaskStage.isGate).
        let ap = MustardTask(title: "ap"); ap.stage = .needsApproval
        let q = MustardTask(title: "q"); q.stage = .needsInput
        let rev = MustardTask(title: "rev"); rev.stage = .needsReview
        let planned = MustardTask(title: "p"); planned.stage = .planned
        let wip = MustardTask(title: "w"); wip.stage = .inProgress
        let tasks = [ap, q, rev, planned, wip]

        XCTAssertEqual(
            AgentInbox.attentionTaskCount(tasks),
            PersonalBoard.waitingCount(tasks, view: .everyone, area: .all)
        )
    }

    func test_gate_perStage() {
        let ap = MustardTask(title: "a"); ap.stage = .needsApproval
        XCTAssertEqual(AgentInbox.gate(for: ap)?.primary, "Approve")
        XCTAssertEqual(AgentInbox.gate(for: ap)?.secondary, "Deny")
        XCTAssertEqual(AgentInbox.gate(for: ap)?.oneClick, true)

        let input = MustardTask(title: "b"); input.stage = .needsInput
        XCTAssertEqual(AgentInbox.gate(for: input)?.primary, "Answer")
        XCTAssertNil(AgentInbox.gate(for: input)?.secondary)
        XCTAssertEqual(AgentInbox.gate(for: input)?.oneClick, false)

        let review = MustardTask(title: "c"); review.stage = .needsReview
        XCTAssertEqual(AgentInbox.gate(for: review)?.primary, "Accept")
        XCTAssertEqual(AgentInbox.gate(for: review)?.secondary, "Discard")

        let planned = MustardTask(title: "d"); planned.stage = .planned
        XCTAssertNil(AgentInbox.gate(for: planned))
        let queued = MustardTask(title: "e"); queued.stage = .queued
        XCTAssertNil(AgentInbox.gate(for: queued))
    }

    /// An outward action still says what approving actually does.
    func test_gate_gatedApproval_readsApproveAndRun() {
        let t = MustardTask(title: "Email Kamil"); t.stage = .needsApproval
        t.actionType = .draftEmail
        XCTAssertEqual(AgentInbox.gate(for: t)?.primary, "Approve & run")
    }

    /// A ledger-harvested meeting task is triaged for existence: one verb pair,
    /// the same on every surface, and neither word promises execution.
    func test_gate_ledgerMeetingTask_isKeepOrDelete() {
        let t = MustardTask(title: "Move the Sales Buddi Miro board")
        t.source = MeetingTaskSource.ledger
        t.stage = .needsApproval
        XCTAssertTrue(AgentInbox.isExistenceTriage(t))
        XCTAssertEqual(AgentInbox.gate(for: t)?.primary, "Keep")
        XCTAssertEqual(AgentInbox.gate(for: t)?.secondary, "Delete")
        XCTAssertEqual(AgentInbox.gate(for: t)?.oneClick, true)
    }

    /// Once handed to the agent the same row is an execute decision again, so it
    /// must not keep showing the existence-triage words.
    func test_gate_ledgerMeetingTask_agentOwned_isExecuteApproval() {
        let t = MustardTask(title: "Move the Sales Buddi Miro board", owner: .agent)
        t.source = MeetingTaskSource.ledger
        t.stage = .needsApproval
        XCTAssertFalse(AgentInbox.isExistenceTriage(t))
        XCTAssertEqual(AgentInbox.gate(for: t)?.primary, "Approve & run")
    }

    func test_gate_recordingMeetingTask_isNotExistenceTriage() {
        let t = MustardTask(title: "Recording action item")
        t.source = MeetingTaskSource.recording
        t.stage = .needsApproval
        XCTAssertFalse(AgentInbox.isExistenceTriage(t))
        XCTAssertEqual(AgentInbox.gate(for: t)?.primary, "Approve")
    }

    func test_backgroundCodeHeroesMaintenanceDoesNotInflateNeedsYou() {
        let maintenance = MustardTask(title: "refresh memory"); maintenance.source = CodeHeroesDecisionPolicy.source
        maintenance.stage = .needsReview
        maintenance.tags = ["codeheroes", "decision", "maintenance"]
        let action = MustardTask(title: "choose policy"); action.source = CodeHeroesDecisionPolicy.source
        action.stage = .needsInput
        action.tags = ["codeheroes", "decision", "human-action"]

        XCTAssertEqual(AgentInbox.attentionTaskCount([maintenance, action]), 1)
        let attention = AgentInbox.attention([maintenance, action])
        XCTAssertEqual(attention.questions.map(\.title), ["choose policy"])
        XCTAssertTrue(attention.reviews.isEmpty)
        XCTAssertEqual(attention.background.map(\.title), ["refresh memory"])
    }
}
