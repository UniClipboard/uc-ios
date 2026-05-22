import Foundation

/// One server profile. Spec: docs/SYNC_PROTOCOL.md §5.1.
public struct ServerConfig: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var url: String
    public var username: String
    public var password: String
    public var autoSwitchWifiNames: [String]

    public init(
        id: String,
        name: String? = nil,
        url: String,
        username: String,
        password: String,
        autoSwitchWifiNames: [String] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.username = username
        self.password = password
        self.autoSwitchWifiNames = autoSwitchWifiNames
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, username, password, autoSwitchWifiNames
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(String.self, forKey: .id)
        name     = try c.decodeIfPresent(String.self, forKey: .name)
        url      = try c.decode(String.self, forKey: .url)
        username = try c.decode(String.self, forKey: .username)
        password = try c.decode(String.self, forKey: .password)
        autoSwitchWifiNames = try c.decodeIfPresent([String].self, forKey: .autoSwitchWifiNames) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encode(username, forKey: .username)
        try c.encode(password, forKey: .password)
        try c.encode(autoSwitchWifiNames, forKey: .autoSwitchWifiNames)
    }

    /// §5.1 — fall back to URL when name is nil/empty/whitespace.
    public var displayLabel: String {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        return url
    }

    /// §5.1 SSID normalization: trim → strip outer quotes → reject Android privacy placeholders.
    public static func normalizeSSID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.isEmpty || s == "<unknown ssid>" || s == "0x" { return nil }
        return s
    }

    /// §5.3 — true iff the normalized current SSID is in the normalized auto-switch list.
    public func matchesWifiName(_ currentSsid: String?) -> Bool {
        guard let target = Self.normalizeSSID(currentSsid) else { return false }
        return autoSwitchWifiNames.contains { Self.normalizeSSID($0) == target }
    }
}

/// Persisted multi-server collection. Spec: §5.2.
public struct ServerConfigList: Codable, Equatable, Hashable, Sendable {
    public var configs: [ServerConfig]
    public var activeConfigId: String?

    /// User's explicit pin from the home-screen server chip. When non-nil
    /// and resolvable to an existing config, this wins over both the
    /// user's `activeConfigId` default AND the §5.3 SSID auto-switch
    /// rules. Cleared when the user picks the "自动切换" affordance in
    /// the switcher sheet, when the pinned server is deleted, or when
    /// the user edits the default in Settings (treated as a fresh
    /// intent that should release the pin).
    ///
    /// Why a separate field instead of just respecting `activeConfigId`:
    /// the WiFi auto-switch feature is the whole reason for §5.3 — users
    /// who set `autoSwitchWifiNames` *want* their non-default server to
    /// take over on its LAN. So `activeConfigId` continues to mean "my
    /// fallback when no SSID rule matches", and `manualOverrideConfigId`
    /// is the "no, actually, I picked this one — stop second-guessing me"
    /// override.
    public var manualOverrideConfigId: String?

    public init(
        configs: [ServerConfig] = [],
        activeConfigId: String? = nil,
        manualOverrideConfigId: String? = nil
    ) {
        self.configs = configs
        self.activeConfigId = activeConfigId
        self.manualOverrideConfigId = manualOverrideConfigId
    }

    private enum CodingKeys: String, CodingKey {
        case configs, activeConfigId, manualOverrideConfigId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configs = try c.decodeIfPresent([ServerConfig].self, forKey: .configs) ?? []
        activeConfigId = try c.decodeIfPresent(String.self, forKey: .activeConfigId)
        manualOverrideConfigId = try c.decodeIfPresent(String.self, forKey: .manualOverrideConfigId)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(configs, forKey: .configs)
        try c.encodeIfPresent(activeConfigId, forKey: .activeConfigId)
        try c.encodeIfPresent(manualOverrideConfigId, forKey: .manualOverrideConfigId)
    }

    /// §5.2 — stale activeConfigId falls back to configs[0]; nil iff configs is empty.
    public var activeConfig: ServerConfig? {
        guard !configs.isEmpty else { return nil }
        if let id = activeConfigId, let hit = configs.first(where: { $0.id == id }) { return hit }
        return configs.first
    }

    /// Resolves the effective server. Precedence:
    /// 1. `manualOverrideConfigId` — the user's explicit chip pin.
    /// 2. The default server when it ITSELF has a matching SSID rule
    ///    (covers the case where multiple servers share a SSID — the
    ///    default wins to avoid silently re-routing the user's chosen
    ///    server to one they merely added on the same network).
    /// 3. §5.3 SSID auto-switch — first non-default config matching the
    ///    current Wi-Fi, in `configs` array order. Two non-default
    ///    servers sharing a SSID is a configuration accident; the
    ///    deterministic-but-implicit "first wins" stays for now.
    /// 4. `activeConfig` — the user's persisted default (with §5.2 fallback).
    public func resolveActiveConfig(currentSsid: String?) -> ServerConfig? {
        if let id = manualOverrideConfigId,
           let pinned = configs.first(where: { $0.id == id }) {
            return pinned
        }
        guard let defaultCfg = activeConfig else { return nil }
        guard Self.normalizeNonNilSSID(currentSsid) != nil else { return defaultCfg }
        if defaultCfg.matchesWifiName(currentSsid) { return defaultCfg }
        for cfg in configs where cfg.id != defaultCfg.id {
            if cfg.matchesWifiName(currentSsid) { return cfg }
        }
        return defaultCfg
    }

    private static func normalizeNonNilSSID(_ ssid: String?) -> String? {
        ServerConfig.normalizeSSID(ssid)
    }
}

/// Read-only legacy single-config shape. Spec: §5.5.
public struct LegacyServerConfig: Codable, Equatable, Sendable {
    public var url: String
    public var username: String
    public var password: String

    public init(url: String, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }

    /// §5.5 — wrap into a ServerConfigList with a fresh UUID v4 and mark active.
    public func migrated(idProvider: () -> String = { UUID().uuidString.lowercased() }) -> ServerConfigList {
        let cfg = ServerConfig(
            id: idProvider(),
            name: nil,
            url: url,
            username: username,
            password: password,
            autoSwitchWifiNames: []
        )
        return ServerConfigList(configs: [cfg], activeConfigId: cfg.id)
    }
}
