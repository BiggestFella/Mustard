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
    private let gmail: GmailService
    private var schedulerTask: Task<Void, Never>?
    private var lastInbox = Date.distantPast
    private var lastMeetingImportAt: Date?
    private var didReconcileTaskRuns = false

    var isStarted: Bool { schedulerTask != nil }

    init(
        agent: AgentService,
        taskAgent: AgentTaskCoordinator,
        noteIndex: NoteIndexService,
        calendar: GoogleCalendarService,
        gmail: GmailService
    ) {
        self.agent = agent
        self.taskAgent = taskAgent
        self.noteIndex = noteIndex
        self.calendar = calendar
        self.gmail = gmail
    }

    func startIfNeeded() {
        guard schedulerTask == nil else { return }
        // Adopt legacy meeting rows on the spot, before any tick. The hourly
        // importer also does this, but it sits behind vault file I/O, a
        // `meetingVaultPath` being set, and the Claude execution gate — so rows
        // born under the old execute-triage rules could keep showing
        // "Approve & run" (which still queues a real execution) long after
        // launch. This is a single fetch + filter, no files, and self-limiting.
        agent.adoptMeetingTaskOwnership()
        calendar.bootstrap()
        gmail.bootstrap()
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
        let now = Date.now
        if !agent.isSweeping, !agent.isExecuting, !taskAgent.isRunning {
            let settings = SourceSettingsStore.loadOrMigrate()
            let updated = await agent.sweepDueSources(settings, now: now)
            SourceSettingsStore.save(updated)
            let gmailSettings = GmailSettingsStore.load()
            if gmailSettings.enabled, gmail.state == .connected,
               GmailSettings.isDue(lastPolledAt: gmail.lastPolled,
                                   intervalMinutes: gmailSettings.pollIntervalMinutes, now: now) {
                await gmail.poll(projects: GmailTriage.routes(from: updated))
            }
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
        if !meetingVaultPath.isEmpty, !agent.isSweeping, !agent.isExecuting,
           MeetingTaskImportSchedule.isDue(lastImportAt: lastMeetingImportAt, now: now) {
            // Sweep before importing, every pass — not once ever. This used to be
            // gated on a `didArchiveStaleMeetingTasks` flag, so it fired a single
            // time in June 2026 and then never again while the importer kept
            // running underneath it; that is how 194 cards from Apr–Jun meetings
            // reached the board on 2026-08-13. Cheap (one fetch + filter) and
            // self-limiting: archiving retags the source, so a row is only ever
            // swept once. Shares the 7-day boundary with `MeetingTaskFreshness`,
            // which now keeps stale lines out at the door.
            agent.archiveStaleMeetingTasks(now: now)
            agent.importMeetingTasks(vaultRoot: meetingVaultPath)
            lastMeetingImportAt = now
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
    @State private var gmail: GmailService
    @State private var scheduler: MustardAppScheduler
    @State private var hoverPanel: HoverPanel?
    @State private var notch: NotchController?
    @State private var notchNav = NotchNavigation()
    @State private var hotKeys = HotKeyBindingsStore()
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
        let gmailKeychain = KeychainTokenStore(service: GmailService.keychainService)
        let gmail = GmailService(
            authSession: GoogleAuthSession(
                makeServer: { LoopbackRedirectServer() },
                tokenClient: GoogleTokenClient(),
                store: gmailKeychain,
                openURL: { NSWorkspace.shared.open($0) },
                scope: GmailService.scope),
            tokenClient: GoogleTokenClient(),
            client: GmailClient(),
            store: gmailKeychain,
            claude: ClaudeRunner.restrictedRun,
            executionGate: executionGate,
            ingest: { proposals, vaultPath in
                await agent.ingestExternal(proposals, vaultPath: vaultPath)
            })
        self.container = container
        self._executionGate = State(initialValue: executionGate)
        self._agent = State(initialValue: agent)
        self._taskAgent = State(initialValue: taskAgent)
        self._noteIndex = State(initialValue: noteIndex)
        self._calendar = State(initialValue: calendar)
        self._gmail = State(initialValue: gmail)
        self._scheduler = State(initialValue: MustardAppScheduler(
            agent: agent,
            taskAgent: taskAgent,
            noteIndex: noteIndex,
            calendar: calendar,
            gmail: gmail
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
                .environment(gmail)
                .environment(notchNav)
                .environment(meetingRecorder)
                .environment(hotKeys)
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
                                    .environment(gmail)
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
                    // the services box, so it has to exist first. `services` is a
                    // plain non-optional local — the escaping closure must never
                    // read the @State property back out.
                    let services: ClipboardServices
                    if let existing = clipboard {
                        services = existing
                    } else {
                        // Mustard owns clipboard capture (notch shelf spec §1):
                        // one poller, concealed/transient types skipped, password
                        // managers excluded, 200-item history in SwiftData.
                        let store = ClipStore(context: container.mainContext)
                        let monitor = ClipboardMonitor(pasteboard: LivePasteboard()) { candidate in
                            store.ingest(candidate)
                        }
                        monitor.start()
                        services = ClipboardServices(
                            store: store, monitor: monitor, paster: .live(monitor: monitor))
                        clipboard = services
                    }
                    // Same reason as `services`: the live-rebind closure below
                    // must capture the instance, never re-read the @State box.
                    var clipsKey = clipsHotKey
                    if notch == nil {
                        let controller = NotchController { controller in
                            AnyView(
                                NotchView(controller: controller)
                                    .environment(agent)
                                    .environment(taskAgent)
                                    .environment(notchNav)
                                    .environment(meetingRecorder)
                                    .environment(meetingSuggestions)
                                    .environment(services)
                                    .environment(gmail)
                                    .modelContainer(container)
                            )
                        }
                        controller.show()
                        notch = controller

                        if clipsKey == nil {
                            // ⌃⌥V (or whatever Settings → Hotkeys has bound)
                            // anywhere → the panel opens pinned on Clips.
                            // Carbon does the background work; the menu item
                            // below only makes the chord discoverable. A
                            // conflict is logged by `register()` and posted to
                            // the shared board, never silent.
                            let hotKey = ClipsHotKey()
                            hotKey.onPress = {
                                controller.openPinned(on: NotchTabModel.clipsHotKeyTab)
                            }
                            hotKey.register()
                            clipsKey = hotKey
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
                        // → the words land at the cursor (never in secure fields).
                        // Completed dictations are also kept in local clip history
                        // (notch shelf spec §1/§3) — hence the store, built above.
                        let coordinator = SystemDictationCoordinator.live(
                            clipStore: services.store)
                        coordinator.activate()
                        dictation = coordinator

                        // Ask macOS to keep this locale's speech assets on disk.
                        // Best-effort and detached: a refusal is normal (the
                        // reservation pool is shared and device-capped) and voice
                        // works either way, so launch never waits on it.
                        if #available(macOS 26.0, *) {
                            Task.detached { await VoiceAssetReadiness.reserveAssets() }
                        }
                    }

                    // Route saved global chords into the owning coordinator's
                    // live rebind (Settings → Hotkeys). Coordinators are stable
                    // class instances for the app's lifetime, captured here
                    // once they all exist.
                    let capture = voiceCapture
                    let dictating = dictation
                    let rewriting = rewrite
                    let clips = clipsKey
                    hotKeys.applyGlobal = { action, chord in
                        switch action {
                        case .pushToTalk:
                            capture?.rebindHotKey(keyCode: chord.keyCode, modifiers: chord.carbonModifiers)
                        case .dictation:
                            dictating?.rebindHotKey(keyCode: chord.keyCode, modifiers: chord.carbonModifiers)
                        case .rewrite:
                            if #available(macOS 26.0, *) {
                                rewriting?.rebindHotKey(keyCode: chord.keyCode, modifiers: chord.carbonModifiers)
                            } else {
                                nil
                            }
                        case .clips:
                            clips?.rebind(keyCode: chord.keyCode, modifiers: chord.carbonModifiers)
                        default:
                            nil
                        }
                    }
                }
        }
        .modelContainer(container)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Toggle Hover Panel") { hoverPanel?.toggle() }
                    .keyboardShortcut(hotKeys.shortcut(for: .hover))
                // The strip is always on screen (`show()` at launch), so the
                // notch chord toggles the PIN, not visibility — hiding it
                // outright would leave no way back to the ambient notch.
                Button("Toggle Notch") { notch?.togglePinned() }
                    .keyboardShortcut(hotKeys.shortcut(for: .notch))
                // Clips is a GLOBAL (Carbon) chord — this menu item only makes
                // it discoverable, so it mirrors whatever the user has bound.
                Button("Open Clips") { notch?.openPinned(on: NotchTabModel.clipsHotKeyTab) }
                    .keyboardShortcut(hotKeys.shortcut(for: .clips))
            }
        }
    }
}
