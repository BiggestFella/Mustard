import XCTest
import Foundation
import FoundationModels
@testable import MustardKit

/// On-device language service (Voice Core Task 5). The Foundation Models
/// edge (`SystemLanguageModel`, `LanguageModelSession`) stays behind injected
/// probe/session seams; every decision — prompt-band selection, availability
/// gating, context-overflow mapping, bounded/idempotent prewarming, session
/// reuse — is pinned here deterministically.
final class OnDeviceLanguageServiceTests: XCTestCase {

    // MARK: - Prompt bands (pure)

    func test_band_pinsEveryOSReleaseBand() {
        XCTAssertEqual(PromptCatalog.band(majorVersion: 26, minorVersion: 0), .macOS26)
        XCTAssertEqual(PromptCatalog.band(majorVersion: 26, minorVersion: 3), .macOS26)
        XCTAssertEqual(PromptCatalog.band(majorVersion: 26, minorVersion: 4), .macOS26_4)
        XCTAssertEqual(PromptCatalog.band(majorVersion: 26, minorVersion: 9), .macOS26_4)
        XCTAssertEqual(PromptCatalog.band(majorVersion: 27, minorVersion: 0), .macOS27)
        XCTAssertEqual(PromptCatalog.band(majorVersion: 28, minorVersion: 1), .macOS27)
    }

    func test_band_floorsBelowSupportedRange() {
        XCTAssertEqual(PromptCatalog.band(majorVersion: 25, minorVersion: 9), .macOS26,
                       "Anything below the framework floor pins to the base band.")
    }

    func test_resourceName_joinsFeatureAndBandSuffix() {
        XCTAssertEqual(PromptCatalog.resourceName(feature: "voice-task", band: .macOS27),
                       "voice-task-27")
        XCTAssertEqual(PromptCatalog.resourceName(feature: "voice-task", band: .macOS26_4),
                       "voice-task-26.4")
        XCTAssertEqual(PromptCatalog.resourceName(feature: "meeting-digest", band: .macOS26),
                       "meeting-digest-26")
    }

    func test_bestResource_fallsBackToNearestLowerBand() {
        let available: Set<String> = ["voice-task-26"]

        XCTAssertEqual(
            PromptCatalog.bestResource(feature: "voice-task", band: .macOS27) { available.contains($0) },
            "voice-task-26",
            "A missing band-specific prompt falls back to the nearest lower band, never upward.")
    }

    func test_bestResource_prefersExactBand_andReturnsNilWhenNothingExists() {
        let available: Set<String> = ["voice-task-26", "voice-task-27"]

        XCTAssertEqual(
            PromptCatalog.bestResource(feature: "voice-task", band: .macOS27) { available.contains($0) },
            "voice-task-27")
        XCTAssertNil(
            PromptCatalog.bestResource(feature: "unknown", band: .macOS27) { available.contains($0) })
    }

    // MARK: - Availability gating (pure)

    private static func probe(
        state: LocalModelProbe.State,
        supportsLocale: Bool = true,
        contextSize: Int = 4096
    ) -> LocalModelProbe {
        LocalModelProbe(state: state, supportsLocale: supportsLocale, contextSize: contextSize)
    }

    func test_capabilities_disabled_mapsToAppleIntelligenceDisabled() {
        let result = LocalModelPolicy.capabilities(
            probe: Self.probe(state: .disabled), band: .macOS27, osBuild: "27A5194q")
        XCTAssertEqual(result, .failure(.appleIntelligenceDisabled))
    }

    func test_capabilities_ineligible_mapsToDeviceNotEligible() {
        let result = LocalModelPolicy.capabilities(
            probe: Self.probe(state: .ineligible), band: .macOS27, osBuild: "27A5194q")
        XCTAssertEqual(result, .failure(.deviceNotEligible))
    }

    func test_capabilities_modelNotReady_mapsToModelNotReady() {
        let result = LocalModelPolicy.capabilities(
            probe: Self.probe(state: .modelNotReady), band: .macOS27, osBuild: "27A5194q")
        XCTAssertEqual(result, .failure(.modelNotReady))
    }

    func test_capabilities_unsupportedLocale_evenWhenModelAvailable() {
        let result = LocalModelPolicy.capabilities(
            probe: Self.probe(state: .available, supportsLocale: false),
            band: .macOS27, osBuild: "27A5194q")
        XCTAssertEqual(result, .failure(.unsupportedLocale))
    }

