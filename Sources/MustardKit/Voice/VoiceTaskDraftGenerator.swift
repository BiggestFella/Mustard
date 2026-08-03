// Voice-task drafting is a Mac feature: the iOS companion compiles MustardKit
// sources directly at an iOS 17 floor where FoundationModels (and @Generable)
// do not exist, so this whole unit is macOS-only.
#if os(macOS)
import Foundation
import FoundationModels

/// The guided-generation output for voice-task drafting (Capture Task 2).
/// Deliberately all-strings: everything passes through `VoiceTaskDrafting`'s
/// deterministic validation before it can touch a draft — the model's output
/// is never trusted as-is.
@Generable
public struct GeneratedVoiceTaskDraft: Sendable {
    public var title: String
    public var notes: String?
    public var areaName: String?
    public var scheduledISO8601: String?
    public var urls: [String]

    public init(
        title: String,
        notes: String? = nil,
        areaName: String? = nil,
        scheduledISO8601: String? = nil,
        urls: [String] = []
    ) {
        self.title = title
        self.notes = notes
        self.areaName = areaName
        self.scheduledISO8601 = scheduledISO8601
        self.urls = urls
    }
}

/// Why drafting failed. Every case is retryable-local: the captured task stays
/// raw and editable, and nothing was mutated.
public enum VoiceTaskDraftFailure: Error, Equatable, Sendable {
    /// The on-device model was unavailable or generation failed.
    case model(LocalModelFailure)
    /// The model returned structured output that failed validation.
    case invalidOutput(String)
    /// No prompt resource exists for the release band (configuration error).
    case missingPrompt
}

/// On-device voice-task drafting over the shared generation seam.
public struct VoiceTaskDraftGenerator: Sendable {
    private let service: any OnDeviceGenerating
    private let calendar: Calendar
    private let locale: Locale
    private let promptBand: PromptBand
    private let loadPrompt: @Sendable (String) -> String?

    public init(
        service: any OnDeviceGenerating,
        calendar: Calendar,
        locale: Locale = .current,
        promptBand: PromptBand = PromptCatalog.currentBand,
        loadPrompt: @escaping @Sendable (String) -> String?
    ) {
        self.service = service
        self.calendar = calendar
        self.locale = locale
        self.promptBand = promptBand
        self.loadPrompt = loadPrompt
    }

    public func draft(
        transcript: String,
        allowedAreas: [String],
        now: Date
    ) async -> Result<VoiceTaskDraft, VoiceTaskDraftFailure> {
        // Prompt resource first (cheap, deterministic), then the availability
        // gate — the model is never asked to generate unless both hold.
        guard let resource = PromptCatalog.bestResource(
                feature: "voice-task", band: promptBand,
                isAvailable: { loadPrompt($0) != nil }),
              let instructions = loadPrompt(resource) else {
            return .failure(.missingPrompt)
        }
        if case .failure(let failure) = await service.capabilities(locale: locale) {
            return .failure(.model(failure))
        }

        let generated: GeneratedVoiceTaskDraft
        do {
            generated = try await service.generate(
                GeneratedVoiceTaskDraft.self,
                instructions: instructions,
                prompt: Self.prompt(
                    transcript: transcript, allowedAreas: allowedAreas,
                    now: now, calendar: calendar))
        } catch let failure as LocalModelFailure {
            return .failure(.model(failure))
        } catch {
            return .failure(.model(.unavailable(error.localizedDescription)))
        }

        guard let draft = VoiceTaskDrafting.validated(
            title: generated.title,
            notes: generated.notes,
            areaName: generated.areaName,
            scheduledISO8601: generated.scheduledISO8601,
            urls: generated.urls,
            allowedAreas: allowedAreas,
            calendar: calendar
        ) else {
            return .failure(.invalidOutput("The model returned no usable title"))
        }
        return .success(draft)
    }

    // MARK: - Prompt assembly

    /// The per-request prompt: pinned "today" + timezone (so relative spoken
    /// dates resolve deterministically), the allowed areas verbatim, and the
    /// raw transcript, in the house date-grounding style.
    static func prompt(
        transcript: String, allowedAreas: [String], now: Date, calendar: Calendar
    ) -> String {
        let areaLine = allowedAreas.isEmpty
            ? "There are no known areas — always omit areaName."
            : "Known areas (use EXACTLY one of these strings, or omit): " +
              allowedAreas.map { "\"\($0)\"" }.joined(separator: ", ") + "."
        return """
        Today is \(dayStamp(now: now, calendar: calendar)) (timezone \(calendar.timeZone.identifier)).
        \(areaLine)

        Raw transcript of the spoken task:
        \(transcript)
        """
    }

    private static func dayStamp(now: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        guard let y = comps.year, let m = comps.month, let d = comps.day,
              let weekday = comps.weekday else { return "" }
        let name = calendar.weekdaySymbols[weekday - 1]
        return String(format: "%@ %04d-%02d-%02d", name, y, m, d)
    }

    // MARK: - Bundled prompts

    /// Loads a band-suffixed prompt resource from `Voice/Prompts` — the
    /// production `loadPrompt`. Mirrors `AgentTurnContract`'s lookup: the
    /// processed subdirectory first, then the bundle root; `Bundle.module`
    /// exists only under SwiftPM (the iOS companion target compiles sources
    /// directly and never runs voice drafting).
    public static func bundledPrompt(_ name: String) -> String? {
        // The PACKAGED app must be tried first. `Bundle.module` resolves the
        // SwiftPM build-directory copy, which does not exist inside
        // Mustard.app — the same trap AgentTurnContract already works around.
        // Getting this wrong is silent: drafting just fails and every capture
        // stays raw.
        let packaged = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("Mustard_MustardKit.bundle", isDirectory: true) }
            .flatMap(Bundle.init(url:))
        if let url = packaged?.url(forResource: name, withExtension: "txt", subdirectory: "Prompts")
            ?? packaged?.url(forResource: name, withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Prompts")
            ?? Bundle.module.url(forResource: name, withExtension: "txt")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        #else
        return nil
        #endif
    }
}
#endif
