import Foundation

/// One editable field of a voice-captured task draft. The quick editor bumps a
/// per-field revision on every user edit; the on-device generator snapshots the
/// revisions when a request starts, so a late result can be applied field by
/// field only where Leon hasn't typed since.
public enum VoiceTaskField: String, CaseIterable, Hashable, Sendable {
    case title
    case notes
    case area
    case schedule
    case urls
}

/// A typed, already-validated draft of a voice-captured task (modern voice-task
/// capture spec). Foundation-only on purpose — the quick editor, the coordinator,
/// and the on-device generator all build on this type.
public struct VoiceTaskDraft: Equatable, Sendable {
    public var title: String
    public var notes: String?
    public var areaName: String?
    public var scheduledDate: Date?
    public var urls: [URL]

    public init(
        title: String = "",
        notes: String? = nil,
        areaName: String? = nil,
        scheduledDate: Date? = nil,
        urls: [URL] = []
    ) {
        self.title = title
        self.notes = notes
        self.areaName = areaName
        self.scheduledDate = scheduledDate
        self.urls = urls
    }
}

/// Monotonic per-field edit counters. Every field starts at 0; each user edit
/// bumps that field only. Comparing a live counter against the snapshot taken
/// when a generation request began tells whether the generated value may land.
public struct VoiceTaskFieldRevisions: Equatable, Sendable, ExpressibleByDictionaryLiteral {
    private var counts: [VoiceTaskField: Int]

    public init() {
        counts = [:]
    }

    public init(dictionaryLiteral elements: (VoiceTaskField, Int)...) {
        counts = Dictionary(uniqueKeysWithValues: elements)
    }

    public subscript(field: VoiceTaskField) -> Int {
        counts[field] ?? 0
    }

    public mutating func bump(_ field: VoiceTaskField) {
        counts[field] = self[field] + 1
    }
}

/// Pure validation + merge rules for generated voice-task drafts. The generator
/// (impure, model-facing) funnels its raw strings through here; the merge
/// guarantees a late model result never overwrites a field Leon edited after the
/// request began. Deterministic throughout: injected calendar, no ambient clock.
public enum VoiceTaskDrafting {
    // MARK: - Revision precedence

    /// A generated value may land on `field` only if its revision is unchanged
    /// since the generation request snapshotted the counters.
    public static func shouldApply(
        field: VoiceTaskField,
        current: VoiceTaskFieldRevisions,
        atRequest: VoiceTaskFieldRevisions
    ) -> Bool {
        current[field] == atRequest[field]
    }

    // MARK: - Field validation

    /// Trim and collapse whitespace runs; a title left empty is invalid (nil).
    public static func validatedTitle(_ raw: String) -> String? {
        let title = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return title.isEmpty ? nil : title
    }

    /// Trimmed notes; nil/blank means "nothing proposed", never "clear notes".
    public static func validatedNotes(_ raw: String?) -> String? {
        guard let notes = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !notes.isEmpty else { return nil }
        return notes
    }

    /// An area is valid only if it names one of the allowed areas (trimmed,
    /// case-insensitive), and it canonicalizes to the allowed spelling — the
    /// model never mints a new area.
    public static func validatedArea(_ name: String?, allowedAreas: [String]) -> String? {
        guard let candidate = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else { return nil }
        return allowedAreas.first { $0.compare(candidate, options: .caseInsensitive) == .orderedSame }
    }

