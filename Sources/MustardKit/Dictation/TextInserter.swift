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
public struct TextInserter {
    public var stillFocused: (FocusedTextTarget) -> Bool
    public var directInsert: (FocusedTextTarget, String) -> Bool
    public var readPasteboard: () -> PasteboardSnapshot
    public var writeTranscript: (String) -> Int
    public var currentChangeCount: () -> Int
    public var restorePasteboard: (PasteboardSnapshot) -> Void
    public var sendPaste: (pid_t) -> Bool
    /// Gives the target app time to process ⌘V before restoration.
    public var settle: () async -> Void
    /// Delivery check: true = the text is present, false = readable and
    /// absent, nil = unreadable, so unknowable. The two insertion paths hold
    /// this to different bars — see `insert`.
    public var verifyInserted: (FocusedTextTarget, String) -> Bool?

    public init(
        stillFocused: @escaping (FocusedTextTarget) -> Bool,
        directInsert: @escaping (FocusedTextTarget, String) -> Bool,
        readPasteboard: @escaping () -> PasteboardSnapshot,
        writeTranscript: @escaping (String) -> Int,
        currentChangeCount: @escaping () -> Int,
        restorePasteboard: @escaping (PasteboardSnapshot) -> Void,
        sendPaste: @escaping (pid_t) -> Bool,
        settle: @escaping () async -> Void,
        verifyInserted: @escaping (FocusedTextTarget, String) -> Bool?
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
            sendPaste: { pid in
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
            },
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
