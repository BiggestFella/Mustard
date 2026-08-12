import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The notch surface (spec §6a): a black, notch-hugging panel anchored to
/// whichever screen is active (external monitor preferred — see
/// `NotchScreenPicker`). Idle: thin strip rotating focus → waiting count.
/// Hover (or a click to pin) expands it into the tabbed shell — search
/// header, banner slot, tab pills, the active tab's body, quick capture.
/// Intentionally dark — it extends the physical notch — unlike the rest of
/// the app.
@MainActor
public final class NotchController {
    private var panel: NSPanel?
    private let makeContent: (_ controller: NotchController) -> AnyView

    /// Tested state machine (`NotchPinState`); the controller only feeds it
    /// events and applies the resulting geometry.
    private var pinState = NotchPinState()
    private var graceTimer: Timer?
    private var clickOutsideMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    /// The active tab drives the expanded frame (`NotchPanelMetrics`).
    public private(set) var activeTab: NotchTab = .today
    /// A hotkey's requested landing tab, consumed once by the shell's
    /// `.onAppear` (see `consumePendingTab`).
    public private(set) var pendingTab: NotchTab?

    /// Set by the shell view so pin/tab changes re-render it.
    public var onStateChange: (() -> Void)?

    public init(content: @escaping (_ controller: NotchController) -> AnyView) {
        self.makeContent = content
    }

    public var isVisible: Bool { panel?.isVisible ?? false }
    public var isPinned: Bool { pinState.isPinned }
    public var isExpanded: Bool { pinState.isExpanded }

    private var screen: NSScreen? {
        let screens = NSScreen.screens
        let descriptors = screens.enumerated().map { index, screen in
            NotchScreenDescriptor(
                id: index,
                hasNotch: screen.safeAreaInsets.top > 0,
                isMain: screen == NSScreen.main
            )
        }
        guard let chosen = NotchScreenPicker.choose(from: descriptors),
              let index = chosen.id as? Int else { return NSScreen.main }
        return screens[index]
    }

    /// Idle strip geometry: hug the physical notch with a small lip below;
    /// sensible fallback for displays without a notch.
    private func idleFrame(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let notchHeight = screen.safeAreaInsets.top
        let width: CGFloat
        let height: CGFloat
        if notchHeight > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            width = frame.width - left.width - right.width + 24
            height = notchHeight + 20
        } else {
            width = 230
            height = 30
        }
        return NSRect(
            x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height
        )
    }

    /// Expanded geometry is per-tab (grid tabs are taller than list tabs).
    private func expandedFrame(on screen: NSScreen) -> NSRect {
        let size = NotchPanelMetrics.expandedSize(for: activeTab)
        let frame = screen.frame
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// ⌘⇧N: open the panel *pinned*, or hide it (dropping the pin) if visible.
    public func toggle() {
        if let panel, panel.isVisible {
            graceTimer?.invalidate()
            graceTimer = nil
            // Hide FIRST: unpinning shrinks the frame with an animation, and
            // animating a panel the user is about to stop seeing just blocks
            // for the duration. Off-screen, the same setFrame is instant.
            panel.orderOut(nil)
            // A hidden panel never receives a hover-exit, so record the pointer
            // as outside before unpinning — otherwise a peek would survive the
            // hide and the panel would re-open stuck expanded.
            pinState.hoverChanged(isInside: false, now: .now)
            unpin()
            return
        }
        show()
        pin()
    }

    public func show() {
        guard let screen else { return }
        if panel == nil {
            let panel = NSPanel(
                contentRect: idleFrame(on: screen),
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = false
            panel.contentView = NSHostingView(rootView: makeContent(self))
            self.panel = panel
            // Follow display connect/disconnect: previously the panel only
            // re-resolved its screen on the next show()/hover, so unplugging an
            // external monitor left it stranded off-screen.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyFrame() }
            }
        }
        applyFrame()
        panel?.orderFrontRegardless()
    }

    // MARK: - Events from the shell view

    public func hoverChanged(_ isInside: Bool) {
        pinState.hoverChanged(isInside: isInside, now: .now)
        applyFrame()
        if !isInside { armGraceTimer() }
        onStateChange?()
    }

    public func pin() {
        pinState.pin()
        applyFrame()
        installClickOutsideMonitor()
        onStateChange?()
    }

    /// Esc / click-away / hide. Keeps a hover peek only while the pointer is in.
    public func unpin() {
        pinState.unpin()
        applyFrame()
        removeClickOutsideMonitor()
        onStateChange?()
    }

    public func select(tab: NotchTab) {
        activeTab = tab
        applyFrame()
        onStateChange?()
    }

    /// ⌘⇧N / ⌃⌥V entry: open pinned on a specific tab.
    public func openPinned(on tab: NotchTab) {
        // Set the tab before showing so the panel opens straight at that tab's
        // size rather than resizing a frame later, and hand the shell a
        // one-shot request so its `.onAppear` doesn't bounce it to the default.
        activeTab = tab
        pendingTab = tab
        show()
        pin()
    }

    /// Read-and-clear: the shell asks once per expansion. Nil means "no
    /// request" — a plain hover-expand lands on the default tab as usual.
    public func consumePendingTab() -> NotchTab? {
        defer { pendingTab = nil }
        return pendingTab
    }

    /// Release the AppKit hooks (global click monitor, screen-parameters
    /// observer, grace timer). The controller is app-lifetime, so this is for
    /// teardown/tests: a `deinit` cannot touch this main-actor-isolated state
    /// without hopping actors, which is worse than one explicit call.
    public func shutdown() {
        graceTimer?.invalidate()
        graceTimer = nil
        removeClickOutsideMonitor()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        onStateChange = nil
        panel?.orderOut(nil)
    }

    // MARK: - Internals

    private func armGraceTimer() {
        graceTimer?.invalidate()
        graceTimer = Timer.scheduledTimer(
            withTimeInterval: NotchPinState.collapseGrace + 0.05, repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pinState.collapseIfDue(now: .now)
                self.applyFrame()
                self.onStateChange?()
            }
        }
    }

    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pinState.isPinned else { return }
                // A global monitor only fires for clicks in OTHER apps/windows;
                // clicks inside our own panel never reach it — which is exactly
                // "click away to unpin".
                self.unpin()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor { NSEvent.removeMonitor(clickOutsideMonitor) }
        clickOutsideMonitor = nil
    }

    private func applyFrame() {
        guard let panel, let screen else { return }
        let expanded = pinState.isExpanded
        panel.hasShadow = expanded
        panel.setFrame(
            expanded ? expandedFrame(on: screen) : idleFrame(on: screen),
            display: true, animate: true)
    }
}

