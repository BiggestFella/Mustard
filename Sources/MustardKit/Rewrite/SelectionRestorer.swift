import Foundation

/// Re-asserts the snapshotted selection immediately before the rewrite is
/// written back. Only a genuine focus change blocks the write — a withheld or
/// unsettable range is reported (so the matrix records it) but still proceeds,
/// because ⌘V over the live selection remains correct in those apps.
///
/// Both seams are `@MainActor` for the same reason as `TextInserter`'s: setting
/// `kAXSelectedTextRangeAttribute` on a field inside Mustard itself is serviced
/// in-process and reaches `NSTextView.setSelectedRanges` →
/// `NSTextInputContext.invalidateCharacterCoordinates` → HIToolbox's
/// `dispatch_assert_queue(main)`. Today `reassert` happens to be called
/// synchronously from a main-actor coordinator; the annotation is what keeps
/// that true if an `async` hop is ever added between them.
public struct SelectionRestorer {
    public enum Outcome: Equatable, Sendable {
        /// The range was set successfully.
        case reasserted
        /// The element hides its range; nothing to set.
        case noRangeToReassert
        /// The element refused the range write. Logged, not fatal.
        case reassertRejected
        /// A different element has focus. The write must not happen.
        case focusChanged

        public var permitsWrite: Bool { self != .focusChanged }
    }

    public var stillFocused: @MainActor (FocusedTextTarget) -> Bool
    public var setSelectedRange: @MainActor (FocusedTextTarget, NSRange) -> Bool

    public init(
        stillFocused: @escaping @MainActor (FocusedTextTarget) -> Bool,
        setSelectedRange: @escaping @MainActor (FocusedTextTarget, NSRange) -> Bool
    ) {
        self.stillFocused = stillFocused
        self.setSelectedRange = setSelectedRange
    }

    @MainActor
    public func reassert(on target: FocusedTextTarget) -> Outcome {
        guard stillFocused(target) else { return .focusChanged }
        guard let range = target.selectedRange else { return .noRangeToReassert }
        return setSelectedRange(target, range) ? .reasserted : .reassertRejected
    }
}

#if os(macOS)
import ApplicationServices

extension SelectionRestorer {
    /// The production restorer, over `kAXSelectedTextRangeAttribute`.
    @MainActor
    public static func live(reader: AccessibilityFocusReader = .live()) -> SelectionRestorer {
        SelectionRestorer(
            stillFocused: { reader.isStillFocused($0, roles: RewriteRoles.textual) },
            setSelectedRange: { _, range in
                let systemWide = AXUIElementCreateSystemWide()
                var focusedRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                        systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                      let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
                    return false
                }
                let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
                var cfRange = CFRange(location: range.location, length: range.length)
                guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
                return AXUIElementSetAttributeValue(
                    element, kAXSelectedTextRangeAttribute as CFString, value) == .success
            })
    }
}
#endif
