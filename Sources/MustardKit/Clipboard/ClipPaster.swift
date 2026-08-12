import Foundation

/// Clip → frontmost app. Copy is always the first half of paste, so a failed
/// paste still leaves the clip on the pasteboard (worst case: the user ⌘V's
/// it themselves). Every edge is an injected closure — tests never touch the
/// pasteboard, the workspace, or key events.
@MainActor
public final class ClipPaster {
    /// Write text, return the resulting changeCount.
    private let writeToPasteboard: (String) -> Int
    /// Write image bytes, return the resulting changeCount.
    private let writeImageToPasteboard: (Data) -> Int
    private let frontmostPID: () -> pid_t?
    private let sendPaste: (pid_t) -> Bool
    /// Tell the monitor this change is ours (`ClipboardMonitor.expectOwnWrite`),
    /// so copying out of the notch doesn't re-enter history.
    private let markOwnWrite: (Int) -> Void

    public init(
        writeToPasteboard: @escaping (String) -> Int,
        writeImageToPasteboard: @escaping (Data) -> Int,
        frontmostPID: @escaping () -> pid_t?,
        sendPaste: @escaping (pid_t) -> Bool,
        markOwnWrite: @escaping (Int) -> Void
    ) {
        self.writeToPasteboard = writeToPasteboard
        self.writeImageToPasteboard = writeImageToPasteboard
        self.frontmostPID = frontmostPID
        self.sendPaste = sendPaste
        self.markOwnWrite = markOwnWrite
    }

    /// Copy text (the click action).
    ///
    /// Empty is refused on purpose: an image clip's `payload` is empty, and
    /// writing it would silently wipe whatever the user had on the clipboard.
    /// The guard lives here, not only at the call sites, because every clip
    /// grid (Clips, Shelf, collections) copies straight from `payload`.
    public func copy(text: String) {
        guard !text.isEmpty else { return }
        markOwnWrite(writeToPasteboard(text))
    }

    /// Copy an image clip's bytes (PNG/TIFF/JPEG — whatever was captured).
    public func copy(imageData: Data) {
        guard !imageData.isEmpty else { return }
        markOwnWrite(writeImageToPasteboard(imageData))
    }

    /// Copy + ⌘V into the frontmost app (Return / double-click). `false` means
    /// the keystroke was never posted — the text is still on the pasteboard.
    public func paste(text: String) async -> Bool {
        guard !text.isEmpty else { return false }
        copy(text: text)
        guard let pid = frontmostPID() else { return false }
        // ⌘V to ourselves would type into the notch's own capture field
        // instead of the app the user was working in.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return false }
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
            writeImageToPasteboard: { data in
                let board = NSPasteboard.general
                board.clearContents()
                // Clips hold PNG/TIFF originals and JPEG thumbnails. Writing
                // the decoded NSImage hands every receiver a representation it
                // understands; only if the bytes won't decode do we fall back
                // to declaring them PNG.
                if let image = NSImage(data: data) {
                    _ = board.writeObjects([image])
                } else {
                    board.setData(data, forType: .png)
                }
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