    /// Deterministic URL validation — generated URLs are never trusted from model
    /// output alone. Keeps only strings that parse as absolute http(s) URLs with
    /// a host; preserves order; drops duplicates.
    public static func validatedURLs(_ candidates: [String]) -> [URL] {
        var seen = Set<URL>()
        var urls: [URL] = []
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = components.host, !host.isEmpty,
                  let url = components.url,
                  seen.insert(url).inserted else { continue }
            urls.append(url)
        }
        return urls
    }

    /// Keep only URLs the speaker actually referred to. The prompt forbids
    /// inventing links, but a prompt is not an enforcement mechanism: a real
    /// capture came back carrying `http://example.com` for a sentence that
    /// mentioned no site at all. Fabricated data reaching a task is worse than
    /// a missing link, which the user can simply add.
    ///
    /// Matching is on the domain NAME rather than the whole host, because
    /// recognisers write spoken domains inconsistently ("coles dot com au"):
    /// requiring the literal host would drop legitimate links.
    public static func groundedURLs(_ urls: [URL], in transcript: String) -> [URL] {
        let spoken = transcript.lowercased()
        return urls.filter { url in
            guard let host = url.host?.lowercased() else { return false }
            let labels = host.split(separator: ".").map(String.init)
            // Skip "www" and the TLD; the registrable name is what gets said.
            let name = labels
                .filter { $0 != "www" }
                .max(by: { $0.count < $1.count }) ?? host
            return spoken.contains(host) || spoken.contains(name)
        }
    }

    /// Resolve a model-supplied ISO 8601 string via the injected calendar — never
    /// the ambient clock/zone. Two shapes are accepted:
    /// - `"YYYY-MM-DD"` → that day at 09:00 in the calendar's zone (the
    ///   quick-capture date-only convention).
    ///   Rollover dates (e.g. Feb 30) are rejected via a round-trip check.
    /// - a full internet timestamp with an explicit offset → the exact instant.
    /// Anything else (relative words, other formats) is rejected: the task stays
    /// unscheduled rather than guessing.
    public static func scheduledDate(fromISO8601 raw: String?, calendar: Calendar) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }

        if let (year, month, day) = splitDay(raw) {
            var comps = DateComponents()
            comps.year = year; comps.month = month; comps.day = day
            comps.hour = 9; comps.minute = 0
            guard (1...12).contains(month), (1...31).contains(day),
                  let date = calendar.date(from: comps),
                  // Reject overflow rollovers (Feb 30 → Mar 2): the round-trip must agree.
                  calendar.component(.day, from: date) == day,
                  calendar.component(.month, from: date) == month else { return nil }
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = calendar.timeZone
        return formatter.date(from: raw)
    }

    // MARK: - Whole-draft validation

    /// Build a validated draft from the generator's raw strings. A missing/empty
    /// title rejects the whole draft (the run is a retryable failure — the task
    /// stays raw); an invalid optional field is dropped, keeping the rest.
    public static func validated(
        title: String,
        notes: String?,
        areaName: String?,
        scheduledISO8601: String?,
        urls: [String],
        allowedAreas: [String],
        calendar: Calendar
    ) -> VoiceTaskDraft? {
        guard let title = validatedTitle(title) else { return nil }
        return VoiceTaskDraft(
            title: title,
            notes: validatedNotes(notes),
            areaName: validatedArea(areaName, allowedAreas: allowedAreas),
            scheduledDate: scheduledDate(fromISO8601: scheduledISO8601, calendar: calendar),
            urls: validatedURLs(urls)
        )
    }

    // MARK: - Merge

    /// Fold a generated draft into the current one, field by field. A field lands
    /// only when (a) the generated value is present and valid, and (b) its
    /// revision is unchanged since the request began — so a late model result
    /// never overwrites a user edit, and an absent generated field never clears
    /// a value Leon already has.
    public static func merge(
        generated: VoiceTaskDraft,
        into current: VoiceTaskDraft,
        revisions: VoiceTaskFieldRevisions,
        requestRevisions: VoiceTaskFieldRevisions
    ) -> VoiceTaskDraft {
        func applies(_ field: VoiceTaskField) -> Bool {
            shouldApply(field: field, current: revisions, atRequest: requestRevisions)
        }

        var merged = current
        if applies(.title), let title = validatedTitle(generated.title) {
            merged.title = title
        }
        if applies(.notes), let notes = validatedNotes(generated.notes) {
            merged.notes = notes
        }
        if applies(.area), let area = generated.areaName, !area.isEmpty {
            merged.areaName = area
        }
        if applies(.schedule), let date = generated.scheduledDate {
            merged.scheduledDate = date
        }
        if applies(.urls), !generated.urls.isEmpty {
            merged.urls = generated.urls
        }
        return merged
    }

    // MARK: - Helpers

    /// Strictly parse `"YYYY-MM-DD"` (4-2-2 digits); nil for any other shape.
    private static func splitDay(_ raw: String) -> (year: Int, month: Int, day: Int)? {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return (year, month, day)
    }
}
