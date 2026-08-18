#if DEBUG
import Foundation
import SwiftData

/// DEBUG-only seed so the iOS Simulator has representative content to eyeball while the
/// mobile app has no create form and CloudKit sync (BAK-46) isn't wired. Runs once, only
/// if the store is empty — never in Release, never over real/synced data.
enum MobileSampleData {
    @MainActor
    static func seedIfEmpty(_ context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<MustardTask>())) ?? 0
        guard existing == 0 else { return }

        let cal = Calendar.current
        func today(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: .now) ?? .now }

        // Areas (per-list handoff dot colours).
        let dla = Area(name: "DLA SDK", colorHex: "#2D7FF9")
        let admin = Area(name: "Admin", colorHex: "#3E8E7E")
        let personal = Area(name: "Personal", colorHex: "#7F77DD")
        [dla, admin, personal].forEach(context.insert)
        let dlaList = TaskList(name: "DLA SDK", area: dla)
        let adminList = TaskList(name: "Admin", area: admin)
        let personalList = TaskList(name: "Errands", area: personal)
        [dlaList, adminList, personalList].forEach(context.insert)

        func task(_ title: String, stage: TaskStage, owner: TaskOwner = .me,
                  list: TaskList? = nil, at: Date? = nil, est: Int = 30,
                  priority: TaskPriority = .normal, tags: [String] = []) -> MustardTask {
            let t = MustardTask(title: title)
            t.stage = stage; t.owner = owner; t.list = list
            t.estimateMinutes = est; t.priority = priority; t.tags = tags
            if let at { t.scheduledAt = at; t.isTimed = true }
            context.insert(t)
            return t
        }

        // Today timeline + a done + inbox.
        _ = task("Team standup", stage: .scheduled, list: adminList, at: today(9, 30), est: 15)
        let release = task("Draft DLA 5.2 release notes", stage: .inProgress, list: dlaList,
                           at: today(10, 30), est: 90, priority: .high, tags: ["release", "docs"])
        // Starred so the iOS Today FOCUS band is visible in Simulator (BAK-247).
        release.focusOnDay = cal.startOfDay(for: .now)
        release.subtasks = [MustardTask(title: "Pull changelog"), MustardTask(title: "Review with Kamil")]
        release.subtasks?.forEach { $0.parent = release; context.insert($0) }
        _ = task("Reply to Thales SDK thread", stage: .scheduled, list: dlaList, at: today(14), est: 30, priority: .urgent)
        let done = task("Morning inbox sweep", stage: .done, list: adminList, at: today(8))
        done.completedAt = today(8, 20)
        _ = task("Buy standing-desk mat", stage: .inbox, list: personalList)
        _ = task("Read 'Deep Work' ch.4", stage: .planned, list: personalList, est: 45)

        // Agent pipeline: proposed (inbox), needsApproval (gated, w/ rec), queued, needsReview, blocked.
        let proposed = task("Chase overdue invoice #4821", stage: .inbox, owner: .agent, list: adminList)
        proposed.confidence = 0.82; proposed.actionType = .draftEmail

        let gated = task("Email Kamil re: BLE regression", stage: .needsApproval, owner: .agent,
                         list: dlaList, est: 30, priority: .high)
        gated.actionType = .draftEmail; gated.confidence = 0.76
        let rec = Recommendation(
            title: "Email Kamil re: BLE regression",
            body: "The BLE disconnect regression from 5.1 is still open; Kamil asked for a status by Friday.",
            actionType: "draft_email", confidence: 0.76,
            reasoning: "Flagged in yesterday's meeting notes; a reply is overdue and Kamil is blocked on it.",
            draft: "Hi Kamil,\n\nQuick update on the BLE disconnect regression — reproduced on 5.1, fix in review, expect it in 5.2.\n\nLeon")
        context.insert(rec)
        gated.delegation = rec

        let vault = task("Summarise sprint retro into the vault", stage: .queued, owner: .agent, list: adminList)
        vault.actionType = .vaultNote; vault.confidence = 0.9

        let review = task("Weekly metrics digest", stage: .needsReview, owner: .agent, list: adminList)
        review.actionType = .vaultNote; review.confidence = 0.88

        let blocked = task("Ship 5.2 to TestFlight", stage: .blocked, list: dlaList)
        blocked.blockedReason = "Waiting on Apple Developer entitlements"

        // Extra pending recommendations so the Agent badge / nudge / Triage deck have a queue.
        for (title, ctx, conf) in [
            ("Reschedule Friday 1:1 with Sam", "Calendar conflict with the release review", 0.7),
            ("Add 'BLE retry' to the backlog", "Mentioned twice in standup this week", 0.64),
            ("Archive the Q2 planning doc", "Superseded by the Q3 doc", 0.55),
        ] {
            let r = Recommendation(title: title, body: ctx, actionType: "create_task",
                                   confidence: conf, reasoning: ctx, draft: "")
            context.insert(r)
        }

        try? context.save()
    }
}
#endif
