import AppKit
import SwiftUI

/// Selection, queue order and key routing for the Agent console.
///
/// This is a reference type rather than the view's `@State` on purpose: the
/// triage key monitor is an escaping AppKit callback that must read and write
/// the *live* selection and the *live* queue, not the snapshot of the view
/// struct it was installed with. The console keeps `order` in sync on the same
/// change it already uses to re-select.
///
/// Every decision here is pure (`TriageShortcuts`); this owns only the AppKit
/// edges — the monitor's lifetime and the "is the user typing?" responder read.
@MainActor @Observable public final class TriageConsoleState {
    public var selected: Recommendation?
    public var sheetTask: MustardTask?
    /// The master list in visible order — what next/previous walk.
    @ObservationIgnored public var order: [Recommendation] = []
    @ObservationIgnored private var monitor: Any?

    public init() {}

    /// Install the console's local key monitor. `chords` is read per press so a
    /// rebind in Settings takes effect without reinstalling.
    public func installMonitor(
        chords: @escaping () -> [HotKeyAction: HotKeyChord],
        perform: @escaping (TriageCommand) -> Void
    ) {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let command = self.command(for: event, chords: chords()) else { return event }
            perform(command)
            return nil  // consumed — the key never reaches the responder chain
        }
    }

    public func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The triage command this press should fire, or nil to let the event through.
    private func command(for event: NSEvent, chords: [HotKeyAction: HotKeyChord]) -> TriageCommand? {
        // The notch, hover and quick-edit surfaces are panels with their own
        // keyboard behaviour — the console never speaks for them.
        if event.window is NSPanel { return nil }
        let modifiers = HotKeyRecorderLogic.carbonModifiers(fromNSEventFlags: event.modifierFlags.rawValue)
        guard
            let command = TriageShortcuts.command(
                keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, chords: chords),
            TriageShortcuts.shouldHandle(
                command, isRepeat: event.isARepeat,
                isEditingText: Self.isEditingText(in: event.window),
                isModalPresented: sheetTask != nil)
        else { return nil }
        return command
    }

    /// True while a text field / editor holds focus — the draft editor, the
    /// comment field, the command bar, note search. SwiftUI text controls are
    /// backed by an `NSTextView` field editor, so one check covers them all.
    static func isEditingText(in window: NSWindow?) -> Bool {
        guard let responder = (window ?? NSApp.keyWindow)?.firstResponder else { return false }
        if let text = responder as? NSText { return text.isEditable }
        return responder is NSTextView
    }
}