    func test_capabilities_available_carriesContextSizeBandAndBuild() {
        let result = LocalModelPolicy.capabilities(
            probe: Self.probe(state: .available, contextSize: 8192),
            band: .macOS26_4, osBuild: "26E123")

        XCTAssertEqual(result, .success(LocalModelCapabilities(
            contextSize: 8192, promptBand: "26.4", osBuild: "26E123")))
    }

    // MARK: - Service seams

    /// Counts sessions the factory built and prewarm/respond traffic per
    /// session, and can throw a canned error from `respond`.
    @available(macOS 26.0, *)
    private final class StubSessionBox: @unchecked Sendable {
        var sessionsCreated = 0
        var prewarmCounts: [Int] = []
        var respondError: Error?
        var respondResult: (any Sendable)?
        var respondedPrompts: [String] = []
        var createdInstructions: [String?] = []
        private let lock = NSLock()

        func makeSession(_ instructions: String?) -> StubSession {
            lock.lock(); defer { lock.unlock() }
            createdInstructions.append(instructions)
            sessionsCreated += 1
            prewarmCounts.append(0)
            return StubSession(box: self, index: sessionsCreated - 1)
        }

        func recordPrewarm(index: Int) {
            lock.lock(); defer { lock.unlock() }
            prewarmCounts[index] += 1
        }

        func recordPrompt(_ prompt: String) {
            lock.lock(); defer { lock.unlock() }
            respondedPrompts.append(prompt)
        }
    }

    @available(macOS 26.0, *)
    private struct StubSession: LocalModelSessioning {
        let box: StubSessionBox
        let index: Int

        func prewarm(promptPrefix: String?) {
            box.recordPrewarm(index: index)
        }

        func respond<Output: Generable & Sendable>(
            prompt: String, type: Output.Type
        ) async throws -> Output {
            box.recordPrompt(prompt)
            if let error = box.respondError { throw error }
            guard let result = box.respondResult as? Output else {
                throw LocalModelFailure.unavailable("Stub had no canned result")
            }
            return result
        }
    }

    // MARK: - Capabilities through the actor

    func test_service_capabilities_usesInjectedProbeBandAndBuild() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let box = StubSessionBox()
        let service = OnDeviceLanguageService(
            probe: { _ in Self.probe(state: .available, contextSize: 12_000) },
            band: .macOS27,
            osBuild: "27A5194q",
            makeSession: { box.makeSession($0) })

        let result = await service.capabilities(locale: Locale(identifier: "en_AU"))

