import Foundation
import CryptoKit

/// One harvested action item from a meeting note's "Code Heroes tasks" section.
public struct ParsedMeetingTask: Equatable {
    public let title: String
    public let isDone: Bool
    public let due: Date?
    /// Skill-authored 1–2 sentence description (nil on plain/legacy lines).
    public let desc: String?
    /// Owner annotation with wikilink brackets stripped (nil if absent).
    public let owner: String?
    /// Raw `due:` text — "imminent" / "not stated" / ISO date (nil if absent).
    public let dueText: String?
    /// Transcript citation from `[T: "…"]` (nil if absent).
    public let transcriptQuote: String?
    /// Topic tags, `#` stripped, structural `#task`/`#ch` removed.
    public let tags: [String]
    /// The original line verbatim — kept so the sync can re-locate it for write-back.
    public let rawLine: String
    public let notePath: String
    /// Stable identity for dedup + line-locating (see `originKey`).
    public let originKey: String
    /// Originating meeting slug from `src:`, wikilinks stripped (nil if absent).
    /// Task Ledger lines carry this because the ledger's own path says nothing
    /// about which meeting raised the task.
    public let srcNote: String?
}

/// Pure, deterministic harvester for the curated `- [ ]` checklist that Leon's
/// Sync pipeline writes into each meeting note. No model call — the extraction
/// and owner-filtering already happened upstream; Mustard only lifts the lines.
public enum MeetingTaskParser {
    /// Heading whose checklist we harvest — case-insensitive, trailing text tolerated
    /// (`### Code Heroes tasks (Leon)` matches).
    static let sectionHeading = "code heroes tasks"

    private static let checkboxPrefix = #"^\s*[-*]\s+\[[ xX]\]\s*"#
    private static let donePattern = #"✅\s*\d{4}-\d{2}-\d{2}"#
    private static let duePattern = #"📅\s*\d{4}-\d{2}-\d{2}"#
    private static let blockIdSuffix = #"\s*\^[\w-]+\s*$"#
    private static let isoDate = #"\d{4}-\d{2}-\d{2}"#
    /// Obsidian Tasks metadata emoji we drop from the human-readable title.
    private static let metaEmoji = CharacterSet(charactersIn: "⏫🔺🔼🔽⏬🔁⏳🛫➕❌")

