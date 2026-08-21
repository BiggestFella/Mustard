import Foundation

/// How an insertion attempt ended (Dictation Task 3, BAK-289). `recoverable`
/// means nothing was inserted and the transcript must be preserved for the
/// user (the coordinator routes it to safe recovery).
public enum TextInsertionOutcome: Equatable, Sendable {
    case insertedDirectly
    case insertedByPaste
    case recoverable(String)
}

/// Places dictated text into the snapshotted target: secure targets are
/// refused outright, focus is revalidated, direct AX insertion is tried
/// first, and the pasteboard fallback is lossless (capture → write → ⌘V to
/// the target PID → restore only while the clipboard still holds our write).
/// Every edge is an injected closure; tests never touch AX, the pasteboard,
/// or key events.
///
/// **Every seam is `@MainActor`, and so is `insert` — that is a crash fix, not
/// tidiness.** All nine edges reach AppKit, the pasteboard, or Accessibility,
/// and an AX write to a field inside *Mustard itself* is serviced in-process:
/// `AXUIElementSetAttributeValue` → `NSTextView.replaceCharactersInRange` →
/// `NSTextInputContext` → HIToolbox, which calls `dispatch_assert_queue(main)`
/// and `SIGTRAP`s the whole app off the main thread. `insert` used to be a
/// plain nonisolated `async` method, so Swift ran its body — and every
/// *synchronous* seam it calls, whose inferred isolation is erased by a
/// nonisolated function type — on a cooperative thread. Dictating into
/// Mustard's own notes editor crashed it on 2026-08-21 for exactly that
/// reason. Keep the isolation annotations: they are what makes the seams
/// unrepresentable off the main actor.
///
/// The trade-off is deliberate: an AX call into a *hung* remote application now
/// occupies the main thread until the AX messaging timeout instead of a
/// cooperative one. Dispatching only in-process writes to the main actor would
/// keep that off it, but "is this element ours?" is not knowable from the PID
/// alone (an out-of-process write can still be serviced in-process through a
/// helper), so the safe rule is the blunt one. `settle`'s 350 ms is an `await`,
/// which suspends the main actor rather than blocking the main thread.
public struct TextInserter {
    public var stillFocused: @MainActor (FocusedTextTarget) -> Bool
    public var directInsert: @MainActor (FocusedTextTarget, String) -> Bool
    public var readPasteboard: @MainActor () -> PasteboardSnapshot
    public var writeTranscript: @MainActor (String) -> Int
    public var currentChangeCount: @MainActor () -> Int
    public var restorePasteboard: @MainActor (PasteboardSnapshot) -> Void
    public var sendPaste: @MainActor (pid_t) -> Bool
    /// Gives the target app time to process ⌘V before restoration. Awaited on
    /// the main actor, which suspends rather than blocks the main thread.
    public var settle: @MainActor () async -> Void
    /// Delivery check: true = the text is present, false = readable and
    /// absent, nil = unreadable, so unknowable. The two insertion paths hold
    /// this to different bars — see `insert`.
    public var verifyInserted: @MainActor (FocusedTextTarget, String) -> Bool?

    public init(
        stillFocused: @escaping @MainActor (FocusedTextTarget) -> Bool,
        directInsert: @escaping @MainActor (FocusedTextTarget, String) -> Bool,
        readPasteboard: @escaping @MainActor () -> PasteboardSnapshot,
        writeTranscript: @escaping @MainActor (String) -> Int,
        currentChangeCount: @escaping @MainActor () -> Int,
        restorePasteboard: @escaping @MainActor (PasteboardSnapshot) -> Void,
        sendPaste: @escaping @MainActor (pid_t) -> Bool,
        settle: @escaping @MainActor () async -> Void,
        verifyInserted: @escaping @MainActor (FocusedTextTarget, String) -> Bool?
    ) {
        self.stillFocused = stillFocused
        self.directInsert = directInsert
        self.readPasteboard = readPasteboard
        self.writeTranscript = writeTranscript
        self.currentChangeCount = currentChangeCount
        self.restorePasteboard = restorePasteboard
        self.sendPaste = sendPaste
        self.settle = settle
        self.verifyInserted = verifyInserted
    }