        XCTAssertEqual(result, .success(LocalModelCapabilities(
            contextSize: 12_000, promptBand: "27", osBuild: "27A5194q")))
    }

    // MARK: - Bounded, idempotent prewarming

    func test_prepareForLikelyUse_isIdempotent() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let box = StubSessionBox()
        let service = OnDeviceLanguageService(
            probe: { _ in Self.probe(state: .available) },
            band: .macOS27, osBuild: "27A5194q",
            makeSession: { box.makeSession($0) })

        await service.prepareForLikelyUse()
        await service.prepareForLikelyUse()
        await service.prepareForLikelyUse()

        XCTAssertEqual(box.sessionsCreated, 1,
                       "Repeated prepare calls must not rebuild the session.")
        XCTAssertEqual(box.prewarmCounts, [1],
                       "Repeated prepare calls must not re-prewarm.")
    }

    func test_releaseIdleResources_dropsSession_soNextPrepareRebuilds() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let box = StubSessionBox()
        let service = OnDeviceLanguageService(
            probe: { _ in Self.probe(state: .available) },
            band: .macOS27, osBuild: "27A5194q",
            makeSession: { box.makeSession($0) })

        await service.prepareForLikelyUse()
        await service.releaseIdleResources()
        await service.prepareForLikelyUse()

        XCTAssertEqual(box.sessionsCreated, 2)
        XCTAssertEqual(box.prewarmCounts, [1, 1])
    }

    // MARK: - Guided generation (one-shot sessions)

    func test_generate_returnsTypedOutput_andUsesAFreshSessionPerRequest() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let box = StubSessionBox()
        box.respondResult = GeneratedContent("structured")
        let service = OnDeviceLanguageService(
            probe: { _ in Self.probe(state: .available) },
            band: .macOS27, osBuild: "27A5194q",
            makeSession: { box.makeSession($0) })

        let first: GeneratedContent = try await service.generate(
            GeneratedContent.self, instructions: "Extract a task.", prompt: "buy milk")
        let second: GeneratedContent = try await service.generate(
            GeneratedContent.self, instructions: "Extract a task.", prompt: "call dentist")

        XCTAssertEqual(String(describing: first.kind), String(describing: GeneratedContent("structured").kind))
        XCTAssertEqual(String(describing: second.kind), String(describing: GeneratedContent("structured").kind))
        // Live sessions are stateful multi-turn transcripts: reusing one
        // across drafts accumulates context until every draft overflows.
        // Every generate() is one-shot on a fresh session.
        XCTAssertEqual(box.sessionsCreated, 2,
                       "Each draft must run in its own session — transcripts never accumulate.")
        XCTAssertEqual(box.respondedPrompts, ["buy milk", "call dentist"])
        XCTAssertEqual(box.createdInstructions, ["Extract a task.", "Extract a task."])
    }

    func test_generate_freshSessionCarriesTheRequestInstructions() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let box = StubSessionBox()
        box.respondResult = GeneratedContent("ok")
        let service = OnDeviceLanguageService(
            probe: { _ in Self.probe(state: .available) },
            band: .macOS27, osBuild: "27A5194q",
            makeSession: { box.makeSession($0) })

        _ = try await service.generate(
            GeneratedContent.self, instructions: "Draft a task.", prompt: "a")
        _ = try await service.generate(
            GeneratedContent.self, instructions: "Summarize a meeting.", prompt: "b")

        XCTAssertEqual(box.sessionsCreated, 2)
        XCTAssertEqual(box.createdInstructions, ["Draft a task.", "Summarize a meeting."])
    }

    // MARK: - Context overflow & framework error mapping

    func test_generate_mapsExceededContextWindow_toContextOverflow() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let box = StubSessionBox()
        box.respondError = LanguageModelSession.GenerationError.exceededContextWindowSize(
            .init(debugDescription: "too big"))
        let service = OnDeviceLanguageService(
            probe: { _ in Self.probe(state: .available) },
            band: .macOS27, osBuild: "27A5194q",
            makeSession: { box.makeSession($0) })

        do {
            _ = try await service.generate(
                GeneratedContent.self, instructions: "i", prompt: "p")
            XCTFail("Overflow must throw")
        } catch let failure as LocalModelFailure {
            XCTAssertEqual(failure, .contextOverflow)
        }
    }

    // A sibling case here used to pin the same mapping through macOS 27's
    // `LanguageModelError.contextSizeExceeded`. Apple removed that type in the
    // macOS 28 SDK (see `OnDeviceLanguageService.mappedFailure`), so it can no
    // longer be constructed to assert against — do not re-add it. The overflow
    // mapping itself stays covered by the `GenerationError` case above.

    func test_generate_mapsUnsupportedLanguage_toUnsupportedLocale() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let box = StubSessionBox()
        box.respondError = LanguageModelSession.GenerationError.unsupportedLanguageOrLocale(
            .init(debugDescription: "no Klingon"))
        let service = OnDeviceLanguageService(
            probe: { _ in Self.probe(state: .available) },
            band: .macOS27, osBuild: "27A5194q",
            makeSession: { box.makeSession($0) })

        do {
            _ = try await service.generate(
                GeneratedContent.self, instructions: "i", prompt: "p")
            XCTFail("Must throw")
        } catch let failure as LocalModelFailure {
            XCTAssertEqual(failure, .unsupportedLocale)
        }
    }

    func test_generate_rethrowsUnmappedErrorsUnchanged() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        struct OtherError: Error, Equatable {}
        let box = StubSessionBox()
        box.respondError = OtherError()
        let service = OnDeviceLanguageService(
            probe: { _ in Self.probe(state: .available) },
            band: .macOS27, osBuild: "27A5194q",
            makeSession: { box.makeSession($0) })

        do {
            _ = try await service.generate(
                GeneratedContent.self, instructions: "i", prompt: "p")
            XCTFail("Must throw")
        } catch is OtherError {
            // expected: unknown failures surface verbatim for retry policy upstream
        }
    }
}
