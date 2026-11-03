import Foundation

public enum SettingsStoreError: Error, Equatable {
    case duplicateKeyboardBindings([KeyboardBindingConflict])
    case invalidKeyboardBindings([KeyboardBindingIssue])
}

public protocol SettingsPersisting {
    func load() -> SwooshSettings
    func save(_ settings: SwooshSettings) throws
    func restoreDefaults() throws -> SwooshSettings
}

public final class UserDefaultsSettingsStore: SettingsPersisting {
    public static let defaultKey = "co.swoosh.settings.v1"
    public static let legacySuiteName = "com.example.Swoosh"
    public static let legacyMigrationMarkerKey = "co.swoosh.settings.migrated-from-com.example.Swoosh.v1"

    private let defaults: UserDefaults
    private let legacyDefaults: UserDefaults?
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public convenience init(key: String = UserDefaultsSettingsStore.defaultKey) {
        self.init(
            defaults: .standard,
            key: key,
            legacyDefaults: UserDefaults(suiteName: UserDefaultsSettingsStore.legacySuiteName)
        )
    }

    public init(
        defaults: UserDefaults,
        key: String = UserDefaultsSettingsStore.defaultKey,
        legacyDefaults: UserDefaults? = nil
    ) {
        self.defaults = defaults
        self.key = key
        self.legacyDefaults = legacyDefaults
        encoder.outputFormatting = [.sortedKeys]
    }

    public func load() -> SwooshSettings {
        migrateLegacySettingsIfNeeded()

        guard let data = defaults.data(forKey: key) else {
            return .defaults
        }

        guard let decoded = try? decoder.decode(SwooshSettings.self, from: data) else {
            return .defaults
        }

        return decoded.normalized
    }

    public func save(_ settings: SwooshSettings) throws {
        let normalized = settings.normalized
        let conflicts = normalized.bindingConflicts()
        guard conflicts.isEmpty else {
            throw SettingsStoreError.duplicateKeyboardBindings(conflicts)
        }

        let issues = KeyboardBindingValidator().issues(for: normalized)
        guard issues.isEmpty else {
            throw SettingsStoreError.invalidKeyboardBindings(issues)
        }

        let data = try encoder.encode(normalized)
        defaults.set(data, forKey: key)
    }

    public func restoreDefaults() throws -> SwooshSettings {
        let restored = SwooshSettings.defaults
        try save(restored)
        return restored
    }

    public func rawStoredData() -> Data? {
        defaults.data(forKey: key)
    }

    private func migrateLegacySettingsIfNeeded() {
        guard defaults.object(forKey: Self.legacyMigrationMarkerKey) == nil else {
            return
        }

        defer {
            defaults.set(Self.legacySuiteName, forKey: Self.legacyMigrationMarkerKey)
        }

        guard defaults.object(forKey: key) == nil,
              let legacyData = legacyDefaults?.data(forKey: key) else {
            return
        }

        // Copy rather than move so rollback to a legacy build remains possible.
        defaults.set(legacyData, forKey: key)
    }
}
