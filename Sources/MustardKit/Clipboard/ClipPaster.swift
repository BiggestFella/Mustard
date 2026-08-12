import Foundation

/// Clip → frontmost app. Copy is always the first half of paste, so a failed
/// paste still leaves the clip on the pasteboard (worst case: the user ⌘V's
/// it themselves). Every edge is an injected closure — tests never touch the
/// pasteboard, the workspace, or key events.
@MainActor
public final class ClipPaster {
    /// Write text, return the resulting changeCount.
    private let writeToPasteboard: (String) -> Int
    private let frontmostPID: () -> pid_t?
    private let sendPaste: (pid_t) -> Bool
    /// Tell the monitor this change is ours (`ClipboardMonitor.expectOwnWrite`),
    /// so copying out of the notch doesn't re-enter history.
    private let markOwnWrite: (Int) -> Void

    public init(
        writeToPasteboard: @escaping (String) -> Int,
        frontmostPID: @escaping () -> pid_t?,
        sendPaste: @escaping (pid_t) -> Bool,
        markOwnWrite: @escaping (Int) -> Void
    ) {
        self.writeToPasteboard = writeToPasteboard
        self.frontmostPID = frontmostPID
        self.sendPaste = sendPaste
        self.markOwnWrite = markOwnWrite
    }

    /// Copy only (the click action).
    public func copy(text: String) {
        markOwnWrite(writeToPasteboard(text))
    }

    /// Copy + ⌘V into the frontmost app (Return / double-click). `false` means
    /// the keystroke was never posted — the text is still on the pasteboard.
    public func paste(text: String) async -> Bool {
        copy(text: text)
        guard let pid = frontmostPID() else { return false }
        return sendPaste(pid)
    }
}

#if os(macOS)
import AppKit

extension ClipPaster {
    /// The production paster: general pasteboard + the frontmost app's pid +
    /// dictation's ⌘V synthesizer (`PasteKeystroke`).
    public static func live(monitor: ClipboardMonitor) -> ClipPaster {
        ClipPaster(
            writeToPasteboard: { text in
                let board = NSPasteboard.general
                board.clearContents()
                board.setString(text, forType: .string)
                return board.changeCount
            },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            sendPaste: { pid in PasteKeystroke.send(to: pid) },
            markOwnWrite: { [weak monitor] count in
                monitor?.expectOwnWrite(changeCount: count)
            })
    }
}
#endif
