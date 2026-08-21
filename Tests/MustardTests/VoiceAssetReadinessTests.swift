import XCTest
@testable import MustardKit

/// Speech asset readiness state machine (Voice Core Task 3). The live
/// closures (SpeechTranscriber locale resolution, AssetInventory install
/// requests) are macOS-27-only and injected; every transition — ready,
/// download-needed, unsupported locale, download error, cancelled download —
/// is pinned here against deterministic stubs.
final class VoiceAssetReadinessTests: XCTestCase {

    /// Records the locales `installAssets` is invoked with, across
    /// concurrency-safe closure captures.
    private actor InstallRecorder {
        private(set) var locales: [Locale] = []
        func record(_ locale: Locale) { locales.append(locale) }
    }

    private let enAU = Locale(identifier: "en_AU")
    private let enUS = Locale(identifier: "en_US")

    private enum StubError: Error, LocalizedError {
        case downloadFailed
        var errorDescription: String? { "The asset download failed." }
    }

    // MARK: - Ready (assets already installed — install is a no-op)

    func test_ready_whenLocaleSupportedAndInstallSucceedsImmediately() async {
        let recorder = InstallRecorder()
        let readiness = VoiceAssetReadiness(
            resolveLocale: { locale in locale },
            installAssets: { locale in await recorder.record(locale) })

        let result = await readiness.prepare(locale: enAU)

        XCTAssertEqual(result, .ready)
        let installed = await recorder.locales
        XCTAssertEqual(installed, [enAU])
    }

    // MARK: - Download needed (install runs for the *resolved* locale, then ready)

    func test_downloadNeeded_installsResolvedEquivalentLocale_thenReady() async {
        let recorder = InstallRecorder()
        let resolved = enUS
        let readiness = VoiceAssetReadiness(
            resolveLocale: { _ in resolved },
            installAssets: { locale in await recorder.record(locale) })

        let result = await readiness.prepare(locale: enAU)

        XCTAssertEqual(result, .ready)
        let installed = await recorder.locales
        XCTAssertEqual(installed, [enUS],
                       "The download must target the recognizer's supported equivalent locale, not the raw request.")
    }

    // MARK: - Unsupported locale

    func test_unsupportedLocale_whenResolutionReturnsNil_andNeverInstalls() async {
        let recorder = InstallRecorder()
        let readiness = VoiceAssetReadiness(
            resolveLocale: { _ in nil },
            installAssets: { locale in await recorder.record(locale) })

        let result = await readiness.prepare(locale: Locale(identifier: "xx_XX"))

        XCTAssertEqual(result, .unsupportedLocale)
        let installed = await recorder.locales
        XCTAssertTrue(installed.isEmpty,
                      "No install attempt may be made for an unsupported locale.")
    }

    // MARK: - Download error

    func test_downloadError_surfacesLocalizedReasonAsUnavailable() async {
        let readiness = VoiceAssetReadiness(
            resolveLocale: { locale in locale },
            installAssets: { _ in throw StubError.downloadFailed })

        let result = await readiness.prepare(locale: enAU)

        XCTAssertEqual(result, .unavailable(StubError.downloadFailed.localizedDescription))
    }

    // MARK: - Cancelled download

    func test_cancelledDownload_mapsToUnavailableWithCancellationReason() async {
        let readiness = VoiceAssetReadiness(
            resolveLocale: { locale in locale },
            installAssets: { _ in throw CancellationError() })

        let result = await readiness.prepare(locale: enAU)

        XCTAssertEqual(result, .unavailable("Asset installation cancelled"))
    }

    // MARK: - Reservation (Talkify review, item 3)

    /// macOS may evict on-device speech assets to reclaim disk. Reserving the
    /// locale asks it not to, which is the difference between a fast next
    /// dictation and one that silently re-downloads a model first.

    private actor ReserveRecorder {
        private(set) var locales: [Locale] = []
        func record(_ locale: Locale) { locales.append(locale) }
    }

    func test_reserve_resolvesTheLocaleBeforeReservingIt() async {
        let recorder = ReserveRecorder()
        let readiness = VoiceAssetReadiness(
            resolveLocale: { _ in self.enUS },   // en_AU resolves to en_US
            installAssets: { _ in },
            reserveLocale: { locale in
                await recorder.record(locale)
                return true
            })

        let result = await readiness.reserve(locale: enAU)

        XCTAssertEqual(result, .reserved)
        let reserved = await recorder.locales
        XCTAssertEqual(
            reserved, [enUS],
            "the supported equivalent must be reserved, not the raw request")
    }

    func test_reserve_reportsUnsupportedWithoutCallingTheReservation() async {
        let recorder = ReserveRecorder()
        let readiness = VoiceAssetReadiness(
            resolveLocale: { _ in nil },
            installAssets: { _ in },
            reserveLocale: { locale in
                await recorder.record(locale)
                return true
            })

        let result = await readiness.reserve(locale: enAU)

        XCTAssertEqual(result, .unsupportedLocale)
        let reserved = await recorder.locales
        XCTAssertTrue(reserved.isEmpty)
    }

    /// The reservation pool is shared across apps and device-capped. Being
    /// refused a slot is normal and must never be treated as a failure —
    /// dictation still works, it is just evictable.
    func test_reserve_reportsRefusalWhenTheSystemDeclines() async {
        let readiness = VoiceAssetReadiness(
            resolveLocale: { locale in locale },
            installAssets: { _ in },
            reserveLocale: { _ in false })

        let result = await readiness.reserve(locale: enAU)

        XCTAssertEqual(result, .refused)
    }

    func test_reserve_surfacesAThrownReservationAsFailedWithItsReason() async {
        let readiness = VoiceAssetReadiness(
            resolveLocale: { locale in locale },
            installAssets: { _ in },
            reserveLocale: { _ in throw StubError.downloadFailed })

        let result = await readiness.reserve(locale: enAU)

        XCTAssertEqual(result, .failed(StubError.downloadFailed.localizedDescription))
    }

    /// Callers that predate reservation keep compiling and reserve nothing,
    /// rather than silently claiming a slot they never asked for.
    func test_reserve_defaultsToRefusedWhenNoReservationClosureIsSupplied() async {
        let readiness = VoiceAssetReadiness(
            resolveLocale: { locale in locale },
            installAssets: { _ in })

        let result = await readiness.reserve(locale: enAU)

        XCTAssertEqual(result, .refused)
    }
}
