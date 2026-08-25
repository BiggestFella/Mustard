import Foundation

/// User-facing Gmail source configuration. Non-secret → UserDefaults as a
/// Codable blob (the `SourceSettingsStore` pattern; ADR-0001 defers a SwiftData
/// settings model). Tokens/credentials live in the Keychain, never here.
public struct GmailSettings: Codable, Equatable {
    public var enabled: Bool
    /// Gmail label id to poll (system ids like "INBOX" or user "Label_…" ids).
    public var labelId: String
    /// Extra Gmail search query (same syntax as the search bar); bounds the window.
    public var query: String
    public var pollIntervalMinutes: Double

    public init(enabled: Bool = false, labelId: String = "INBOX",
                query: String = "newer_than:3d", pollIntervalMinutes: Double = 5) {
        self.enabled = enabled
        self.labelId = labelId
        self.query = query
        self.pollIntervalMinutes = pollIntervalMinutes
    }

    /// Poll due-check for the 60s scheduler tick. Interval 0 means off.
    public static func isDue(lastPolledAt: Date?, intervalMinutes: Double, now: Date) -> Bool {
        guard intervalMinutes > 0 else { return false }
        guard let last = lastPolledAt else { return true }
        return now.timeIntervalSince(last) >= intervalMinutes * 60
    }
}

public enum GmailSettingsStore {
    public static let key = "gmailSettings"

    public static func load(_ defaults: UserDefaults = .standard) -> GmailSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(GmailSettings.self, from: data) else {
            return GmailSettings()
        }
        return s
    }

    public static func save(_ settings: GmailSettings, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: key) }
    }
}

/// Poll runtime state: the bounded seen-id set plus the last poll stamp.
/// Separate from `GmailSettings` so config edits never clobber sync progress.
public struct GmailSyncState: Codable, Equatable {
    public var seenEventIDs: [String]
    public var lastPolledAt: Date?
    /// Failed-triage attempt counts per message id — so an email that keeps producing
    /// unparseable/failed triage (e.g. an injection emitting prose) is abandoned after a
    /// few tries instead of re-running claude on it every interval forever.
    public var failedAttempts: [String: Int]

    public init(seenEventIDs: [String] = [], lastPolledAt: Date? = nil,
                failedAttempts: [String: Int] = [:]) {
        self.seenEventIDs = seenEventIDs
        self.lastPolledAt = lastPolledAt
        self.failedAttempts = failedAttempts
    }

    enum CodingKeys: String, CodingKey {
        case seenEventIDs, lastPolledAt, failedAttempts
    }

    // Custom decode so `failedAttempts` (added later) defaults to `[:]` when a stored
    // blob predates it — older UserDefaults data stays decodable (mirrors
    // SourceProposal's `init(from:)` pattern for `labels`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seenEventIDs = try c.decode([String].self, forKey: .seenEventIDs)
        lastPolledAt = try c.decodeIfPresent(Date.self, forKey: .lastPolledAt)
        failedAttempts = try c.decodeIfPresent([String: Int].self, forKey: .failedAttempts) ?? [:]
    }
}

public enum GmailSyncStateStore {
    public static let key = "gmailSyncState"

    public static func load(_ defaults: UserDefaults = .standard) -> GmailSyncState {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(GmailSyncState.self, from: data) else {
            return GmailSyncState()
        }
        return s
    }

    public static func save(_ state: GmailSyncState, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: key) }
    }
}
