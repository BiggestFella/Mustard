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

    /// Throw the captured task away entirely. Close KEEPS the task (capture
    /// is never destructive by default), but an accidental trigger — a
    /// fumbled hotkey, two stray words — needs a way out that does not leave
    /// litter in the Inbox for you to clean up later.
    public func discard() {
        guard !isClosed else { return }
        context.delete(task)
        try? context.save()
        close()
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

/// Owns the one visible quick-edit card (Capture Task 4): a floating,
/// key-accepting but NON-activating panel below the chosen notch display —
/// capturing from another app must never pull Mustard's window forward.
/// A newer capture replaces the visible card; `presentsPanel: false` keeps
/// tests panel-free.
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
        // The card needs KEY focus (you type into it) but must NOT activate
        // Mustard — a capture taken from another app should never yank the
        // main window forward. `.nonactivatingPanel` grants exactly that: the
        // panel becomes key while the owning app stays in the background.
        // Only "Open Fully" activates, because that is what it is for.
        let panel = KeyableNonactivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
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
        installPanelContent(VoiceTaskQuickEditView(state: state), in: panel)
        if let screen = NotchScreenPicker.currentScreen() {
            // Below the notch/menu bar of the chosen display, centred.
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.maxY - 12))
        }
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
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
}

/// A floating panel that accepts keyboard input WITHOUT activating its app.
/// `NSPanel` declines key status for a non-activating style by default, so
/// this override is what lets you type into the card while Mustard stays in
/// the background and your current app keeps its window frontmost.
private final class KeyableNonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

#endif
