import Foundation
import SwiftData

/// In-memory sample container for #Preview and manual demo runs.
@MainActor
public enum PreviewData {
    public static let container: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(
            for: Area.self, TaskList.self, MustardTask.self, Recommendation.self,
            AgentRun.self, AgentMessage.self, AgentDraft.self, CalendarEvent.self, NoteIndexEntry.self,
            MeetingRecord.self, MeetingTranscriptSegment.self, MeetingActionProposal.self,
            configurations: config
        )
        let ctx = container.mainContext
        let cal = Calendar.current
        func today(_ h: Int, _ m: Int) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: .now)!
        }
        // Handoff per-list dot colours (BAK-98). Mustard colours dots by Area, so each
        // handoff "area" gets its own Area carrying the canonical Theme area-dot hex:
        // DLA SDK blue / Admin green / Errands purple / Reading grey. (The handoff's
        // "Code Heroes"/"Personal" group headers are a sidebar grouping Mustard doesn't
        // model yet — exact per-list colour under a shared group needs a per-list
        // colorHex, deferred. See docs/design/redesign-2026/PRD.md.)
        let dlaArea = Area(name: "DLA SDK", colorHex: "#2D7FF9")    // Theme.Palette.areaBlue
        let adminArea = Area(name: "Admin", colorHex: "#3E8E7E")   // Theme.Palette.areaGreen
        let personal = Area(name: "Errands", colorHex: "#7F77DD")  // Theme.Palette.areaPurple
        let readingArea = Area(name: "Reading", colorHex: "#B0ACA1") // Theme.Palette.areaGrey
        let dev = TaskList(name: "DLA SDK", area: dlaArea)
        let admin = TaskList(name: "Admin", area: adminArea)
        let errands = TaskList(name: "Errands", area: personal)
        let reading = TaskList(name: "Reading", area: readingArea)
        for model in [dlaArea, adminArea, personal, readingArea] { ctx.insert(model) }
        for list in [dev, admin, errands, reading] { ctx.insert(list) }

        let standup = MustardTask(title: "Team standup", scheduledAt: today(9, 30))
        standup.estimateMinutes = 15
        standup.list = admin
        let focus = MustardTask(title: "Draft DLA 5.2 release notes", scheduledAt: today(10, 0))
        focus.estimateMinutes = 90
        focus.list = dev
        let sync = MustardTask(title: "Thales SDK sync", scheduledAt: today(11, 30))
        sync.list = dev
        // Timed agenda items obey the placement invariant (BAK-246): a scheduled task
        // is never in the Inbox, so the board preview doesn't render the very symptom.
        for t in [standup, focus, sync] { t.isTimed = true; PersonalBoard.normalizePlacement(t) }
        let loose = MustardTask(title: "Reply to Kamil re: BLE issue") // stays unfiled
        for task in [standup, focus, sync, loose] { ctx.insert(task) }

        let meeting = CalendarEvent(
            externalId: "sample-1", title: "Sprint planning",
            start: today(13, 0), end: today(14, 0),
            joinURL: "https://meet.google.com/sample"
        )
        ctx.insert(meeting)

        let rec = Recommendation(
            title: "Reply to Kamil re: BLE handshake regression",
            body: "Kamil asked for a status by EOD.",
            actionType: "draft_email", vaultPath: "/vault",
            confidence: 0.82,
            reasoning: "He flagged a regression and asked for status by EOD; the tracker shows the fix moved to In Review yesterday.",
            draft: "Hi Kamil,\n\nConfirming the BLE handshake regression is now in review — fix landed yesterday, QA verifying today. Verified build by EOD tomorrow.\n\nCheers,\nLeon",
            source: "gmail", sourceContext: "Thales SDK — kamil@thalesgroup.com"
        )
        ctx.insert(rec)

        // Sample note index entries (BAK-148) for the Notes surface preview.
        ctx.insert(NoteIndexEntry(project: "DL-Knowledge-Base", relativePath: "Home.md", title: "Home",
                                  forwardLinks: ["guides/Setup.md"], contentSnapshot: "# Home\ngo [[Setup]]"))
        ctx.insert(NoteIndexEntry(project: "DL-Knowledge-Base", relativePath: "guides/Setup.md", title: "Setup",
                                  contentSnapshot: "# Setup"))

        // Agent task-session samples (Task 12): one Needs You question and one Needs
        // Review output, each carrying a durable AgentRun conversation so Board, Agent
        // Console, and Task Detail render without any live CLI work.
        let prep = MustardTask(title: "Prep DLA 5.2 release", owner: .agent)
        prep.stage = .needsInput
        prep.list = dev
        prep.actionType = .ticket
        let prepRun = AgentRun(task: prep, workingDirectory: "/kb/DL", project: "DL-Knowledge-Base")
        prepRun.state = .needsInput
        prepRun.providerSessionID = "preview-prep-session"
        prep.agentRun = prepRun
        ctx.insert(prep); ctx.insert(prepRun)
        for m in [
            AgentMessage(run: prepRun, sequence: 0, role: .human, kind: .delegation, content: "Prep the DLA 5.2 release."),
            AgentMessage(run: prepRun, sequence: 1, role: .system, kind: .progress, content: "Agent started work."),
            AgentMessage(run: prepRun, sequence: 2, role: .agent, kind: .question,
                         content: "Which version number should the release notes target — 5.2.0 or 5.2.1?"),
        ] { ctx.insert(m) }

        let review = MustardTask(title: "Create Shortcut story for BLE regression", owner: .agent)
        review.stage = .needsReview
        review.list = dev
        review.actionType = .ticket
        let storyLink = TaskLink(label: "Shortcut sc-4821", url: "https://app.shortcut.com/codeheroes/story/4821")
        review.links = [storyLink]
        let reviewRun = AgentRun(task: review, workingDirectory: "/kb/DL", project: "DL-Knowledge-Base")
        reviewRun.state = .completed
        reviewRun.providerSessionID = "preview-review-session"
        reviewRun.completedAt = .now
        review.agentRun = reviewRun
        ctx.insert(review); ctx.insert(reviewRun)
        for m in [
            AgentMessage(run: reviewRun, sequence: 0, role: .human, kind: .delegation,
                         content: "Create a Shortcut story for the BLE handshake regression."),
            AgentMessage(run: reviewRun, sequence: 1, role: .system, kind: .progress, content: "Agent started work."),
            AgentMessage(run: reviewRun, sequence: 2, role: .agent, kind: .result,
                         content: "Created Shortcut story sc-4821 with repro steps and the linked tracker item.",
                         links: [storyLink]),
        ] { ctx.insert(m) }

        let draftsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mustard-preview/_agent/drafts/\(review.uid)", isDirectory: true)
        try? FileManager.default.createDirectory(at: draftsDir, withIntermediateDirectories: true)
        let draftRel = "_agent/drafts/\(review.uid)/jira-reply.md"
        try? "## Jira reply (draft)\n\nThe \"Manage my QDI\" option can't satisfy Apple 5.1.1(v) or Google Play account-deletion rules, so the delete-worded option must stay regardless of SSP.\n\n- Apple 5.1.1(v)\n- Google Play account-deletion"
            .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("mustard-preview/\(draftRel)"),
                   atomically: true, encoding: .utf8)
        reviewRun.workingDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("mustard-preview").path
        let previewDraft = AgentDraft(run: reviewRun, kind: .comment, title: "Manage my QDI — Jira reply",
                                      relativePath: draftRel)
        reviewRun.drafts = [previewDraft]
        ctx.insert(previewDraft)

        return container
    }()
}
