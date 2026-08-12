import Foundation
import SwiftData

/// Gathers the candidate speaker names `MeetingSpeakerAttribution` matches
/// verbal handoffs against (BAK-335): past meeting-action owners union the
/// user's custom vocabulary, de-duplicated case-insensitively. Follows
/// `VoiceLexiconSource`'s pattern — the one place this feature touches
/// `ModelContext`/`FetchDescriptor`, so the coordinator calls a single
/// function rather than duplicating fetch logic.
///
/// `CalendarEvent` does NOT model meeting attendees (BAK-335 finding: it
/// carries only `externalId`/`calendarId`/`title`/`start`/`end`/`isAllDay`/
/// `joinURL`/`location`/`updatedAt` — no participant or invitee list), so a
/// meeting's linked `calendarEvent` contributes nothing here today. If
/// attendees are ever added to `CalendarEvent`, this is the one place to
/// wire them into the candidate list.
public enum MeetingSpeakerCandidateSource {
    /// - Parameters:
    ///   - context: the app's ModelContext (main-actor bound in production,
    ///     an in-memory container in tests).
    ///   - userTerms: already-parsed custom vocabulary (see
    ///     `VoiceLexicon.parseUserTerms`); callers read this from
    ///     `VoiceLexiconUserTerms.load()` before calling here — matching
    ///     `VoiceLexiconSource.fetch`'s injected-input style.
    public static func fetch(
        context: ModelContext,
        userTerms: [String]
    ) -> [String] {
        let proposalOwners = ((try? context.fetch(FetchDescriptor<MeetingActionProposal>())) ?? [])
            .compactMap(\.owner)

        var seen: Set<String> = []
        var result: [String] = []
        for name in proposalOwners + userTerms {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed.lowercased()).inserted {
                result.append(trimmed)
            }
        }
        return result
    }
}
