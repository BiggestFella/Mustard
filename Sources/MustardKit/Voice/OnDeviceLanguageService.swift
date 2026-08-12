import Foundation
import FoundationModels

/// On-device language service (Voice Core Task 5). A narrow adapter around
/// the Foundation Models framework: availability, locale support, and the
/// reported context budget gate every use; typed outputs come from guided
/// generation; and prompt selection follows the release band in
/// `PromptCatalog`. Language work never leaves the machine — when Apple
/// Intelligence is unavailable the caller gets a typed failure to retry
/// locally, never a network fallback.

// MARK: - Capabilities & failures (pure Foundation)

/// What the local model can do right now, stamped with the prompt band and
/// macOS build so generated results are traceable after OS/model updates
/// (Apple exposes no runtime model-version identifier).
public struct LocalModelCapabilities: Equatable, Sendable {
    public let contextSize: Int
    public let promptBand: String
    public let osBuild: String

    public init(contextSize: Int, promptBand: String, osBuild: String) {
        self.contextSize = contextSize
        self.promptBand = promptBand
        self.osBuild = osBuild
    }
}

/// Why local generation is not possible (or failed). Everything here is
/// retryable-local for the caller; none of these fall through to a network
/// model.
public enum LocalModelFailure: Error, Equatable, Sendable {
    /// Apple Intelligence is switched off in System Settings.
    case appleIntelligenceDisabled
    /// This Mac cannot run the on-device model at all.
    case deviceNotEligible
    /// The model exists but is still downloading/initializing.
    case modelNotReady
    /// The model does not support the requested locale.
    case unsupportedLocale
    /// The instructions + prompt exceeded the reported context budget —
    /// the caller should split the work into separate sessions.
    case contextOverflow
    /// Anything else, with a human-readable reason.
    case unavailable(String)
}

/// A framework-independent snapshot of `SystemLanguageModel` state, so the
/// availability decision is pure and deterministic in tests.
public struct LocalModelProbe: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case available
        case disabled
        case ineligible
        case modelNotReady
    }

    public let state: State
    public let supportsLocale: Bool
    public let contextSize: Int

    public init(state: State, supportsLocale: Bool, contextSize: Int) {
        self.state = state
        self.supportsLocale = supportsLocale
        self.contextSize = contextSize
    }
}

/// The availability gate: model-state failures first, then locale support,
/// then capabilities stamped with band + build.
public enum LocalModelPolicy {
    public static func capabilities(
        probe: LocalModelProbe,
        band: PromptBand,
        osBuild: String
    ) -> Result<LocalModelCapabilities, LocalModelFailure> {
        switch probe.state {
        case .disabled: return .failure(.appleIntelligenceDisabled)
        case .ineligible: return .failure(.deviceNotEligible)
        case .modelNotReady: return .failure(.modelNotReady)
        case .available: break
        }
        guard probe.supportsLocale else { return .failure(.unsupportedLocale) }
        return .success(LocalModelCapabilities(
            contextSize: probe.contextSize,
            promptBand: band.rawValue,
            osBuild: osBuild))
    }
}

// MARK: - Service contracts

/// The shared generation seam every voice feature consumes. Gated on
/// macOS 26 because `Generable` (guided generation) is.
@available(macOS 26.0, *)
public protocol OnDeviceGenerating: Sendable {
    func capabilities(locale: Locale) async -> Result<LocalModelCapabilities, LocalModelFailure>
    func generate<Output: Generable & Sendable>(
        _ type: Output.Type, instructions: String, prompt: String
    ) async throws -> Output
}

/// One live model conversation. `OnDeviceLanguageService` owns instances of
/// this seam; tests inject stubs, the live conformance wraps
/// `LanguageModelSession`.
@available(macOS 26.0, *)
public protocol LocalModelSessioning: Sendable {
    func prewarm(promptPrefix: String?)
    func respond<Output: Generable & Sendable>(
        prompt: String, type: Output.Type
    ) async throws -> Output
}

// MARK: - Service

