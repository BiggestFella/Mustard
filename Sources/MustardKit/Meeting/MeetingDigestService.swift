// Digest generation is a Mac feature: the iOS companion compiles MustardKit
// sources at an iOS 17 floor without FoundationModels, so this unit is
// macOS-only (same rule as VoiceTaskDraftGenerator).
#if os(macOS)
import Foundation
import FoundationModels

/// One proposed action item from the model — all strings, validated before
/// anything touches persistence. Evidence is mandatory downstream.
@Generable
public struct GeneratedMeetingAction: Sendable {
    public var title: String
    public var owner: String?
    public var dueISO8601: String?
    public var evidenceSegmentIDs: [String]

    public init(
        title: String,
        owner: String? = nil,
        dueISO8601: String? = nil,
        evidenceSegmentIDs: [String] = []
    ) {
        self.title = title
        self.owner = owner
        self.dueISO8601 = dueISO8601
        self.evidenceSegmentIDs = evidenceSegmentIDs
    }
}

/// The model's digest of one transcript chunk (or of partial digests during
/// reduction).
@Generable
public struct GeneratedMeetingDigest: Sendable {
    public var summary: String
    public var decisions: [String]
    public var unresolvedQuestions: [String]
    public var actions: [GeneratedMeetingAction]

    public init(
        summary: String,
        decisions: [String] = [],
        unresolvedQuestions: [String] = [],
        actions: [GeneratedMeetingAction] = []
    ) {
        self.summary = summary
        self.decisions = decisions
        self.unresolvedQuestions = unresolvedQuestions
        self.actions = actions
    }
}

/// Hierarchical, evidence-backed digest generation over the shared on-device
/// seam (meeting recorder Task 7, BAK-299): chunk to the runtime context
/// budget → one fresh generation per chunk → reduce partial digests → strict
/// evidence validation. A proposal without a real transcript segment behind
/// it never survives.
public struct MeetingDigestService {
    /// Headroom reserved out of the model's context window for the
    /// guided-generation structured output and the chunk prompt's date
    /// preamble — the transcript budget is whatever context is left after
    /// the real instructions size and this reserve (BAK-328).
    static let outputReserve = 1024

    private let service: any OnDeviceGenerating
    private let calendar: Calendar
    private let locale: Locale
    private let promptBand: PromptBand
    private let loadPrompt: @Sendable (String) -> String?
    private let tokenCount: @Sendable (String) -> Int

    public init(
        service: any OnDeviceGenerating,
        calendar: Calendar,
        locale: Locale = .current,
        promptBand: PromptBand = PromptCatalog.currentBand,
        loadPrompt: @escaping @Sendable (String) -> String?,
        tokenCount: @escaping @Sendable (String) -> Int
    ) {
        self.service = service
        self.calendar = calendar
        self.locale = locale
        self.promptBand = promptBand
        self.loadPrompt = loadPrompt
        self.tokenCount = tokenCount
    }

