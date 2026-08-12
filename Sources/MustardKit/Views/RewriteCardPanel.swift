#if os(macOS)
import AppKit
import SwiftUI

/// Hosts the review card. Non-activating and key-capable at the same time:
/// the panel must take keystrokes (return / esc / 1–4) WITHOUT bringing
/// Mustard forward, because activating the app is what dragged the whole
/// window stack forward in voice bug #7 — and here it would also disturb the
/// very selection being rewritten.
///
/// `NSApp.activate` must never be called on this path.
public final class RewriteCardPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// Required: a borderless panel returns false by default, and the card
    /// would never receive return / esc.
    public override var canBecomeKey: Bool { true }
    /// Must stay false — becoming main is what activates the application.
    public override var canBecomeMain: Bool { false }
}
#endif
