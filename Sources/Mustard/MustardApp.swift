import SwiftUI
import SwiftData
import AppKit
import MustardKit

@MainActor
private final class MustardAppScheduler {
    private let agent: AgentService
    private let taskAgent: AgentTaskCoordinator
    private let noteIndex: NoteIndexService
    private let calendar: GoogleCalendarService
    private var schedulerTask: Task<Void, Never>?
    private var lastInbox = Date.distantPast
    private var didReconcileTaskRuns = false

    var isStarted: Bool { schedulerTask != nil }

    init(
        agent: AgentService,
        taskAgent: AgentTaskCoordinator,
        noteIndex: NoteIndexService,
        calendar: GoogleCalendarService
    ) {
        self.agent = agent
        self.taskAgent = taskAgent
        self.noteIndex = noteIndex
        self.calendar = calendar
    }

    func startIfNeeded() {
        guard schedulerTask == nil else { return }
        calendar.bootstrap()
        schedulerTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        if let self { await self.runSourceTick() }
                        try? await Task.sleep(for: .seconds(60))
                    }
                }
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        if let self { await self.runDelegatedTick() }
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
                await group.waitForAll()
            }
        }
    }

    func stop() async {
        guard let schedulerTask else { return }
        schedulerTask.cancel()
        await schedulerTask.value
        self.schedulerTask = nil
    }

    private func runSourceTick() async {
        if !agent.isSweeping, !agent.isExecuting, !taskAgent.isRunning {
            let settings = SourceSettingsStore.loadOrMigrate()
            let updated = await agent.sweepDueSources(settings, now: .now)
            SourceSettingsStore.save(updated)
            if Date.now.timeIntervalSince(lastInbox) >= 600 {
                for source in updated.sources where source.enabled && !source.workingDirectory.isEmpty {
                    await agent.ingestInbox(workingDirectory: source.workingDirectory)
                    let areaName = AreaMapping.areaName(forProject: source.project) ?? ""
                    if !areaName.isEmpty {
                        // Order remains load-bearing (BAK-92): export sees a pending
                        // live result before ingest archives it.
                        agent.exportWorkOrders(
                            workingDir: source.workingDirectory,
                            area: areaName,
                            project: source.project
                        )
                        agent.ingestAgentResults(workingDir: source.workingDirectory)
                    }
                }
                // Area-less connected-worker hand-offs (F26) route to the default KB —
                // the meeting vault — since they match no source's area filter above.
                let defaultDir = UserDefaults.standard.string(forKey: "meetingVaultPath") ?? ""
                if !defaultDir.isEmpty, !updated.sources.contains(where: { $0.enabled && $0.workingDirectory == defaultDir }) {
                    agent.exportAreaLessWork(workingDir: defaultDir, project: "Code Heroes")
                    agent.ingestAgentResults(workingDir: defaultDir)
                }
                lastInbox = .now
            }
        }

        // Cheap local work remains independent of the Claude execution gate.
        noteIndex.reindexDueProjects(SourceSettingsStore.loadOrMigrate())
        let meetingVaultPath = UserDefaults.standard.string(forKey: "meetingVaultPath") ?? ""
        if !meetingVaultPath.isEmpty,
           !UserDefaults.standard.bool(forKey: "didArchiveStaleMeetingTasks") {
            agent.archiveStaleMeetingTasks()
            UserDefaults.standard.set(true, forKey: "didArchiveStaleMeetingTasks")
        }
        if !meetingVaultPath.isEmpty, !agent.isSweeping, !agent.isExecuting {
            agent.importMeetingTasks(vaultRoot: meetingVaultPath)
        }
        if calendar.state == .connected {
            await calendar.fetch()
        }
    }

    private func runDelegatedTick() async {
        if !didReconcileTaskRuns {
            // Only advance to normal execution once recovery has durably persisted.
            // A transient save failure leaves the flag clear so the next 2s tick retries.
            guard taskAgent.reconcileInterruptedRuns() else { return }
            didReconcileTaskRuns = true
        }
        if !agent.isSweeping, !agent.isExecuting {
            await taskAgent.runNext(settings: SourceSettingsStore.loadOrMigrate())
        }
    }
}

