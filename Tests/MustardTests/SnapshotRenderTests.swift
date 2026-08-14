import XCTest
import SwiftUI
import AppKit
import SwiftData
@testable import MustardKit

/// Visual render harness — NOT a pass/fail test. Renders the app's screens to
/// PNGs in `.build/snapshots/` so they can be eyeballed for obvious visual
/// defects (black boxes, unreadable text, broken layout). Uses AppKit
/// `cacheDisplay`, which faithfully renders native controls (`TextEditor`,
/// `DatePicker`, `Picker`) that SwiftUI's `ImageRenderer` cannot.
///
/// Skipped unless `MUSTARD_SNAPSHOT=1`, so `swift test` / CI are unaffected:
///   MUSTARD_SNAPSHOT=1 swift test --filter SnapshotRenderTests
///
/// Renders in `.aqua` (light) — the app's pinned appearance (RootView).
final class SnapshotRenderTests: XCTestCase {

    @MainActor
    private func renderPNG(_ view: some View, _ name: String, _ size: CGSize) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        host.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("no bitmap rep for \(name)"); return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            XCTFail("png encode failed for \(name)"); return
        }
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
        print("SNAPSHOT \(name).png (\(Int(size.width))x\(Int(size.height)))")
    }

    @MainActor
    func test_renderScreens() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MUSTARD_SNAPSHOT"] == "1",
            "set MUSTARD_SNAPSHOT=1 to render snapshots")

        let container = PreviewData.container
        let agent = AgentService(context: container.mainContext)
        let full = CGSize(width: 1000, height: 680)
        let screen = CGSize(width: 860, height: 680)

        renderPNG(RootView().modelContainer(container).environment(agent), "root", full)
        renderPNG(TodayView().modelContainer(container).environment(agent), "today", screen)
        renderPNG(BoardView().modelContainer(container).environment(agent), "board", screen)
        renderPNG(WeekView().modelContainer(container).environment(agent), "week", screen)
        renderPNG(AgentConsoleView().modelContainer(container).environment(agent), "agent", screen)
        renderPNG(ListContentView(scope: .unfiled).modelContainer(container).environment(agent), "lists", screen)

        if let task = try container.mainContext.fetch(FetchDescriptor<MustardTask>()).first {
            renderPNG(
                TaskDetailSheet(task: task).modelContainer(container).environment(agent),
                "task-detail", CGSize(width: 460, height: 560))
        }
    }

    /// Focused Phase 6A visual harness. Kept separate from `test_renderScreens` so this
    /// task does not change the broad snapshot setup or depend on the live app scheduler.
    @MainActor
    func test_renderCodeHeroesReadOnlyProjection() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MUSTARD_SNAPSHOT"] == "1",
            "set MUSTARD_SNAPSHOT=1 to render snapshots")

        let container = PreviewData.container
        let context = container.mainContext
        let agent = AgentService(context: context)
        let taskAgent = AgentTaskCoordinator(context: context)
        let draftPanel = AgentDraftPanelState()
        guard let ordinaryTask = try context.fetch(FetchDescriptor<MustardTask>()).first else {
            return XCTFail("Preview data needs an ordinary task")
        }

        let projection = MustardTask(title: "Choose the Digital Licence enforcement approach", owner: .agent)
        projection.source = CodeHeroesDecisionPolicy.source
        projection.sourceURL = "/tmp/code-heroes/operations/decision-queue.json"
        projection.stage = .needsInput
        projection.priority = .high
        projection.tags = ["codeheroes", "decision", "human-action"]
        projection.notes = "Question: Which repository option should be adopted?\nNext action: Resolve the canonical decision in the Code Heroes repository."
        projection.links = [TaskLink(label: "Decision", url: "/tmp/code-heroes/operations/decisions/open/DEC-DL-1.md")]

        renderPNG(
            VStack(spacing: 12) {
                MustardBoardCard(task: projection, showConfidence: true)
                MustardBoardCard(task: ordinaryTask, showConfidence: true)
            }
            .padding(16)
            .modelContainer(container)
            .environment(agent)
            .environment(taskAgent)
            .background(Theme.Palette.surface),
            "code-heroes-card-comparison", CGSize(width: 260, height: 460))
        renderPNG(
            VStack(spacing: 0) {
                TimelineRow(task: projection, onToggleDone: {})
                Divider().overlay(Theme.Palette.hairline)
                TimelineRow(task: ordinaryTask, onToggleDone: {})
            }
            .padding(16)
            .modelContainer(container)
            .environment(agent)
            .background(Theme.Palette.bg),
            "code-heroes-timeline-comparison", CGSize(width: 520, height: 220))
        renderPNG(
            TaskDetailSheet(task: projection)
                .modelContainer(container)
                .environment(agent)
                .environment(taskAgent)
                .environment(draftPanel),
            "code-heroes-read-only-detail", CGSize(width: 460, height: 680))
        renderPNG(
            TaskDetailSheet(task: ordinaryTask)
                .modelContainer(container)
                .environment(agent)
                .environment(taskAgent)
                .environment(draftPanel),
            "ordinary-editable-detail", CGSize(width: 460, height: 680))
    }
}
