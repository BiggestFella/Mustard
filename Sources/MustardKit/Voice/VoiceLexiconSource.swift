import Foundation
import SwiftData

/// Gathers the SwiftData-backed inputs to `VoiceLexicon.terms(...)` — the
/// only place this feature touches `ModelContext`/`FetchDescriptor` — so both
/// capture paths (push-to-talk and meetings) call one function at
/// capture/meeting start rather than duplicating fetch logic (BAK-334).
public enum VoiceLexiconSource {
    /// How far back a task's `createdAt` may be and still contribute a
    /// title-derived term. Standup vocabulary drifts (a client wraps up, a
    /// new one starts); an unbounded task history would keep biasing toward
    /// vocabulary that stopped being relevant months ago.
    static let taskLookbackSeconds: TimeInterval = 90 * 24 * 60 * 60

    /// - Parameters:
    ///   - context: the app's ModelContext (main-actor bound in production,
    ///     an in-memory container in tests).
    ///   - now: injected so the 90-day window is deterministic in tests —
    ///     never the ambient clock.
    ///   - userTerms: already-parsed custom vocabulary (see
    ///     `VoiceLexicon.parseUserTerms`); callers read this from
    ///     `UserDefaults` (`VoiceLexiconUserTerms.key`) before calling here.
    ///   - cap: forwarded to `VoiceLexicon.terms`.
    public static func fetch(
        context: ModelContext,
        now: Date,
        userTerms: [String],
        cap: Int = VoiceLexicon.defaultCap
    ) -> [String] {
        let areas = ((try? context.fetch(FetchDescriptor<Area>())) ?? []).map(\.name)
        let taskLists = ((try? context.fetch(FetchDescriptor<TaskList>())) ?? []).map(\.name)

        let cutoff = now.addingTimeInterval(-taskLookbackSeconds)
        let taskDescriptor = FetchDescriptor<MustardTask>(
            predicate: #Predicate { $0.createdAt >= cutoff })
        let taskTitles = ((try? context.fetch(taskDescriptor)) ?? []).map(\.title)

        let proposalOwners = ((try? context.fetch(FetchDescriptor<MeetingActionProposal>())) ?? [])
            .compactMap(\.owner)

        return VoiceLexicon.terms(
            areas: areas,
            taskLists: taskLists,
            taskTitles: taskTitles,
            proposalOwners: proposalOwners,
            userTerms: userTerms,
            cap: cap)
    }
}

/// The persisted "custom vocabulary" setting (Voice Setup, BAK-334) — a
/// simple newline/comma-separated string, matching the light UserDefaults
/// style used elsewhere (`BoardSettings`, `@AppStorage` in the views) rather
/// than a new SwiftData model for one text field.
public enum VoiceLexiconUserTerms {
    public static let key = "voice.lexicon.userTerms"

    public static func load(_ defaults: UserDefaults = .standard) -> [String] {
        VoiceLexicon.parseUserTerms(defaults.string(forKey: key) ?? "")
    }
}