public struct NotchView: View {
    @Environment(\.modelContext) private var context
    @Environment(AgentService.self) private var agent
    @Environment(NotchNavigation.self) private var nav
    /// Optional: absent in previews/tests that don't wire the recorder.
    @Environment(MeetingCaptureCoordinator.self) private var meetingRecorder: MeetingCaptureCoordinator?
    /// Optional: not yet injected app-wide (Task 13); drag-in is a no-op
    /// until it is, rather than crashing the notch.
    @Environment(ClipboardServices.self) private var services: ClipboardServices?
    @Query private var tasks: [MustardTask]
    @Query(sort: \Recommendation.createdAt, order: .reverse) private var recommendations: [Recommendation]
    @Query(sort: \CalendarEvent.start) private var events: [CalendarEvent]
    @Query(sort: \ClipCollection.sortOrder) private var collections: [ClipCollection]
    @Query private var clips: [ClipItem]
    @State private var hovering = false
    /// Bumped from the controller's `onStateChange` so pin/tab changes (which
    /// live outside SwiftUI) re-evaluate this view.
    @State private var stateVersion = 0
    @State private var captureText = ""
    @State private var searchQuery = ""
    @State private var showPinnedOnly = false
    @State private var activeTab: NotchTab = .today
    @FocusState private var captureFocused: Bool
    /// Handle for pin/tab/hover events; the controller outlives the view.
    let controller: NotchController?

    public init(controller: NotchController? = nil) {
        self.controller = controller
    }

    /// The controller's `NotchPinState` is the single source of truth for
    /// expansion (hover peek, pin, collapse grace). The local `hovering` flag
    /// is only the fallback for previews/tests with no controller — reading it
    /// as an OR left the view expanded after a hide-while-hovering, because the
    /// hidden panel never delivers the hover-exit.
    private var expanded: Bool {
        _ = stateVersion  // read so SwiftUI tracks controller-driven changes
        guard let controller else { return hovering }
        return controller.isExpanded
    }

    private var focusTask: MustardTask? {
        let todays = DayPlanner.tasksForDay(tasks, day: .now).filter { $0.stage.isOpen && !$0.isBlocked }
        return tasks.first { $0.stage == .inProgress && !$0.isBlocked } ?? todays.first
    }

    private var pending: [Recommendation] {
        RecommendationQueue.pending(recommendations, now: .now)
    }

