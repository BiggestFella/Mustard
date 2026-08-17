import Foundation

/// One raw Accessibility focus reading, framework-light so tests construct it
/// directly. The live probe (below, macOS-only) fills this from the AX APIs;
/// the reader turns it into a pure `FocusedTextTarget`.
public struct AXFocusProbe: Equatable, Sendable {
    public var pid: pid_t
    public var role: String?
    public var subrole: String?
    /// UTF-16 based, as AX reports it; nil when the element hides its range.
    public var selectedRange: NSRange?
    /// The element's full text value; often withheld by web areas.
    public var value: String?
    public var windowTitle: String?
    /// Stable while the element lives (the live probe hashes the AXUIElement).
    public var elementToken: String?
    /// The element's currently selected text (`kAXSelectedTextAttribute`).
    /// Frequently readable even when `value` is withheld, which is why rewrite's
    /// read ladder tries it first. Dictation does not use this.
    public var selectedText: String?

    public init(
        pid: pid_t,
        role: String?,
        subrole: String?,
        selectedRange: NSRange?,
        value: String?,
        windowTitle: String?,
        elementToken: String?,
        selectedText: String? = nil
    ) {
        self.pid = pid
        self.role = role
        self.subrole = subrole
        self.selectedRange = selectedRange
        self.value = value
        self.windowTitle = windowTitle
        self.elementToken = elementToken
        self.selectedText = selectedText
    }
}

/// Why a focus snapshot could not be taken.
public enum FocusReadError: Error, Equatable, Sendable {
    /// Accessibility is not granted — Voice Setup routes to System Settings.
    case accessibilityPermissionMissing
    /// Nothing textual has focus right now.
    case noFocusedTextElement
    /// The focused application stopped responding or died.
    case applicationUnavailable
}

/// The Accessibility adapter behind `FocusedTextReading` (Dictation Task 2,
/// BAK-288): snapshots the focused text element and revalidates that a prior
/// snapshot still owns focus before anything is inserted. All AX access goes
/// through the injected `probe` closure, so every decision here is pure.
public struct AccessibilityFocusReader: FocusedTextReading {
    private let isTrusted: () -> Bool
    private let probe: () throws -> AXFocusProbe?

    public init(
        isTrusted: @escaping () -> Bool,
        probe: @escaping () throws -> AXFocusProbe?
    ) {
        self.isTrusted = isTrusted
        self.probe = probe
    }

