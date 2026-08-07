import Foundation

/// A pure snapshot of the focused text field taken when a system-wide dictation
/// hold begins (⌃⌥D). The coordinator re-snapshots on release and compares with
/// `==` — if the identity changed (different app, element, or cursor), the
/// transcript is never inserted into the wrong field; it goes to safe recovery.
///
/// The AX reading that *produces* one of these lives in `Dictation/` (macOS-only,
/// injected via `FocusedTextReading`); this value stays pure so every insertion
/// decision is unit-testable.
public struct FocusedTextTarget: Equatable, Sendable {
    /// Owning application, for revalidation and paste-event routing.
    public let applicationPID: pid_t
    /// Stable identity for the focused element (PID + role/window metadata),
    /// built by the Accessibility reader.
    public let elementIdentifier: String
    /// Selection at snapshot time; nil when the element hides its range.
    /// Length 0 is an empty cursor; length > 0 is a replaceable selection.
    public let selectedRange: NSRange?
    /// Character immediately before the cursor/selection, nil at document start
    /// or when unreadable.
    public let precedingCharacter: Character?
    /// Character immediately after the cursor/selection, nil at document end
    /// or when unreadable.
    public let followingCharacter: Character?
    /// Secure/password-shaped element (AX secure role/subrole). Insertion logic
    /// must refuse these outright.
    public let isSecure: Bool

    public init(
        applicationPID: pid_t,
        elementIdentifier: String,
        selectedRange: NSRange?,
        precedingCharacter: Character?,
        followingCharacter: Character?,
        isSecure: Bool
    ) {
        self.applicationPID = applicationPID
        self.elementIdentifier = elementIdentifier
        self.selectedRange = selectedRange
        self.precedingCharacter = precedingCharacter
        self.followingCharacter = followingCharacter
        self.isSecure = isSecure
    }
}

/// Injected Accessibility adapter: snapshots the focused element and confirms a
/// prior snapshot is still the focused element on release. The real reader
/// (`Dictation/AccessibilityFocusReader`, macOS AX APIs) conforms; tests inject
/// a stub, keeping the coordinator free of ApplicationServices.
public protocol FocusedTextReading {
    func snapshot() throws -> FocusedTextTarget
    func isStillFocused(_ target: FocusedTextTarget) -> Bool
}