    /// What the notch is waiting on you for: drives the idle ticker and the
    /// Agent pill's count.
    private var waitingCount: Int {
        // Both agent attention stages count — a Needs You question waits on you just like a
        // Needs Review output (mirrors PersonalBoard.waitingCount / AgentInbox).
        pending.count + AgentInbox.attentionTaskCount(tasks)
    }

    private var nextMeeting: CalendarEvent? {
        events.first { $0.start > .now && Calendar.current.isDateInToday($0.start) }
    }

    private func nextMeetingLabel() -> String? {
        guard let m = nextMeeting else { return nil }
        return "\(m.title) · \(m.start.formatted(date: .omitted, time: .shortened))"
    }

    /// A live recording keeps the Meetings pill dotted and makes it the tab the
    /// panel opens on (`NotchTabModel.defaultTab`).
    private var recordingActive: Bool {
        switch meetingRecorder?.state {
        case .recording, .preparing, .paused: return true
        default: return false
        }
    }

    private var tabs: [NotchTab] {
        NotchTabModel.tabs(collectionNames: collections.map(\.name))
    }

    /// Pill badges. `nil` means "no number" — a zero would be noise.
    private func count(for tab: NotchTab) -> Int? {
        switch tab {
        case .today:
            let progress = DayPlanner.dayProgress(tasks, day: .now)
            let open = progress.total - progress.done
            return open > 0 ? open : nil
        case .agent:
            return waitingCount > 0 ? waitingCount : nil
        case .meetings:
            return nil
        case .clips:
            let loose = clips.filter { !$0.pinnedToShelf && $0.collection == nil }.count
            return loose > 0 ? loose : nil
        case .shelf:
            let kept = clips.filter(\.pinnedToShelf).count
            return kept > 0 ? kept : nil
        case .collection(let name):
            let filed = collections.first { $0.name == name }?.items?.count ?? 0
            return filed > 0 ? filed : nil
        }
    }

    /// The ONE way the active tab changes: the panel resizes per tab
    /// (`NotchPanelMetrics`), so the controller must hear about every switch.
    private func switchTo(_ tab: NotchTab) {
        activeTab = tab
        controller?.select(tab: tab)
    }

