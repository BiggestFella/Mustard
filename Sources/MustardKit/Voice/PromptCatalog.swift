import Foundation

/// Prompt release bands (Voice Core Task 5). Apple exposes no runtime model
/// version, so Mustard follows the availability-check guidance: prompts are
/// tuned per OS release band and selected with `#available`, and each
/// generated result records the prompt version plus the macOS build so
/// output quality can be traced after an OS or model update.
public enum PromptBand: String, CaseIterable, Comparable, Sendable {
    /// macOS 26.0–26.3 — the original Apple Intelligence release.
    case macOS26 = "26"
    /// macOS 26.4+ — the mid-cycle model refresh.
    case macOS26_4 = "26.4"
    /// macOS 27.0+ — the current model generation.
    case macOS27 = "27"

    private var order: Int {
        switch self {
        case .macOS26: return 0
        case .macOS26_4: return 1
        case .macOS27: return 2
        }
    }

    public static func < (lhs: PromptBand, rhs: PromptBand) -> Bool {
        lhs.order < rhs.order
    }
}

/// Pure band selection and prompt-resource naming. Feature prompts live as
/// band-suffixed resources (e.g. `voice-task-27.txt`); the catalog decides
/// which band applies and falls back to the nearest *lower* band when a
/// band-specific prompt does not exist — never upward, so a prompt written
/// for a newer model is never fed to an older one.
public enum PromptCatalog {
    /// Mustard's own prompt revision, recorded alongside generated results.
    public static let promptVersion = "voice-core-1"

    /// Deterministic band for an OS version — the injectable core the live
    /// `currentBand` delegates to.
    public static func band(majorVersion: Int, minorVersion: Int) -> PromptBand {
        if majorVersion >= 27 { return .macOS27 }
        if majorVersion == 26, minorVersion >= 4 { return .macOS26_4 }
        return .macOS26
    }

    /// The band for the running OS, per Apple's `#available` guidance.
    public static var currentBand: PromptBand {
        if #available(macOS 27.0, *) { return .macOS27 }
        if #available(macOS 26.4, *) { return .macOS26_4 }
        return .macOS26
    }

    /// `<feature>-<band>` — the base name of the prompt resource.
    public static func resourceName(feature: String, band: PromptBand) -> String {
        "\(feature)-\(band.rawValue)"
    }

    /// The best available prompt resource for a band: the exact band when
    /// present, else the nearest lower band, else nil.
    public static func bestResource(
        feature: String,
        band: PromptBand,
        isAvailable: (String) -> Bool
    ) -> String? {
        for candidate in PromptBand.allCases.filter({ $0 <= band }).sorted(by: >) {
            let name = resourceName(feature: feature, band: candidate)
            if isAvailable(name) { return name }
        }
        return nil
    }
}
