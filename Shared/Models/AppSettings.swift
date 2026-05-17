import Foundation

/// User-tunable application settings persisted under the `app_settings` key.
/// Spec: docs/SYNC_PROTOCOL.md §5.4. All keys are forward-compatible:
/// missing keys are filled with defaults; unknown keys are tolerated.
public struct AppSettings: Codable, Equatable, Hashable, Sendable {
    public var trustInsecureCert: Bool
    public var autoCheckUpdate: Bool
    public var manualUploadDialogShown: Bool
    public var downloadRelativePath: String
    public var logViewLevelFilter: String
    public var ignoredVersion: String?
    /// When true, the sync engine writes new server-side content directly
    /// to `UIPasteboard.general`. When false, new server content is staged
    /// in the UI (highlighted card, expanded preview) but not written.
    /// Default true: tracks the "auto sync" semantics introduced in
    /// cycle 9 — users shouldn't have to think about upload/download.
    public var autoApplyServerChanges: Bool

    public static let defaults = AppSettings(
        trustInsecureCert: false,
        autoCheckUpdate: true,
        manualUploadDialogShown: false,
        downloadRelativePath: "",
        logViewLevelFilter: "info",
        ignoredVersion: nil,
        autoApplyServerChanges: true
    )

    public init(
        trustInsecureCert: Bool = false,
        autoCheckUpdate: Bool = true,
        manualUploadDialogShown: Bool = false,
        downloadRelativePath: String = "",
        logViewLevelFilter: String = "info",
        ignoredVersion: String? = nil,
        autoApplyServerChanges: Bool = true
    ) {
        self.trustInsecureCert = trustInsecureCert
        self.autoCheckUpdate = autoCheckUpdate
        self.manualUploadDialogShown = manualUploadDialogShown
        self.downloadRelativePath = downloadRelativePath
        self.logViewLevelFilter = logViewLevelFilter
        self.ignoredVersion = ignoredVersion
        self.autoApplyServerChanges = autoApplyServerChanges
    }

    private enum CodingKeys: String, CodingKey {
        case trustInsecureCert, autoCheckUpdate, manualUploadDialogShown
        case downloadRelativePath, logViewLevelFilter, ignoredVersion
        case autoApplyServerChanges
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.defaults
        trustInsecureCert       = try c.decodeIfPresent(Bool.self,   forKey: .trustInsecureCert)       ?? d.trustInsecureCert
        autoCheckUpdate         = try c.decodeIfPresent(Bool.self,   forKey: .autoCheckUpdate)         ?? d.autoCheckUpdate
        manualUploadDialogShown = try c.decodeIfPresent(Bool.self,   forKey: .manualUploadDialogShown) ?? d.manualUploadDialogShown
        downloadRelativePath    = try c.decodeIfPresent(String.self, forKey: .downloadRelativePath)    ?? d.downloadRelativePath
        logViewLevelFilter      = try c.decodeIfPresent(String.self, forKey: .logViewLevelFilter)      ?? d.logViewLevelFilter
        ignoredVersion          = try c.decodeIfPresent(String.self, forKey: .ignoredVersion)
        autoApplyServerChanges  = try c.decodeIfPresent(Bool.self,   forKey: .autoApplyServerChanges)  ?? d.autoApplyServerChanges
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trustInsecureCert,       forKey: .trustInsecureCert)
        try c.encode(autoCheckUpdate,         forKey: .autoCheckUpdate)
        try c.encode(manualUploadDialogShown, forKey: .manualUploadDialogShown)
        try c.encode(downloadRelativePath,    forKey: .downloadRelativePath)
        try c.encode(logViewLevelFilter,      forKey: .logViewLevelFilter)
        try c.encodeIfPresent(ignoredVersion, forKey: .ignoredVersion)
        try c.encode(autoApplyServerChanges,  forKey: .autoApplyServerChanges)
    }
}

public extension AppSettings {
    /// §5.5 — `UserDefaults` keys (also reused inside an App Group when sharing with extensions).
    enum PersistenceKey {
        public static let serverConfigList = "server_config_list"
        public static let appSettings      = "app_settings"
        public static let legacyServerConfig = "server_config"
        /// Cycle 9 — runtime sync state. The most recent content hash that
        /// the engine confirmed both sides shared. NOT a user setting; lives
        /// outside `app_settings` so it can be cleared without touching prefs.
        public static let lastSyncedContentHash = "last_synced_content_hash"
        /// Cycle 11 — local observation log: every Clipboard the engine
        /// pulled or pushed, newest-first, capped client-side. Not part of
        /// the wire protocol; the server only keeps one record (§2.1).
        public static let clipboardHistory = "clipboard_history"
        /// Cycle 11 — incremental-sync watermark for §2.7
        /// (`POST /api/history/query`). The highest `lastModified` seen
        /// in any prior page; passed back as `modifiedAfter` so the
        /// server only returns strictly-newer records. Stored as an
        /// ISO-8601 string so the wire format and the persisted form
        /// match (debugging via `defaults read` is then trivial).
        public static let historyModifiedAfter = "history_modified_after"
    }
}
