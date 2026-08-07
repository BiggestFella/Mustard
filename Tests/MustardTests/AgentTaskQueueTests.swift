import XCTest
@testable import MustardKit

final class AgentTaskQueueTests: XCTestCase {
    func test_nextRunnablePrioritizesPriorityBeforeAge() {
        let adjacentPriorities: [(higher: TaskPriority, lower: TaskPriority)] = [
            (.urgent, .high),
            (.high, .normal),
            (.normal, .low),
        ]

        for (higher, lower) in adjacentPriorities {
            let oldLower = makeTask(
                uid: "old-\(lower.rawValue)",
                priority: lower,
                createdAt: date(100)
            )
            let newHigher = makeTask(
                uid: "new-\(higher.rawValue)",
                priority: higher,
                createdAt: date(200)
            )

            XCTAssertTrue(AgentTaskQueue.nextRunnable([oldLower, newHigher]) === newHigher)
        }
    }

    func test_nextRunnableUsesOldestCreationDateWithinPriority() {
        let newer = makeTask(uid: "newer", priority: .high, createdAt: date(200))
        let older = makeTask(uid: "older", priority: .high, createdAt: date(100))

        XCTAssertTrue(AgentTaskQueue.nextRunnable([newer, older]) === older)
    }

    func test_nextRunnableSkipsNonRunnableStagesWrongOwnerAndBlockedTasks() {
        let needsInput = makeTask(uid: "needs-input", stage: .needsInput)
        let inProgress = makeTask(uid: "in-progress", stage: .inProgress)
        let needsReview = makeTask(uid: "needs-review", stage: .needsReview)
        let wrongOwner = makeTask(uid: "wrong-owner", owner: .me)
        let blocked = makeTask(uid: "blocked")
        blocked.blockedReason = "Waiting on approval"

        XCTAssertNil(AgentTaskQueue.nextRunnable([
            needsInput, inProgress, needsReview, wrongOwner, blocked,
        ]))
    }

    func test_nextRunnableAcceptsForAgentAndQueuedStages() {
        let queued = makeTask(uid: "queued", stage: .queued, createdAt: date(200))
        let forAgent = makeTask(uid: "for-agent", stage: .forAgent, createdAt: date(100))

        XCTAssertTrue(AgentTaskQueue.nextRunnable([queued, forAgent]) === forAgent)
    }

    func test_nextRunnableSkipsConnectedWorkerRunAndKeepsNoRunTaskRunnable() {
        let connectedWorker = makeTask(
            uid: "connected-worker",
            stage: .queued,
            priority: .urgent,
            createdAt: date(100)
        )
        let run = AgentRun(task: connectedWorker)
        run.requiresConnectedWorker = true
        connectedWorker.agentRun = run
        let ordinary = makeTask(
            uid: "ordinary",
            stage: .queued,
            priority: .normal,
            createdAt: date(200)
        )

        XCTAssertNil(ordinary.agentRun)
        XCTAssertTrue(AgentTaskQueue.nextRunnable([connectedWorker, ordinary]) === ordinary)
    }

    func test_nextRunnableSkipsBackingOffRunUntilAttemptTimeThenReturnsIt() {
        let backingOff = makeTask(uid: "backing-off", stage: .queued, priority: .urgent, createdAt: date(100))
        let run = AgentRun(task: backingOff)
        run.nextAttemptAt = date(500)
        backingOff.agentRun = run
        let ready = makeTask(uid: "ready", stage: .queued, priority: .normal, createdAt: date(200))

        // Before its attempt time the higher-priority backing-off task is skipped.
        XCTAssertTrue(AgentTaskQueue.nextRunnable([backingOff, ready], now: date(400)) === ready)
        // At/after the attempt time it is runnable again and wins on priority.
        XCTAssertTrue(AgentTaskQueue.nextRunnable([backingOff, ready], now: date(500)) === backingOff)
    }

    func test_nextRunnableDeterministicallyBreaksExactTiesByUID() {
        let z = makeTask(uid: "task-z", createdAt: date(100))
        let a = makeTask(uid: "task-a", createdAt: date(100))

        XCTAssertTrue(AgentTaskQueue.nextRunnable([z, a]) === a)
        XCTAssertTrue(AgentTaskQueue.nextRunnable([a, z]) === a)
    }

    func test_routeMapsTaskAreaToEnabledSource() {
        let task = makeTask(areaName: "Digital Licence")
        let settings = SourceSettings(
            sources: [
                SourceConfig(
                    id: .vault,
                    project: "DL-Knowledge-Base",
                    enabled: true,
                    workingDirectory: "/kb/DL"
                ),
            ],
            state: []
        )

        XCTAssertEqual(
            AgentTaskQueue.route(task, settings: settings),
            AgentTaskRoute(project: "DL-Knowledge-Base", workingDirectory: "/kb/DL")
        )
    }

    func test_routeReturnsNilWithoutListOrArea() {
        let noList = makeTask()
        let noArea = makeTask()
        noArea.list = TaskList(name: "Unfiled")
        let settings = settings(project: "DL-Knowledge-Base", workingDirectory: "/kb/DL")

        XCTAssertNil(AgentTaskQueue.route(noList, settings: settings))
        XCTAssertNil(AgentTaskQueue.route(noArea, settings: settings))
    }

