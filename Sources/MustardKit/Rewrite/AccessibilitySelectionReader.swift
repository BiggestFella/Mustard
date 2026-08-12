import Foundation

/// Reads the text a user has selected in the focused element. Every edge is an
/// injected closure, so the sequencing below is unit-tested without AX, the
/// pasteboard, or synthesized key events.
///
/// The ordering is a safety property, not an optimisation: rungs 1 and 2 are
/// passive reads, and rung 3 posts ⌘C key events into someone else's
/// application. Rung 3 is therefore last, and `RewriteGate.admits` must have
/// already refused secure fields before this runs at all.
public struct AccessibilitySelectionReader {
    /// Rung 1 — `kAXSelectedTextAttribute`. nil means unreadable.
    public var readSelectedTextAttribute: (FocusedTextTarget) -> String?
    /// Rung 2 — `kAXValueAttribute`, to be sliced by the target's range.
    public var readValueAttribute: (FocusedTextTarget) -> String?
    /// Rung 3 — synthesize ⌘C, read the pasteboard, restore it. nil means
    /// the application did not service the copy. Async because the real one has
    /// to wait for the target to service the keystroke, and blocking the main
    /// thread for that settle would freeze the pill mid-rewrite.
    public var copySelectionViaKeystroke: (FocusedTextTarget) async -> String?

    public init(
        readSelectedTextAttribute: @escaping (FocusedTextTarget) -> String?,
        readValueAttribute: @escaping (FocusedTextTarget) -> String?,
        copySelectionViaKeystroke: @escaping (FocusedTextTarget) async -> String?
    ) {
        self.readSelectedTextAttribute = readSelectedTextAttribute
        self.readValueAttribute = readValueAttribute
        self.copySelectionViaKeystroke = copySelectionViaKeystroke
    }

    public func read(_ target: FocusedTextTarget) async -> SelectionLadder.Resolution {
        var attempts: [(SelectionRung, SelectionRead)] = []

        attempts.append((.axSelectedText, Self.classify(readSelectedTextAttribute(target))))
        if SelectionLadder.shouldContinue(after: attempts[attempts.count - 1].1) {
            attempts.append((.axValueSubstring, rungTwo(target)))
        }
        if SelectionLadder.shouldContinue(after: attempts[attempts.count - 1].1) {
            attempts.append((.copyKeystroke, Self.classify(await copySelectionViaKeystroke(target))))
        }
        return SelectionLadder.resolve(attempts)
    }

    /// Rung 2 needs BOTH a readable value and a known range — a withheld range
    /// cannot be sliced, so that case is unreadable and falls through.
    private func rungTwo(_ target: FocusedTextTarget) -> SelectionRead {
        guard let value = readValueAttribute(target),
              let range = target.selectedRange,
              let slice = SelectionLadder.substring(of: value, in: range) else {
            return .unreadable
        }
        return Self.classify(slice)
    }

    /// nil is unreadable; "" is a real, readable, empty selection. Collapsing
    /// these is the bug this three-state exists to prevent.
    static func classify(_ text: String?) -> SelectionRead {
        guard let text else { return .unreadable }
        return text.isEmpty ? .empty : .text(text)
    }
}

#if os(macOS)
import AppKit
import ApplicationServices

extension AccessibilitySelectionReader {
    /// The production reader. Rungs 1 and 2 are passive AX reads. Rung 3
    /// reuses `PasteboardSnapshot`'s capture → copy → restore-only-if-still-ours
    /// discipline and the same `postToPid` synthesis `TextInserter` uses for ⌘V,
    /// so the user's clipboard survives a rewrite untouched.
    @MainActor
    public static func live() -> AccessibilitySelectionReader {
        func focusedElement() -> AXUIElement? {
            let systemWide = AXUIElementCreateSystemWide()
            var focusedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                    systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                  let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeDowncast(focusedRef, to: AXUIElement.self)
        }

        func attribute(_ name: String) -> String? {
            guard let element = focusedElement() else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
                return nil
            }
            return value as? String
        }

        return AccessibilitySelectionReader(
            readSelectedTextAttribute: { _ in attribute(kAXSelectedTextAttribute) },
            readValueAttribute: { _ in attribute(kAXValueAttribute) },
            copySelectionViaKeystroke: { target in
                let snapshot = PasteboardSnapshot.capture(from: .general)
                let before = NSPasteboard.general.changeCount

                guard let source = CGEventSource(stateID: .hidSystemState),
                      // virtualKey 8 == 'c'
                      let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
                      let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else {
                    return nil
                }
                keyDown.flags = .maskCommand
                keyUp.flags = .maskCommand
                keyDown.postToPid(target.applicationPID)
                keyUp.postToPid(target.applicationPID)

                // Give the target time to service ⌘C, matching TextInserter's
                // 350ms settle. A copy that never lands leaves changeCount
                // untouched, which is how we detect it.
                try? await Task.sleep(for: .milliseconds(350))

                let after = NSPasteboard.general.changeCount
                let copied = after != before ? NSPasteboard.general.string(forType: .string) : nil

                // Restore only while the pasteboard still holds nothing but our
                // synthesized copy. If it moved by more than that single write,
                // something else owns the clipboard now and must not be clobbered
                // — the same rule as `PasteboardSnapshot.shouldRestore`.
                if after <= before + 1 { snapshot.restore(to: .general) }
                return copied
            })
    }
}
#endif
