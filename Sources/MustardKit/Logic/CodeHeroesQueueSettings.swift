import Foundation

/// Local configuration for the optional Code Heroes queue.
/// `enabled` is reserved for a later automatic-refresh opt-in. Phase 6A imports
/// remain manual regardless of its value, and this type has no scheduling fields.
public struct CodeHeroesQueueSettings: Codable, Equatable {
    public var repositoryRoot: String
    public var queuePath: String
    public var enabled: Bool

    public init(repositoryRoot: String = "", queuePath: String = "", enabled: Bool = false) {
        self.repositoryRoot = repositoryRoot
        self.queuePath = queuePath
        self.enabled = enabled
    }
}

/// Persists only Code Heroes queue configuration, independently of source-sweep
/// settings and with a safe default if its data has not been saved or is corrupt.
public enum CodeHeroesQueueSettingsStore {
    public static let key = "codeHeroesQueueSettings"

    public static func load(from defaults: UserDefaults = .standard) -> CodeHeroesQueueSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(CodeHeroesQueueSettings.self, from: data) else {
            return CodeHeroesQueueSettings()
        }
        return settings
    }

    public static func save(_ settings: CodeHeroesQueueSettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    public static func reset(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
