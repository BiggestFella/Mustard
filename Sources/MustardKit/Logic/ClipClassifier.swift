import Foundation

/// What kind of thing a clip is. String-backed for SwiftData persistence.
/// `.image`/`.file`/`.dictation` are assigned by the capture path, never by
/// text classification.
public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, link, color, image, file, dictation
}

/// Pure text → kind classification for pasteboard string payloads.
public enum ClipClassifier {
    /// A whole-string hex color (#RGB, #RRGGBB) or rgb()/rgba() literal → .color;
    /// a single whole-string http(s) URL → .link; everything else → .text.
    public static func classify(text: String) -> ClipKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text }
        if isHexColor(trimmed) || isRGBFunction(trimmed) { return .color }
        if isSingleHTTPURL(trimmed) { return .link }
        return .text
    }

    private static func isHexColor(_ s: String) -> Bool {
        guard s.hasPrefix("#") else { return false }
        let digits = s.dropFirst()
        guard digits.count == 3 || digits.count == 6 else { return false }
        return digits.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    private static func isRGBFunction(_ s: String) -> Bool {
        let lower = s.lowercased()
        guard lower.hasPrefix("rgb(") || lower.hasPrefix("rgba("), lower.hasSuffix(")") else {
            return false
        }
        let inner = lower.drop(while: { $0 != "(" }).dropFirst().dropLast()
        let parts = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return (3...4).contains(parts.count) && parts.allSatisfy { Double($0) != nil }
    }

    private static func isSingleHTTPURL(_ s: String) -> Bool {
        guard !s.contains(where: { $0.isWhitespace }),
              let url = URL(string: s),
              let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
}