/// The `OnDeviceGenerating` actor. Owns at most one live session (keyed by
/// its instructions), prewarns it only when asked — `prepareForLikelyUse()`
/// is idempotent — and releases it when idle, so the model's memory cost is
/// bounded and never paid at launch.
@available(macOS 26.0, *)
public actor OnDeviceLanguageService: OnDeviceGenerating {
    public typealias Probe = @Sendable (Locale) async -> LocalModelProbe
    public typealias SessionFactory = @Sendable (String?) -> any LocalModelSessioning

    private let probe: Probe
    private let band: PromptBand
    private let osBuild: String
    private let makeSession: SessionFactory

    private var activeInstructions: String??
    private var activeSession: (any LocalModelSessioning)?
    private var hasPrewarmed = false

    public init(
        probe: @escaping Probe,
        band: PromptBand = PromptCatalog.currentBand,
        osBuild: String,
        makeSession: @escaping SessionFactory
    ) {
        self.probe = probe
        self.band = band
        self.osBuild = osBuild
        self.makeSession = makeSession
    }

    public func capabilities(locale: Locale) async -> Result<LocalModelCapabilities, LocalModelFailure> {
        LocalModelPolicy.capabilities(
            probe: await probe(locale), band: band, osBuild: osBuild)
    }

    public func generate<Output: Generable & Sendable>(
        _ type: Output.Type, instructions: String, prompt: String
    ) async throws -> Output {
        // One-shot: a live session is a stateful multi-turn transcript, so
        // reusing one across drafts accumulates context until every request
        // overflows (and concurrent drafts would interleave turns). Each
        // generate gets a fresh session; prewarming still keeps the model
        // itself resident via `prepareForLikelyUse`.
        let session = makeSession(instructions)
        do {
            return try await session.respond(prompt: prompt, type: type)
        } catch {
            if let mapped = Self.mappedFailure(error) { throw mapped }
            throw error
        }
    }

    /// Prewarms the (base) session once. Safe to call repeatedly — the
    /// session is built and prewarmed at most once until it is released or
    /// rotated to different instructions.
    public func prepareForLikelyUse() {
        let session = session(for: nil)
        guard !hasPrewarmed else { return }
        hasPrewarmed = true
        session.prewarm(promptPrefix: nil)
    }

    /// Drops the live session so the model's resources can be reclaimed.
    /// The next use rebuilds (and may re-prewarm) from scratch.
    public func releaseIdleResources() {
        activeSession = nil
        activeInstructions = nil
        hasPrewarmed = false
    }

    private func session(for instructions: String?) -> any LocalModelSessioning {
        if let activeSession, activeInstructions == .some(instructions) {
            return activeSession
        }
        let session = makeSession(instructions)
        activeSession = session
        activeInstructions = .some(instructions)
        hasPrewarmed = false
        return session
    }

    /// Maps Foundation Models errors to Mustard failures; nil means the
    /// error is unknown and must surface verbatim for the retry policy.
    ///
    /// This used to carry a second `macOS 27` branch over `LanguageModelError`
    /// (`.contextSizeExceeded` / `.unsupportedLanguageOrLocale`). Apple removed
    /// that type in the macOS 28 SDK and consolidated back onto
    /// `LanguageModelSession.GenerationError`, which is what remains here — and
    /// which already mapped both of those cases, so nothing this function could
    /// classify became unclassifiable. The type cannot be named at all against a
    /// current SDK, so there is no conditional way to keep the branch; if a
    /// macOS 27 runtime still throws the old type it now falls through to nil
    /// and surfaces verbatim, which is the documented behaviour for an error
    /// this function does not recognise.
    static func mappedFailure(_ error: Error) -> LocalModelFailure? {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize: return .contextOverflow
            case .unsupportedLanguageOrLocale: return .unsupportedLocale
            case .assetsUnavailable: return .modelNotReady
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Live wiring

/// Wraps a real `LanguageModelSession` behind the sessioning seam.
@available(macOS 26.0, *)
struct LiveLocalModelSession: LocalModelSessioning {
    let session: LanguageModelSession

    func prewarm(promptPrefix: String?) {
        session.prewarm(promptPrefix: promptPrefix.map { Prompt($0) })
    }

    func respond<Output: Generable & Sendable>(
        prompt: String, type: Output.Type
    ) async throws -> Output {
        try await session.respond(to: Prompt(prompt), generating: type).content
    }
}

@available(macOS 26.0, *)
extension OnDeviceLanguageService {
    /// The production service: probes `SystemLanguageModel.default` and
    /// builds real guided-generation sessions.
    public static func live() -> OnDeviceLanguageService {
        OnDeviceLanguageService(
            probe: { locale in Self.liveProbe(locale: locale) },
            band: PromptCatalog.currentBand,
            osBuild: ProcessInfo.processInfo.operatingSystemVersionString,
            makeSession: { instructions in
                LiveLocalModelSession(
                    session: LanguageModelSession(instructions: instructions))
            })
    }

    private static func liveProbe(locale: Locale) -> LocalModelProbe {
        let model = SystemLanguageModel.default
        let state: LocalModelProbe.State
        switch model.availability {
        case .available:
            state = .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: state = .disabled
            case .deviceNotEligible: state = .ineligible
            case .modelNotReady: state = .modelNotReady
            @unknown default: state = .modelNotReady
            }
        }
        return LocalModelProbe(
            state: state,
            supportsLocale: model.supportsLocale(locale),
            contextSize: model.contextSize)
    }
}
