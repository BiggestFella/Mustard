import Foundation

/// Pure mapping from a source to how the triage UI badges it. Vault stays quiet (plain
/// text line, no pill); non-vault sources get an icon + label + their own pill colours.
/// Colours are hex strings (not SwiftUI `Color`) so this stays a pure Logic unit.
public struct SourceBadge: Equatable {
    public let symbol: String   // SF Symbol name
    public let label: String
    public let isQuiet: Bool     // vault → true: no pill, matches today's calm look
    public let fgHex: String     // pill text colour (unused when isQuiet)
    public let bgHex: String     // pill background (unused when isQuiet)

    public init(symbol: String, label: String, isQuiet: Bool, fgHex: String = "", bgHex: String = "") {
        self.symbol = symbol
        self.label = label
        self.isQuiet = isQuiet
        self.fgHex = fgHex
        self.bgHex = bgHex
    }

    public static func badge(for source: SourceID) -> SourceBadge {
        switch source {
        case .gmail: SourceBadge(symbol: "envelope.fill", label: "Gmail", isQuiet: false, fgHex: "#A32D2D", bgHex: "#FCEBEB")
        case .jira: SourceBadge(symbol: "diamond.fill", label: "Jira", isQuiet: false, fgHex: "#2E5CB8", bgHex: "#E7EEF9")
        case .shortcut: SourceBadge(symbol: "flag.fill", label: "Shortcut", isQuiet: false, fgHex: "#5B4AA8", bgHex: "#ECE8F7")
        case .vault: SourceBadge(symbol: "books.vertical", label: "Vault", isQuiet: true)
        case .voice: SourceBadge(symbol: "mic.fill", label: "Voice", isQuiet: false, fgHex: "#7F77DD", bgHex: "#EEECFA")
        }
    }

    /// Tolerant entry point for the stored `Recommendation.source` string.
    public static func badge(forRaw raw: String) -> SourceBadge {
        badge(for: SourceID(rawValue: raw) ?? .vault)
    }
}
