#if os(macOS)
import AppKit
import SwiftUI
import SwiftData
import Observation

/// What the quick editor does with a key or dismissal event (Capture Task 4).
public enum QuickEditEvent: Equatable, Sendable {
    case plainReturn(in: VoiceTaskField?)
    case commandReturn
    case escape
    case outsideClick
}

public enum QuickEditAction: Equatable, Sendable {
    case insertNewline
    case commit
    case dismiss
    case none
}

/// The quick-edit card's state (Capture Task 4, BAK-284): the editable draft,
/// per-field revision counters (the coordinator's merge gate), and the
/// commit/close decisions. Conforms to `VoiceTaskQuickEditing` so the capture
/// coordinator can snapshot revisions and land merged drafts.
@MainActor
@Observable
public final class VoiceTaskQuickEditState: VoiceTaskQuickEditing {
    public let task: MustardTask
    public var draft: VoiceTaskDraft
    public private(set) var revisions = VoiceTaskFieldRevisions()
    public private(set) var isClosed = false
    /// Installed by the capture coordinator when a draft fails — the card
    /// shows Draft Again while it is open (spec: retryable from the card).
    public var retryDraft: (() -> Void)?
    /// Area names offered by the picker, fetched once — the panel-hosted view
    /// has no SwiftData environment, so `@Query` is not an option there.
    public let areaNames: [String]

    private let context: ModelContext
    private let navigation: NotchNavigation?
    /// Set by the controller: dismisses the panel when the state closes.
    var onClose: (() -> Void)?

    public init(task: MustardTask, context: ModelContext, navigation: NotchNavigation? = nil) {
        self.task = task
        self.context = context
        self.navigation = navigation
        self.areaNames = ((try? context.fetch(FetchDescriptor<Area>())) ?? [])
            .map(\.name).sorted()
        self.draft = VoiceTaskDraft(
            title: task.title,
            notes: task.notes.isEmpty ? nil : task.notes,
            areaName: task.list?.area?.name,
            scheduledDate: task.scheduledAt,
            urls: task.links.compactMap { URL(string: $0.url) })
    }

    // MARK: - Decisions

    /// Key/dismissal → action, pure. Return inserts a newline only inside the
    /// multiline notes field; ⌘Return and clicking outside commit; Escape
    /// dismisses (keeping the task — capture is never destructive).
    public static func action(for event: QuickEditEvent) -> QuickEditAction {
        switch event {
        case .commandReturn, .outsideClick:
            return .commit
        case .escape:
            return .dismiss
        case .plainReturn(let field):
            return field == .notes ? .insertNewline : .commit
        }
    }

    // MARK: - Editing

    public func userChanged(_ field: VoiceTaskField) {
        revisions.bump(field)
    }

    public func handle(_ event: QuickEditEvent) {
        switch Self.action(for: event) {
        case .commit: commit()
        case .dismiss: close()
        case .insertNewline, .none: break   // the focused text control handles it
        }
    }

    /// Apply the draft to the task, save, and dismiss.
    public func commit() {
        guard !isClosed else { return }
        task.title = VoiceTaskDrafting.validatedTitle(draft.title) ?? task.title
        task.notes = draft.notes ?? ""
        if task.scheduledAt != draft.scheduledDate {
            task.scheduledAt = draft.scheduledDate
            if draft.scheduledDate != nil { task.isTimed = false }
            PersonalBoard.normalizePlacement(task)
        }
        if let areaName = draft.areaName, !areaName.isEmpty {
            task.stampArea(named: areaName, in: context, overriding: true)
        }
        task.links = draft.urls.map {
            TaskLink(label: $0.host ?? $0.absoluteString, url: $0.absoluteString)
        }
        try? context.save()
        close()
    }

