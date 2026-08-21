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
    /// Asks the system to keep this locale's assets on disk. Returns whether
    /// the slot was granted. Defaults to granting nothing, so a caller that
    /// does not opt in never quietly claims one.
    public var reserveLocale: @Sendable (Locale) async throws -> Bool

    public init(
        resolveLocale: @escaping @Sendable (Locale) async -> Locale?,
        installAssets: @escaping @Sendable (Locale) async throws -> Void,
        reserveLocale: @escaping @Sendable (Locale) async throws -> Bool = { _ in false }
    ) {
        self.resolveLocale = resolveLocale
        self.installAssets = installAssets
        self.reserveLocale = reserveLocale
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

    /// How a reservation attempt ended. None of these outcomes block voice:
    /// an unreserved locale still transcribes, it is just evictable.
    public enum Reservation: Equatable, Sendable {
        /// The system is holding this locale's assets for us.
        case reserved
        /// Declined — the per-device reservation pool is shared with other
        /// apps and capped. Expected, not an error.
        case refused
        /// The recognizer cannot support this locale at all.
        case unsupportedLocale
        /// The reservation call itself failed, with its reason.
        case failed(String)
    }

    /// Asks macOS to keep this locale's on-device speech assets installed
    /// (Talkify review, item 3).
    ///
    /// Without a reservation the system may evict the model to reclaim disk,
    /// and the next dictation pays for a silent re-download before it can
    /// transcribe a word. Reserving is best-effort by design: the pool is
    /// device-capped and shared with every other app that wants a slot, so a
    /// refusal is a normal outcome and never blocks capture.
    ///
    /// Reserves the recognizer-supported *equivalent* of the requested locale
    /// — the same locale `prepare` installs — so the reservation and the
    /// installed assets can never refer to different models.
    public func reserve(locale: Locale) async -> Reservation {
        guard let supported = await resolveLocale(locale) else {
            return .unsupportedLocale
        }
        do {
            let granted = try await reserveLocale(supported)
            return granted ? .reserved : .refused
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