    func test_routeReturnsNilWhenNoProjectMapsToArea() {
        let task = makeTask(areaName: "Digital Licence")
        let settings = settings(project: "Unknown", workingDirectory: "/kb/unknown")

        XCTAssertNil(AgentTaskQueue.route(task, settings: settings))
    }

    func test_routeReturnsNilForDisabledSource() {
        let task = makeTask(areaName: "Digital Licence")
        let settings = SourceSettings(
            sources: [
                SourceConfig(
                    id: .vault,
                    project: "DL-Knowledge-Base",
                    enabled: false,
                    workingDirectory: "/kb/DL"
                ),
            ],
            state: []
        )

        XCTAssertNil(AgentTaskQueue.route(task, settings: settings))
    }

    func test_routeReturnsNilForEmptyOrWhitespaceWorkingDirectory() {
        let task = makeTask(areaName: "Digital Licence")

        XCTAssertNil(AgentTaskQueue.route(
            task,
            settings: settings(project: "DL-Knowledge-Base", workingDirectory: "")
        ))
        XCTAssertNil(AgentTaskQueue.route(
            task,
            settings: settings(project: "DL-Knowledge-Base", workingDirectory: "  \n\t")
        ))
    }

    func test_routeUsesFirstMatchingSourceInSettingsOrder() {
        let task = makeTask(areaName: "Digital Licence")
        let settings = SourceSettings(
            sources: [
                SourceConfig(id: .vault, project: "DL", workingDirectory: "/kb/first"),
                SourceConfig(
                    id: .vault,
                    project: "DL-Knowledge-Base",
                    workingDirectory: "/kb/second"
                ),
            ],
            state: []
        )

        XCTAssertEqual(
            AgentTaskQueue.route(task, settings: settings),
            AgentTaskRoute(project: "DL", workingDirectory: "/kb/first")
        )
    }

    // MARK: - Default route for area-less hand-offs (F26, ADR-0011 addendum)

    func test_route_areaLessTask_fallsBackToDefaultRoute() {
        // A voice-routed capture with no client area would otherwise strand (BAK-90);
        // the injected default KB rescues it so the connected worker can pick it up.
        let noArea = makeTask()
        let noAreaList = makeTask()
        noAreaList.list = TaskList(name: "Unfiled")   // list but no area
        let settings = settings(project: "DL-Knowledge-Base", workingDirectory: "/kb/DL")
        let fallback = AgentTaskRoute(project: "Code Heroes", workingDirectory: "/kb/ch-work")

        XCTAssertEqual(AgentTaskQueue.route(noArea, settings: settings, defaultRoute: fallback), fallback)
        XCTAssertEqual(AgentTaskQueue.route(noAreaList, settings: settings, defaultRoute: fallback), fallback)
    }

    func test_route_areaLessTask_stillNilWhenNoDefaultProvided() {
        // Absent a default, behaviour is unchanged — the strand is surfaced, not hidden.
        let noArea = makeTask()
        let settings = settings(project: "DL-Knowledge-Base", workingDirectory: "/kb/DL")
        XCTAssertNil(AgentTaskQueue.route(noArea, settings: settings))
    }

    func test_route_areadTask_prefersMatchingSourceOverDefault() {
        // A task WITH an area routes by area; the default never shadows a real match.
        let task = makeTask(areaName: "Digital Licence")
        let settings = settings(project: "DL-Knowledge-Base", workingDirectory: "/kb/DL")
        let fallback = AgentTaskRoute(project: "Code Heroes", workingDirectory: "/kb/ch-work")

        XCTAssertEqual(
            AgentTaskQueue.route(task, settings: settings, defaultRoute: fallback),
            AgentTaskRoute(project: "DL-Knowledge-Base", workingDirectory: "/kb/DL")
        )
    }

    func test_route_areadButUnmatched_staysNilEvenWithDefault() {
        // A task that HAS an area but no enabled matching source is a config gap
        // (the manual BAK-90 nudge case) — the default only rescues area-LESS tasks.
        let task = makeTask(areaName: "Digital Licence")
        let settings = settings(project: "Unknown", workingDirectory: "/kb/unknown")
        let fallback = AgentTaskRoute(project: "Code Heroes", workingDirectory: "/kb/ch-work")

        XCTAssertNil(AgentTaskQueue.route(task, settings: settings, defaultRoute: fallback))
    }

    private func makeTask(
        uid: String = UUID().uuidString,
        owner: TaskOwner = .agent,
        stage: TaskStage = .forAgent,
        priority: TaskPriority = .normal,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        areaName: String? = nil
    ) -> MustardTask {
        let task = MustardTask(title: uid, owner: owner)
        task.uid = uid
        task.stage = stage
        task.priority = priority
        task.createdAt = createdAt
        if let areaName {
            task.list = TaskList(name: "Work", area: Area(name: areaName))
        }
        return task
    }

    private func settings(project: String, workingDirectory: String) -> SourceSettings {
        SourceSettings(
            sources: [
                SourceConfig(
                    id: .vault,
                    project: project,
                    enabled: true,
                    workingDirectory: workingDirectory
                ),
            ],
            state: []
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