    public var body: some View {
        VStack(spacing: 0) {
            shape
            Spacer(minLength: 0)
        }
        .onHover { isIn in
            withAnimation(.snappy(duration: 0.16)) { hovering = isIn }
            controller?.hoverChanged(isIn)
        }
        .onAppear {
            controller?.onStateChange = {
                withAnimation(.snappy(duration: 0.16)) { stateVersion &+= 1 }
            }
        }
        // Drag-in lands on the Shelf regardless of which face is showing (idle
        // strip or expanded panel) — both render inside this VStack. Nothing
        // can store the drop until ClipboardServices is injected, so decline
        // it rather than silently swallowing the gesture.
        .onDrop(of: [.fileURL, .image, .utf8PlainText], isTargeted: nil) { providers in
            guard let services else { return false }
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in services.store.addShelfDrop(fileURL: url) }
                    }
                } else if provider.canLoadObject(ofClass: NSImage.self) {
                    _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                        guard let data = (image as? NSImage)?.tiffRepresentation else { return }
                        Task { @MainActor in services.store.addShelfDrop(imageData: data) }
                    }
                } else {
                    _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                        guard let text = string as? String else { return }
                        Task { @MainActor in services.store.addShelfDrop(text: text) }
                    }
                }
            }
            return true
        }
    }

    private func capture() {
        let trimmed = captureText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { captureFocused = true; return }
        context.insert(MustardTask(title: trimmed))
        captureText = ""
        captureFocused = true
    }

    private var shape: some View {
        Group {
            if expanded { expandedContent } else { idleContent }
        }
        .background(
            UnevenRoundedRectangle(
                bottomLeadingRadius: expanded ? 18 : 10,
                bottomTrailingRadius: expanded ? 18 : 10
            )
            .fill(.black)
        )
    }

    private var idleContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 4)) { timeline in
                // Prefer a starred focus task's title over the plain in-progress/next
                // fallback; when the agent is executing its work still wins the slot.
                let idleFocus = RitualPlanner.focusTitle(tasks, day: .now) ?? focusTask?.title
                // Same gate as the Today banner — read the ritual keys straight from
                // UserDefaults (0 == never → nil) since the notch has no @AppStorage.
                let last = UserDefaults.standard.double(forKey: RitualPrompt.lastPlannedKey)
                let dismissed = UserDefaults.standard.double(forKey: RitualPrompt.dismissedKey)
                let planPrompt = RitualPrompt.shouldOffer(
                    lastPlannedDay: last > 0 ? Date(timeIntervalSince1970: last) : nil,
                    dismissedDay: dismissed > 0 ? Date(timeIntervalSince1970: dismissed) : nil,
                    now: .now)
                let items = NotchTicker.idleItems(
                    focusTitle: agent.isExecuting ? (agent.currentTitle ?? "Agent working…") : idleFocus,
                    waitingCount: waitingCount,
                    nextEvent: nextMeetingLabel(),
                    planPrompt: planPrompt
                )
                let tick = Int(timeline.date.timeIntervalSinceReferenceDate / 4)
                HStack(spacing: 5) {
                    // Persistent recording indicator (meeting recorder spec):
                    // visible for the whole recording, even on the idle strip.
                    if case .recording = meetingRecorder?.state {
                        Circle().fill(Color(hex: "#FF5F57")).frame(width: 5, height: 5)
                    }
                    if agent.isExecuting {
                        Circle().fill(Color(hex: "#7F77DD")).frame(width: 5, height: 5)
                    } else if waitingCount > 0 {
                        Circle().fill(Color(hex: "#5DCAA5")).frame(width: 5, height: 5)
                    }
                    Text(NotchTicker.item(items, tick: tick))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Click the strip to pin the panel open (hover alone only peeks).
        .contentShape(Rectangle())
        .onTapGesture { controller?.pin() }
    }

    /// The expanded panel is a shell: header (search + pins + open-app), a
    /// banner slot, the tab pills, the active tab's body, and the capture bar.
    /// The tabs own their own content; the shell owns none of it.
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: 30)
            headerRow
            // Banner slot: the meeting suggestion is visible from any tab and
            // routes through the same consent path as the manual button.
            MeetingStartPromptView()
            tabPills
            tabContent
            Spacer(minLength: 0)
            captureBar
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // A hotkey open (⌘⇧N / ⌃⌥V) names its tab; anything else — a plain
            // hover-expand — lands on the default tab.
            switchTo(
                controller?.consumePendingTab()
                    ?? NotchTabModel.defaultTab(recordingActive: recordingActive))
        }
        .onChange(of: tabs) { _, current in
            // A deleted collection must not strand the shell on a dead tab;
            // Today is always present and is where the panel normally lands.
            if !current.contains(activeTab) { switchTo(.today) }
        }
        .onExitCommand { controller?.unpin() }
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                TextField("Search", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            Spacer()
            Button {
                showPinnedOnly.toggle()
            } label: {
                Image(systemName: showPinnedOnly ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(showPinnedOnly ? 0.9 : 0.55))
            }
            .buttonStyle(.plain)
            .help("Pinned only")
            Button {
                if controller?.isPinned == true { controller?.unpin() } else { controller?.pin() }
            } label: {
                Image(systemName: controller?.isPinned == true ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(controller?.isPinned == true ? 0.9 : 0.55))
            }
            .buttonStyle(.plain)
            .help("Keep the panel open")
            Button {
                openMainApp()
            } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Open Mustard")
        }
    }

    private func openMainApp() {
        nav.openAgentConsole = false
        nav.pendingTask = nil
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    private var tabPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs, id: \.self) { tab in
                    let selected = tab == activeTab
                    Button {
                        switchTo(tab)
                    } label: {
                        HStack(spacing: 4) {
                            if tab == .meetings && recordingActive {
                                Circle().fill(Color(hex: "#FF5F57")).frame(width: 5, height: 5)
                            }
                            Text(tab.title)
                            if let count = count(for: tab) {
                                Text("\(count)").opacity(0.5)
                            }
                        }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(selected ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 4)
                        .background(
                            selected
                                ? AnyShapeStyle(Color.white)
                                : AnyShapeStyle(Color.white.opacity(0.08)),
                            in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                NotchNewCollectionPill()
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .today: NotchTodayTab()
        case .agent: NotchAgentTab()
        case .meetings: NotchMeetingsTab()
        case .clips: NotchClipsTab(searchQuery: searchQuery, pinnedOnly: showPinnedOnly)
        case .shelf: NotchShelfTab(searchQuery: searchQuery)
        case .collection(let name): NotchCollectionTab(name: name, searchQuery: searchQuery)
        }
    }

    private var captureBar: some View {
        HStack(spacing: 8) {
            TextField("Add to inbox…", text: $captureText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .focused($captureFocused)
                .onSubmit(capture)
            Button("Add", action: capture)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color(hex: "#534AB7"), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.bottom, 12)
    }
}

/// The "+" pill that creates a custom collection. Stubbed until the
/// collections task lands — the shell already reserves its slot at the end of
/// the pill row so the layout doesn't shift when it arrives.
struct NotchNewCollectionPill: View {
    var body: some View { EmptyView() }
}
