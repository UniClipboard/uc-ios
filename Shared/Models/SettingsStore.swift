import Foundation

/// Persists `ServerConfigList` and `AppSettings` under the keys defined in
/// `AppSettings.PersistenceKey` (spec: `docs/SYNC_PROTOCOL.md` §5.4, §5.5).
///
/// Pure Foundation — lives in the SwiftPM `Models` target so it can be
/// unit-tested via `swift test`.
///
/// Corruption policy: if a stored JSON blob fails to decode, the store
/// returns the type's default ( empty list / `AppSettings.defaults`). This
/// matches the forward-compat philosophy of `AppSettings.init(from:)` —
/// stored data must never block app startup.
public final class SettingsStore: @unchecked Sendable {
    /// App Group container shared between the main app and the Share
    /// Extension. Keep in sync with the `application-groups` entitlement
    /// on both targets.
    public static let appGroupID = "group.app.uniclipboard.UniClipboard"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter defaults: when nil (the default), the store opens the
    ///   App Group suite (`appGroupID`) and one-shot-migrates any existing
    ///   keys from `.standard` on first use. Falls back to `.standard` if
    ///   the App Group entitlement isn't active. Tests pass an explicit
    ///   ephemeral `UserDefaults(suiteName:)`.
    public init(defaults: UserDefaults? = nil) {
        let chosen: UserDefaults
        if let defaults {
            chosen = defaults
        } else if let suite = UserDefaults(suiteName: SettingsStore.appGroupID) {
            SettingsStore.migrateFromStandardIfNeeded(into: suite)
            chosen = suite
        } else {
            chosen = .standard
        }
        self.defaults = chosen
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// One-shot migration from `.standard` to the App Group suite. Runs
    /// the first time we open the suite after the App Group entitlement
    /// is added: copies known keys over and removes them from `.standard`.
    /// Idempotent — if any known key already exists in the suite the
    /// migration is considered done and skipped, so a re-install can't be
    /// overridden by a stale `.standard` blob.
    private static func migrateFromStandardIfNeeded(into suite: UserDefaults) {
        let keys = [
            AppSettings.PersistenceKey.serverConfigList,
            AppSettings.PersistenceKey.appSettings,
            AppSettings.PersistenceKey.lastSyncedContentHash,
            AppSettings.PersistenceKey.legacyServerConfig,
        ]
        for key in keys where suite.object(forKey: key) != nil {
            return
        }
        let standard = UserDefaults.standard
        for key in keys {
            guard let value = standard.object(forKey: key) else { continue }
            suite.set(value, forKey: key)
            standard.removeObject(forKey: key)
        }
    }

    // MARK: - ServerConfigList

    /// Load the server list, performing one-shot legacy migration (§5.5)
    /// if `server_config_list` is absent and `server_config` is present.
    public func loadServers() -> ServerConfigList {
        if let data = defaults.data(forKey: AppSettings.PersistenceKey.serverConfigList) {
            if let list = try? decoder.decode(ServerConfigList.self, from: data) {
                return list
            }
            return ServerConfigList()
        }

        if let legacyData = defaults.data(forKey: AppSettings.PersistenceKey.legacyServerConfig),
           let legacy = try? decoder.decode(LegacyServerConfig.self, from: legacyData) {
            let migrated = legacy.migrated()
            saveServers(migrated)
            defaults.removeObject(forKey: AppSettings.PersistenceKey.legacyServerConfig)
            return migrated
        }

        return ServerConfigList()
    }

    public func saveServers(_ list: ServerConfigList) {
        guard let data = try? encoder.encode(list) else { return }
        defaults.set(data, forKey: AppSettings.PersistenceKey.serverConfigList)
    }

    // MARK: - AppSettings

    public func loadAppSettings() -> AppSettings {
        guard let data = defaults.data(forKey: AppSettings.PersistenceKey.appSettings) else {
            return .defaults
        }
        return (try? decoder.decode(AppSettings.self, from: data)) ?? .defaults
    }

    public func saveAppSettings(_ settings: AppSettings) {
        guard let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: AppSettings.PersistenceKey.appSettings)
    }

    // MARK: - Last-synced content hash (cycle 9)

    /// Load the most-recent content hash the sync engine confirmed both
    /// sides shared. `nil` on first launch or after the engine resets.
    public func loadLastSyncedHash() -> String? {
        defaults.string(forKey: AppSettings.PersistenceKey.lastSyncedContentHash)
    }

    /// Persist the latest synced-content hash. Pass `nil` to clear it (e.g.
    /// when the user switches active server).
    public func saveLastSyncedHash(_ hash: String?) {
        if let hash {
            defaults.set(hash, forKey: AppSettings.PersistenceKey.lastSyncedContentHash)
        } else {
            defaults.removeObject(forKey: AppSettings.PersistenceKey.lastSyncedContentHash)
        }
    }

    // MARK: - Clipboard history (cycle 11)

    /// Load the persisted clipboard observation log. Returns `[]` on cold
    /// launch or when the stored JSON fails to decode (forward-compat with
    /// the rest of the store's corruption policy — never block startup on
    /// a bad blob).
    public func loadHistory() -> [ClipboardHistoryItem] {
        guard let data = defaults.data(forKey: AppSettings.PersistenceKey.clipboardHistory) else {
            return []
        }
        return (try? decoder.decode([ClipboardHistoryItem].self, from: data)) ?? []
    }

    /// Persist the clipboard observation log. Callers cap the size before
    /// calling — this method writes whatever it's handed. An empty array
    /// is still encoded (rather than removing the key) so a subsequent
    /// load round-trips to `[]` and the corruption fallback never fires.
    public func saveHistory(_ items: [ClipboardHistoryItem]) {
        guard let data = try? encoder.encode(items) else { return }
        defaults.set(data, forKey: AppSettings.PersistenceKey.clipboardHistory)
    }

    /// Load the incremental-sync watermark (the largest `lastModified`
    /// seen on any prior §2.7 page). Returns `nil` on cold launch or if
    /// the stored string fails to parse — both are treated as "fetch
    /// everything next round".
    public func loadHistoryWatermark() -> Date? {
        guard let s = defaults.string(forKey: AppSettings.PersistenceKey.historyModifiedAfter),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        if let d = Self.fractionalISOFormatter.date(from: s) { return d }
        if let d = Self.plainISOFormatter.date(from: s) { return d }
        return nil
    }

    /// Persist the watermark. Pass `nil` to clear (e.g. when switching
    /// servers — the new server's `lastModified` timeline is unrelated
    /// to the old one).
    public func saveHistoryWatermark(_ date: Date?) {
        if let date {
            defaults.set(Self.fractionalISOFormatter.string(from: date),
                         forKey: AppSettings.PersistenceKey.historyModifiedAfter)
        } else {
            defaults.removeObject(forKey: AppSettings.PersistenceKey.historyModifiedAfter)
        }
    }

    // MARK: - ISO formatters (shared between watermark + future date keys)

    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plainISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