    /// Roles that can receive dictated text. Everything else — buttons, web
    /// areas as a whole, canvases — reads as "no focused text element".
    static let textualRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
    ]

    /// Dictation's snapshot: the protocol witness, and the only signature
    /// dictation ever calls. Its role policy is `textualRoles`, unchanged.
    public func snapshot() throws -> FocusedTextTarget {
        try snapshot(roles: Self.textualRoles)
    }

    /// The same snapshot under a caller-supplied role policy. Rewrite passes
    /// `RewriteRoles.textual`, which admits `AXWebArea` — without this it would
    /// be refused in Gmail and Slack, the two targets it exists for. An
    /// overload rather than a defaulted parameter so the protocol witness above
    /// stays exact and dictation's behaviour is byte-for-byte identical.
    public func snapshot(roles: Set<String>) throws -> FocusedTextTarget {
        guard isTrusted() else { throw FocusReadError.accessibilityPermissionMissing }
        guard let probe = try probe(),
              let role = probe.role, roles.contains(role) else {
            throw FocusReadError.noFocusedTextElement
        }
        let neighbors = Self.neighbors(of: probe.selectedRange, in: probe.value)
        return FocusedTextTarget(
            applicationPID: probe.pid,
            elementIdentifier: Self.identity(of: probe),
            selectedRange: probe.selectedRange,
            precedingCharacter: neighbors.before,
            followingCharacter: neighbors.after,
            isSecure: probe.subrole == "AXSecureTextField")
    }

    /// True only when the same textual element still owns focus. Any failure —
    /// revoked permission, dead app, focus moved — fails closed to false, so
    /// the transcript is never inserted into the wrong place.
    public func isStillFocused(_ target: FocusedTextTarget) -> Bool {
        isStillFocused(target, roles: Self.textualRoles)
    }

    /// Same revalidation under a caller-supplied role policy. Rewrite passes
    /// `RewriteRoles.textual` so Gmail/Slack (`AXWebArea`) can accept a rewrite
    /// after a successful snapshot; dictation keeps the narrower set.
    public func isStillFocused(_ target: FocusedTextTarget, roles: Set<String>) -> Bool {
        guard isTrusted(),
              let probe = try? probe(),
              let role = probe.role, roles.contains(role) else {
            return false
        }
        return probe.pid == target.applicationPID
            && Self.identity(of: probe) == target.elementIdentifier
    }

    /// Best-effort paste-delivery check: true/false when the focused
    /// element's value is readable, nil when it isn't (web areas often
    /// withhold it) — unknowable is not the same as failed.
    public func focusedValueContains(_ text: String) -> Bool? {
        guard isTrusted(), let probe = try? probe(), let value = probe.value else { return nil }
        return value.contains(text)
    }

    // MARK: - Pure mapping

    /// Stable identity: PID anchored, plus the element token and role/window
    /// metadata. Deliberately excludes the selection — the cursor may move
    /// while the identity stays the same; strict cursor comparison is the
    /// coordinator's job via `FocusedTextTarget`'s `==`.
    static func identity(of probe: AXFocusProbe) -> String {
        "\(probe.pid)#\(probe.elementToken ?? "-")#\(probe.role ?? "-")#\(probe.windowTitle ?? "-")"
    }

    /// The characters flanking the selection. AX ranges are UTF-16 based;
    /// converting through `Range(_:in:)` keeps surrogate pairs (emoji) whole.
    /// Unreadable value or an out-of-bounds range → (nil, nil).
    static func neighbors(
        of selectedRange: NSRange?, in value: String?
    ) -> (before: Character?, after: Character?) {
        guard let selectedRange, let value,
              let range = Range(selectedRange, in: value) else { return (nil, nil) }
        let before = range.lowerBound > value.startIndex
            ? value[value.index(before: range.lowerBound)] : nil
        let after = range.upperBound < value.endIndex
            ? value[range.upperBound] : nil
        return (before, after)
    }
}

// MARK: - Live AX probe (macOS only; verified in the cross-app matrix)

#if os(macOS)
import ApplicationServices

extension AccessibilityFocusReader {
    /// The production reader over the real Accessibility APIs. Reads are
    /// passive — nothing here prompts; the Accessibility grant is requested
    /// from Voice Setup only.
    public static func live() -> AccessibilityFocusReader {
        AccessibilityFocusReader(
            isTrusted: { AXIsProcessTrusted() },
            probe: { try liveProbe() })
    }

    private static func liveProbe() throws -> AXFocusProbe? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        switch status {
        case .success:
            break
        case .cannotComplete:
            // The focused app stopped responding (or died mid-read).
            throw FocusReadError.applicationUnavailable
        default:
            return nil
        }
        guard let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeDowncast(focusedRef, to: AXUIElement.self)

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)

        func attribute(_ name: String, of target: AXUIElement) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(target, name as CFString, &value) == .success else {
                return nil
            }
            return value
        }

        var selectedRange: NSRange?
        if let rangeRef = attribute(kAXSelectedTextRangeAttribute, of: element),
           CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var cfRange = CFRange()
            if AXValueGetValue(unsafeDowncast(rangeRef, to: AXValue.self), .cfRange, &cfRange) {
                selectedRange = NSRange(location: cfRange.location, length: cfRange.length)
            }
        }

        var windowTitle: String?
        if let windowRef = attribute(kAXWindowAttribute, of: element),
           CFGetTypeID(windowRef) == AXUIElementGetTypeID() {
            windowTitle = attribute(
                kAXTitleAttribute, of: unsafeDowncast(windowRef, to: AXUIElement.self)) as? String
        }

        return AXFocusProbe(
            pid: pid,
            role: attribute(kAXRoleAttribute, of: element) as? String,
            subrole: attribute(kAXSubroleAttribute, of: element) as? String,
            selectedRange: selectedRange,
            value: attribute(kAXValueAttribute, of: element) as? String,
            windowTitle: windowTitle,
            // Stable while the element lives: AXUIElement is CFHash-able and
            // two references to the same element hash identically.
            elementToken: String(CFHash(element)),
            // Read for rewrite's rung 1; dictation ignores it.
            selectedText: attribute(kAXSelectedTextAttribute, of: element) as? String)
    }
}
#endif
