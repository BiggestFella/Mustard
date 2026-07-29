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
}
