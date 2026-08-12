import Foundation

/// Which focused-element roles rewrite will act on. Broader than dictation's
/// `AccessibilityFocusReader.textualRoles` because Chromium/Electron apps
/// (Gmail, Slack, Linear) often report the focused element as an `AXWebArea`
/// rather than an `AXTextArea` — and those are exactly the targets rewrite
/// exists for. Kept as a separate policy so widening it can never regress
/// dictation. Expect this set to grow from real cross-app matrix data.
public enum RewriteRoles {
    public static let textual: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea",
    ]

    public static func admits(role: String?) -> Bool {
        guard let role else { return false }
        return textual.contains(role)
    }
}