    /// `@MainActor` because the seams below are AppKit/AX calls; see the type's
    /// note. A nonisolated `async` body here put them on a cooperative thread.
    @MainActor
    public func insert(_ text: String, into target: FocusedTextTarget) async -> TextInsertionOutcome {
        guard !target.isSecure else {
            return .recoverable("This looks like a password field — dictation is never inserted there.")
        }
        guard !text.isEmpty else {
            return .recoverable("Nothing to insert.")
        }
        guard stillFocused(target) else {
            return .recoverable("The text field lost focus before the transcript was ready.")
        }
        // A successful AX return code is not evidence: Chromium-based apps
        // (Slack, Electron editors) report kAXSelectedText as settable and
        // return .success while discarding the write. Only a POSITIVELY
        // confirmed direct write is accepted — anything else falls through to
        // the paste path, which is the whole reason that path exists. Claiming
        // "Inserted" here on an unconfirmed write silently loses the words.
        if directInsert(target, text), verifyInserted(target, text) == true {
            return .insertedDirectly
        }

        // Lossless paste fallback: capture → write → ⌘V → restore, but only
        // while the clipboard still holds our write — an external change wins.
        let snapshot = readPasteboard()
        let writeCount = writeTranscript(text)
        let pasted = sendPaste(target.applicationPID)
        if pasted { await settle() }
        // Last resort, so an unknowable value gets the benefit of the doubt:
        // posting CGEvents proves nothing about the target servicing them, but
        // claiming failure when it probably worked would be worse.
        let delivered = pasted && (verifyInserted(target, text) ?? true)
        if PasteboardSnapshot.shouldRestore(
            currentCount: currentChangeCount(), mustardWriteCount: writeCount) {
            restorePasteboard(snapshot)
        }
        return delivered
            ? .insertedByPaste
            : .recoverable("The app didn't accept the paste — the text is kept for you.")
    }
}

// MARK: - Live wiring (macOS only; exercised in the cross-app matrix)

#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics

/// Synthesizes ⌘V to a pid (virtual key 9 = "v", command flag on both the
/// down and the up event). Shared by dictation's paste fallback and the
/// notch's clip paste-back — requires the same Accessibility grant dictation
/// already needs; posting proves nothing about the target servicing it, so
/// callers treat `true` as "posted", not "delivered".
enum PasteKeystroke {
    static func send(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }
}

extension TextInserter {
    /// The production inserter: AX selected-text replacement first, then the
    /// ⌘V fallback via a synthesized key event posted to the target PID.
    @MainActor
    public static func live(reader: AccessibilityFocusReader = .live()) -> TextInserter {
        TextInserter(
            stillFocused: { reader.isStillFocused($0) },
            directInsert: { _, text in
                // Re-fetch the focused element (identity was just revalidated)
                // and try the writable selected-text attribute.
                let systemWide = AXUIElementCreateSystemWide()
                var focusedRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                        systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                      let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
                    return false
                }
                let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(
                        element, kAXSelectedTextAttribute as CFString, &settable) == .success,
                      settable.boolValue else {
                    return false
                }
                return AXUIElementSetAttributeValue(
                    element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
            },
            readPasteboard: { PasteboardSnapshot.capture(from: .general) },
            writeTranscript: { PasteboardSnapshot.write($0, to: .general) },
            currentChangeCount: { NSPasteboard.general.changeCount },
            restorePasteboard: { $0.restore(to: .general) },
            sendPaste: { pid in PasteKeystroke.send(to: pid) },
            settle: {
                // Give the target app time to service ⌘V before restoration.
                try? await Task.sleep(for: .milliseconds(350))
            },
            verifyInserted: { _, text in
                // Three-state by design; each call site decides what to do with
                // nil (unreadable web areas).
                reader.focusedValueContains(text)
            })
    }
}
#endif
