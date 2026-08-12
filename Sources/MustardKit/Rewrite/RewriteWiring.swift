#if os(macOS)
import ApplicationServices
import Foundation

/// Live suppliers for the coordinator's two remaining edges.
public enum RewriteWiring {

    /// The focused element's AX role, read independently of dictation's
    /// narrower `textualRoles` gate. `AccessibilityFocusReader.snapshot()`
    /// throws `noFocusedTextElement` for anything outside that set, which
    /// would block rewrite in exactly the web areas it exists for — so the
    /// role is read directly here and judged by `RewriteRoles`.
    public static func focusedRole() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeDowncast(focusedRef, to: AXUIElement.self)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// The band-appropriate instruction text, loaded once. Falls back to the
    /// base band's resource, and finally to a minimal built-in string so a
    /// missing resource degrades instead of crashing.
    /// `Bundle.module` is internal to this target, so it cannot be a default
    /// argument on a public function — the caller-facing overload below fills
    /// it in instead.
    public static func bandInstructions() -> String {
        bandInstructions(bundle: .module)
    }

    static func bandInstructions(bundle: Bundle) -> String {
        let band = PromptCatalog.currentBand
        guard let name = PromptCatalog.bestResource(
                feature: RewritePrompt.feature, band: band,
                isAvailable: { bundle.url(forResource: $0, withExtension: "txt") != nil }),
              let url = bundle.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Rewrite the text. Preserve meaning exactly. Return only the rewritten text."
        }
        return text
    }
}
#endif