    /// Harvest the `- [ ]` lines under the "Code Heroes tasks" heading, in order.
    public static func parse(_ text: String, notePath: String) -> [ParsedMeetingTask] {
        var out: [ParsedMeetingTask] = []
        var inSection = false
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" }
                    .trimmingCharacters(in: .whitespaces).lowercased()
                inSection = heading.hasPrefix(sectionHeading)
                continue
            }
            guard inSection, isCheckbox(trimmed) else { continue }
            out.append(
                ParsedMeetingTask(
                    title: extractTitle(rawLine),
                    isDone: isChecked(rawLine),
                    due: dueDate(rawLine),
                    desc: quotedField(rawLine, label: "desc"),
                    owner: stripWikilinks(field(rawLine, label: "owner")),
                    dueText: field(rawLine, label: "due"),
                    transcriptQuote: transcriptQuote(rawLine),
                    tags: tags(rawLine),
                    rawLine: rawLine,
                    notePath: notePath,
                    originKey: originKey(notePath: notePath, line: rawLine),
                    srcNote: stripWikilinks(field(rawLine, label: "src"))
                )
            )
        }
        return out
    }

    static func isCheckbox(_ line: String) -> Bool {
        line.range(of: checkboxPrefix, options: .regularExpression) != nil
    }

    static func isChecked(_ line: String) -> Bool {
        guard let r = line.range(of: #"\[[ xX]\]"#, options: .regularExpression) else { return false }
        return line[r].lowercased().contains("x")
    }

    /// Due date: the `due: YYYY-MM-DD` text the sync skill writes, falling back to
    /// the `📅 YYYY-MM-DD` Obsidian-Tasks form on hand-written lines.
    static func dueDate(_ line: String) -> Date? {
        if let r = line.range(of: #"due:\s*\d{4}-\d{2}-\d{2}"#, options: .regularExpression),
           let dr = line[r].range(of: isoDate, options: .regularExpression) {
            return dateFormatter.date(from: String(line[r][dr]))
        }
        if let r = line.range(of: duePattern, options: .regularExpression),
           let dr = line[r].range(of: isoDate, options: .regularExpression) {
            return dateFormatter.date(from: String(line[r][dr]))
        }
        return nil
    }

    /// Human-readable title = the action clause before the first em-dash separator.
    /// The sync skill guarantees the action clause contains no `—`; plain
    /// Obsidian-Tasks lines have none either, so the whole line is used and the
    /// date/priority/block-id strips below clean it up.
    static func extractTitle(_ line: String) -> String {
        var s = line.replacingOccurrences(of: checkboxPrefix, with: "", options: .regularExpression)
        if let i = s.firstIndex(of: "\u{2014}") { s = String(s[..<i]) }
        s = s.replacingOccurrences(of: donePattern, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: duePattern, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: blockIdSuffix, with: "", options: .regularExpression)
        s = stripWikilinks(s) ?? ""
        s = s.replacingOccurrences(of: #"#[\w-]+"#, with: "", options: .regularExpression)
        var kept = String.UnicodeScalarView()
        for scalar in s.unicodeScalars where !metaEmoji.contains(scalar) { kept.append(scalar) }
        return collapseWhitespace(String(kept))
    }

    /// `label: value` where value runs to the next comma, `#`, em-dash, or end.
    static func field(_ line: String, label: String) -> String? {
        guard let r = line.range(of: "\(label):\\s*([^,#\u{2014}]+)", options: .regularExpression) else { return nil }
        let raw = String(line[r]).replacingOccurrences(of: "\(label):", with: "")
        let v = raw.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// `label: "value"` — the quoted form used by `desc:`.
    static func quotedField(_ line: String, label: String) -> String? {
        guard let r = line.range(of: "\(label):\\s*\"([^\"]*)\"", options: .regularExpression),
              let q = line[r].range(of: "\"[^\"]*\"", options: .regularExpression) else { return nil }
        let v = String(line[r][q]).dropFirst().dropLast()
        return v.isEmpty ? nil : String(v)
    }

    /// The transcript citation inside `[T: "…"]`.
    static func transcriptQuote(_ line: String) -> String? {
        guard let r = line.range(of: #"\[T:\s*"[^"]*"\]"#, options: .regularExpression),
              let q = line[r].range(of: "\"[^\"]*\"", options: .regularExpression) else { return nil }
        let v = String(line[r][q]).dropFirst().dropLast()
        return v.isEmpty ? nil : String(v)
    }

    /// `#tags` minus the structural `#task`/`#ch`, leading `#` stripped, in order.
    static func tags(_ line: String) -> [String] {
        let skip: Set<String> = ["task", "ch"]
        var out: [String] = []
        var idx = line.startIndex
        while let r = line.range(of: #"#[\w-]+"#, options: .regularExpression, range: idx..<line.endIndex) {
            let tag = String(line[r].dropFirst())
            if !skip.contains(tag.lowercased()) { out.append(tag) }
            idx = r.upperBound
        }
        return out
    }

    /// Strip `[[wikilink]]` → inner text. Returns nil only for nil input.
    static func stripWikilinks(_ s: String?) -> String? {
        guard let s else { return nil }
        return s.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
    }

    /// Stable identity: SHA-256 of `notePath` + the line with its checkbox state
    /// and `✅ <date>` stripped — so `- [ ]` → `- [x] ✅ date` keeps the same key.
    public static func originKey(notePath: String, line: String) -> String {
        sha256Hex(notePath + "\n" + normalize(line))
    }

    static func normalize(_ line: String) -> String {
        var s = line.replacingOccurrences(of: checkboxPrefix, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: donePattern, with: "", options: .regularExpression)
        return collapseWhitespace(s)
    }

    private static func collapseWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