struct MustardApp: App {
    private let container: ModelContainer
    @State private var executionGate: AgentExecutionGate
    @State private var agent: AgentService
    @State private var taskAgent: AgentTaskCoordinator
    @State private var noteIndex: NoteIndexService
    @State private var calendar: GoogleCalendarService
    @State private var scheduler: MustardAppScheduler
    @State private var hoverPanel: HoverPanel?
    @State private var notch: NotchController?
    @State private var notchNav = NotchNavigation()
    @State private var voiceCapture: VoiceTaskCaptureCoordinator?
    @State private var dictation: SystemDictationCoordinator?
    @State private var rewrite: RewriteController?
    @State private var clipboard: ClipboardServices?
    @State private var clipsHotKey: ClipsHotKey?
    @State private var meetingRecorder: MeetingCaptureCoordinator
    @State private var meetingSuggestions: MeetingSuggestionMonitor
    @State private var didRecoverMeetings = false
    init() {
        let container = MustardContainer.make()
        let executionGate = AgentExecutionGate()
        let agent = AgentService(context: container.mainContext, executionGate: executionGate)
        let taskAgent = AgentTaskCoordinator(context: container.mainContext, executionGate: executionGate)
        let noteIndex = NoteIndexService(context: container.mainContext)
        let keychain = KeychainTokenStore()
        let calendar = GoogleCalendarService(
            authSession: GoogleAuthSession(
                makeServer: { LoopbackRedirectServer() },
                tokenClient: GoogleTokenClient(),
                store: keychain,
                openURL: { NSWorkspace.shared.open($0) }),
            tokenClient: GoogleTokenClient(),
            eventsClient: GoogleEventsClient(),
            store: keychain,
            context: container.mainContext)
        self.container = container
        self._executionGate = State(initialValue: executionGate)
        self._agent = State(initialValue: agent)
        self._taskAgent = State(initialValue: taskAgent)
        self._noteIndex = State(initialValue: noteIndex)
        self._calendar = State(initialValue: calendar)
        self._scheduler = State(initialValue: MustardAppScheduler(
            agent: agent,
            taskAgent: taskAgent,
            noteIndex: noteIndex,
            calendar: calendar
        ))

        // Manual meeting recorder (Meetings Tasks 6–8): consent-gated
        // two-source capture with the on-device digest. Built here so both
        // the main window (review/retry) and the notch share one instance.
        let recordings = URL.applicationSupportDirectory
            .appending(path: "Mustard/Recordings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: recordings, withIntermediateDirectories: true)
        let meetingStore = MeetingAudioStore(recordingsRoot: recordings)
        let digestService = MeetingDigestService(
            service: OnDeviceLanguageService.live(),
            calendar: .current,
            loadPrompt: VoiceTaskDraftGenerator.bundledPrompt,
            // ~4 chars per token is the standard conservative estimate; the
            // chunker only needs a budget-shaped bound, not exact counts.
            tokenCount: { $0.count / 4 + 1 })
        self._meetingRecorder = State(initialValue: MeetingCaptureCoordinator(
            context: container.mainContext,
            capturing: ScreenCaptureMeetingAudio(),
            store: meetingStore,
            makeWriter: { uid, startedAt in
                try MeetingAudioWriter(store: meetingStore, meetingUID: uid, startedAt: startedAt)
            },
            transcription: .liveMeeting(),
            generateDigest: { segments, now in
                await digestService.digest(segments: segments, now: now)
            }))
        let recorder = _meetingRecorder.wrappedValue
        self._meetingSuggestions = State(initialValue: MeetingSuggestionMonitor(
            events: { (try? container.mainContext.fetch(FetchDescriptor<CalendarEvent>())) ?? [] },
            signals: { MeetingAppSignals.current() },
            isRecording: { recorder.state != .idle }))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(agent)
                .environment(taskAgent)
                .environment(noteIndex)
                .environment(calendar)
                .environment(notchNav)
                .environment(meetingRecorder)
                .frame(minWidth: 640, minHeight: 520)
                .task {
                    let container = container
                    let agent = agent
                    scheduler.startIfNeeded()
                    if hoverPanel == nil {
                        hoverPanel = HoverPanel {
                            AnyView(
                                HoverPanelView()
                                    .environment(agent)
                                    .environment(taskAgent)
                                    .modelContainer(container)
                            )
                        }
                    }
                    if !didRecoverMeetings {
                        // Crash-left partials surface once per launch, and
                        // audio past the 30-day retention (pinned exempt)
                        // is cleared — transcripts and digests stay.
                        meetingRecorder.recoverOnLaunch()
                        MeetingRetention.sweep(
                            meetings: (try? container.mainContext.fetch(
                                FetchDescriptor<MeetingRecord>())) ?? [],
                            store: MeetingAudioStore(
                                recordingsRoot: URL.applicationSupportDirectory
                                    .appending(path: "Mustard/Recordings", directoryHint: .isDirectory)),
                            context: container.mainContext,
                            now: .now)
                        meetingSuggestions.startPolling()
                        didRecoverMeetings = true
                    }
                    // Built BEFORE the notch: the panel's content closure captures
                    // the services box, so it has to exist first.
                    if clipboard == nil {
                        // Mustard owns clipboard capture (notch shelf spec §1):
                        // one poller, concealed/transient types skipped, password
                        // managers excluded, 200-item history in SwiftData.
                        let store = ClipStore(context: container.mainContext)
                        let monitor = ClipboardMonitor(pasteboard: LivePasteboard()) { candidate in
                            store.ingest(candidate)
                        }
                        monitor.start()
                        clipboard = ClipboardServices(
                            store: store, monitor: monitor, paster: .live(monitor: monitor))
                    }
                    if notch == nil {
                        // Strong, app-lifetime capture (same shape as `agent`
                        // above) — the @State optional itself must not be read
                        // from inside the escaping content closure.
                        let clipboard = clipboard
                        let controller = NotchController { controller in
                            AnyView(
                                NotchView(controller: controller)
                                    .environment(agent)
                                    .environment(taskAgent)
                                    .environment(notchNav)
                                    .environment(meetingRecorder)
                                    .environment(meetingSuggestions)
                                    .environment(clipboard)
                                    .modelContainer(container)
                            )
                        }
                        controller.show()
                        notch = controller

                        if clipsHotKey == nil {
                            // ⌃⌥V anywhere → the panel opens pinned on Clips.
                            // Carbon does the background work; the menu item
                            // below only makes the chord discoverable. A
                            // conflict is logged by `register()`, never silent.
                            let hotKey = ClipsHotKey()
                            hotKey.onPress = {
                                controller.openPinned(on: NotchTabModel.clipsHotKeyTab)
                            }
                            hotKey.register()
                            clipsHotKey = hotKey
                        }
                    }
                    if voiceCapture == nil {
                        // Push-to-talk capture: hold ⌃⌥Space anywhere, speak, release
                        // → raw Inbox task, quick-edit card, on-device drafting. One
                        // coordinator per app; permission pre-flight happens at
                        // activation, never mid-capture.
                        let capture = VoiceTaskCaptureCoordinator(
                            context: container.mainContext, navigation: notchNav)
                        capture.activate()
                        voiceCapture = capture
                    }
                    if rewrite == nil, #available(macOS 26.0, *) {
                        // On-device rewrite: select text anywhere, tap ⌃⌥R, review
                        // the rewrite in a non-activating card, Return to replace.
                        // Nothing in the target app changes before that.
                        let controller = RewriteController.live()
                        controller.activate()
                        rewrite = controller
                    }
                    if dictation == nil {
                        // System-wide dictation: hold ⌃⌥D in any app, speak, release
                        // → the words land at the cursor (never in secure fields,
                        // never in Mustard's store).
                        let coordinator = SystemDictationCoordinator.live()
                        coordinator.activate()
                        dictation = coordinator
                    }
                }
        }
        .modelContainer(container)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Toggle Hover Panel") { hoverPanel?.toggle() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                // The strip is always on screen (`show()` at launch), so ⌘⇧N
                // toggles the PIN, not visibility — hiding it outright would
                // leave no way back to the ambient notch.
                Button("Toggle Notch") { notch?.togglePinned() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Clips") { notch?.openPinned(on: NotchTabModel.clipsHotKeyTab) }
                    .keyboardShortcut("v", modifiers: [.control, .option])
            }
        }
    }
}