    public func digest(
        segments: [VoiceTranscriptSegment],
        now: Date
    ) async -> Result<MeetingDigest, MeetingDigestFailure> {
        guard let resource = PromptCatalog.bestResource(
                feature: "meeting-digest", band: promptBand,
                isAvailable: { loadPrompt($0) != nil }),
              let instructions = loadPrompt(resource) else {
            return .failure(.missingPrompt)
        }
        let capabilities: LocalModelCapabilities
        switch await service.capabilities(locale: locale) {
        case .failure(let failure): return .failure(.model(failure))
        case .success(let value): capabilities = value
        }

        // The transcript gets whatever context is left after the real
        // instructions size and the output reserve — not a flat half-context
        // guess, which ignored how big the instructions actually are.
        let budget = max(256, capabilities.contextSize - tokenCount(instructions) - Self.outputReserve)
        let chunks = MeetingDigestChunker.chunks(
            segments: segments, budgetTokens: budget, tokenCount: tokenCount)

        // Map: one fresh generation per chunk.
        var partials: [GeneratedMeetingDigest] = []
        for chunk in chunks {
            switch await generate(
                instructions: instructions,
                prompt: Self.chunkPrompt(chunk, now: now, calendar: calendar)
            ) {
            case .success(let partial): partials.append(partial)
            case .failure(let failure): return .failure(failure)
            }
        }

        // Reduce: partial digests are tiny relative to the transcript, so a
        // single reduction pass combines them.
        let combined: GeneratedMeetingDigest
        if partials.isEmpty {
            combined = GeneratedMeetingDigest(summary: "")
        } else if partials.count == 1 {
            combined = partials[0]
        } else {
            switch await generate(
                instructions: instructions,
                prompt: Self.reductionPrompt(partials, now: now, calendar: calendar)
            ) {
            case .success(let reduced): combined = reduced
            case .failure(let failure): return .failure(failure)
            }
        }

        // Evidence validation: a proposal survives only with at least one
        // REAL transcript segment behind it; ghost ids are filtered out.
        let validIDs = Set(segments.map { MeetingTranscriptMerge.persistentID(for: $0) })
        let actions: [MeetingDigest.Action] = combined.actions.compactMap { action in
            let evidence = action.evidenceSegmentIDs.filter(validIDs.contains)
            guard !evidence.isEmpty,
                  let title = VoiceTaskDrafting.validatedTitle(action.title) else { return nil }
            let owner = action.owner.flatMap {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            return MeetingDigest.Action(
                title: title,
                owner: owner,
                due: VoiceTaskDrafting.scheduledDate(
                    fromISO8601: action.dueISO8601, calendar: calendar),
                evidenceSegmentIDs: evidence)
        }

        return .success(MeetingDigest(
            summary: combined.summary,
            decisions: combined.decisions,
            unresolvedQuestions: combined.unresolvedQuestions,
            actions: actions,
            promptVersion: PromptCatalog.promptVersion,
            osBuild: capabilities.osBuild))
    }

    // MARK: - Generation

    private func generate(
        instructions: String, prompt: String
    ) async -> Result<GeneratedMeetingDigest, MeetingDigestFailure> {
        do {
            return .success(try await service.generate(
                GeneratedMeetingDigest.self, instructions: instructions, prompt: prompt))
        } catch let failure as LocalModelFailure {
            return .failure(.model(failure))
        } catch {
            return .failure(.model(.unavailable(error.localizedDescription)))
        }
    }

    // MARK: - Prompt assembly

    static func chunkPrompt(
        _ chunk: [VoiceTranscriptSegment], now: Date, calendar: Calendar
    ) -> String {
        let lines = chunk.map(MeetingDigestChunker.renderedLine(for:))
        return """
        Today is \(dayStamp(now: now, calendar: calendar)) (timezone \(calendar.timeZone.identifier)).

        Transcript segments (cite ids EXACTLY as given):
        \(lines.joined(separator: "\n"))
        """
    }

    static func reductionPrompt(
        _ partials: [GeneratedMeetingDigest], now: Date, calendar: Calendar
    ) -> String {
        let rendered = partials.enumerated().map { index, partial in
            let actions = partial.actions.map {
                "- \($0.title) [evidence: \($0.evidenceSegmentIDs.joined(separator: ", "))]"
            }
            return """
            Part \(index + 1):
            Summary: \(partial.summary)
            Decisions: \(partial.decisions.joined(separator: "; "))
            Unresolved: \(partial.unresolvedQuestions.joined(separator: "; "))
            Actions:
            \(actions.joined(separator: "\n"))
            """
        }
        return """
        Today is \(dayStamp(now: now, calendar: calendar)) (timezone \(calendar.timeZone.identifier)).

        These are partial digests of consecutive parts of ONE meeting. Merge
        them into a single digest. Keep every action's evidenceSegmentIDs
        VERBATIM — never invent or alter ids.

        \(rendered.joined(separator: "\n\n"))
        """
    }

    private static func dayStamp(now: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        guard let y = comps.year, let m = comps.month, let d = comps.day,
              let weekday = comps.weekday else { return "" }
        let name = calendar.weekdaySymbols[weekday - 1]
        return String(format: "%@ %04d-%02d-%02d", name, y, m, d)
    }
}
#endif
