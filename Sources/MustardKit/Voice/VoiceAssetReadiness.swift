import Foundation

/// Speech asset readiness (Voice Core). Resolves the caller's locale to a
/// recognizer-supported equivalent, then ensures the on-device speech assets
/// for it are installed — a no-op when they already are. The live closures
/// (`SpeechTranscriber.supportedLocale(equivalentTo:)` and
/// `AssetInventory.assetInstallationRequest(supporting:)`) are macOS-27-only
/// and wired up separately; injecting them keeps every transition pure and
/// unit-tested without downloading anything.
public struct VoiceAssetReadiness {
    /// Maps a requested locale to the recognizer-supported equivalent, or
    /// `nil` when transcription cannot support it at all.
    public var resolveLocale: @Sendable (Locale) async -> Locale?
    /// Installs (or verifies) the speech assets for a supported locale.
    /// Throws `CancellationError` when the download is cancelled.
    public var installAssets: @Sendable (Locale) async throws -> Void

    public init(
        resolveLocale: @escaping @Sendable (Locale) async -> Locale?,
        installAssets: @escaping @Sendable (Locale) async throws -> Void
    ) {
        self.resolveLocale = resolveLocale
        self.installAssets = installAssets
    }

    public func prepare(locale: Locale) async -> VoiceReadiness {
        guard let supported = await resolveLocale(locale) else {
            return .unsupportedLocale
        }
        do {
            try await installAssets(supported)
            return .ready
        } catch is CancellationError {
            return .unavailable("Asset installation cancelled")
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