    /// Dismiss without applying pending edits. The task is kept as-is.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        onClose?()
    }

    /// Commit, then hand off to the full task drawer in the main window.
    public func openFully() {
        commit()
        navigation?.pendingTask = task
    }

    // MARK: - VoiceTaskQuickEditing (the coordinator's merge landing)

    /// The coordinator already wrote the task and gated the merge by revision;
    /// the state only reflects the merged fields in the UI.
    public func apply(_ merged: VoiceTaskDraft) {
        draft = merged
    }
}

/// Owns the one visible quick-edit card (Capture Task 4): an activating
/// floating panel below the chosen notch display. A newer capture replaces
/// the visible card. `presentsPanel: false` keeps tests panel-free.
@MainActor
public final class VoiceTaskQuickEditController {
    private let context: ModelContext
    private let navigation: NotchNavigation?
    private let presentsPanel: Bool
    private var panel: NSPanel?
    private var resignObserver: NSObjectProtocol?
    private var current: VoiceTaskQuickEditState?

    public init(context: ModelContext, navigation: NotchNavigation?, presentsPanel: Bool = true) {
        self.context = context
        self.navigation = navigation
        self.presentsPanel = presentsPanel
    }

    /// The capture coordinator's `presentEditor` seam. One visible card: a
    /// newer capture replaces the previous editor.
    public func present(for task: MustardTask) -> VoiceTaskQuickEditState {
        current?.close()
        let state = VoiceTaskQuickEditState(task: task, context: context, navigation: navigation)
        state.onClose = { [weak self, weak state] in
            guard let self, let state, self.current === state else { return }
            self.current = nil
            self.dismissPanel()
        }
        current = state
        if presentsPanel { showPanel(for: state) }
        return state
    }

    // MARK: - Panel

    private func showPanel(for state: VoiceTaskQuickEditState) {
        dismissPanel()
        // Activating (unlike the capture pill): the card is for typing, so it
        // must take key focus the moment it appears.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: VoiceTaskQuickEditView(state: state))
        if let screen = chooseScreen() {
            // Below the notch/menu bar of the chosen display, centred.
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - 12))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Clicking outside moves key focus away → commit. `close()` flips
        // `isClosed` before the panel resigns key, so programmatic dismissal
        // (Escape, replacement) never re-enters as a commit.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak state] _ in
            MainActor.assumeIsolated {
                state?.handle(.outsideClick)
            }
        }
    }

    private func dismissPanel() {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    /// The same display policy as the notch (`NotchScreenPicker`): follow the
    /// external monitor in use, else the built-in notch screen.
    private func chooseScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let descriptors = screens.enumerated().map { index, screen in
            NotchScreenDescriptor(
                id: AnyHashable(index),
                hasNotch: screen.safeAreaInsets.top > 0,
                isMain: screen == NSScreen.main)
        }
        guard let chosen = NotchScreenPicker.choose(from: descriptors),
              let index = chosen.id.base as? Int, screens.indices.contains(index) else {
            return NSScreen.main
        }
        return screens[index]
    }
}

// MARK: - Area stamping (shared by the capture coordinator and the editor)

extension MustardTask {
    /// Find-or-create the named area + its list and stamp this task — the
    /// sibling of `AgentService.ensureArea(_:named:)` for voice callers whose
    /// area name was already validated against the allowed list. Passing
    /// `overriding: true` re-stamps a task that already has a list (an
    /// explicit user pick in the editor); the default never overrides.
    @MainActor
    func stampArea(named areaName: String, in context: ModelContext, overriding: Bool = false) {
        guard overriding || list == nil else { return }
        guard list?.area?.name != areaName else { return }
        let area = (try? context.fetch(FetchDescriptor<Area>()))?.first { $0.name == areaName }
            ?? { let a = Area(name: areaName); context.insert(a); return a }()
        if let existing = (try? context.fetch(FetchDescriptor<TaskList>()))?.first(where: { $0.area?.name == areaName }) {
            list = existing
        } else {
            let created = TaskList(name: areaName, area: area)
            context.insert(created)
            list = created
        }
    }
}
#endif
