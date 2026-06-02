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

    public init(
        configs: [ServerConfig] = [],
        activeConfigId: String? = nil
    ) {
        self.configs = configs
        self.activeConfigId = activeConfigId
    }

    private enum CodingKeys: String, CodingKey {
        // `manualOverrideConfigId` is decode-only: a pre-unification key we
        // migrate away from (see init(from:)) and never re-encode.
        case configs, activeConfigId, manualOverrideConfigId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configs = try c.decodeIfPresent([ServerConfig].self, forKey: .configs) ?? []
        let decodedActive = try c.decodeIfPresent(String.self, forKey: .activeConfigId)
        // One-shot migration: pre-unification builds persisted a home-chip
        // "pin" in `manualOverrideConfigId` that out-prioritized
        // `activeConfigId`. The pin concept is gone — the user's last
        // explicit pick IS the current server now — so promote a resolvable
        // legacy pin into `activeConfigId` and never re-encode the old key
        // (see encode(to:)). Absent/unresolvable → fall back to the
        // persisted `activeConfigId`.
        let legacyPin = try c.decodeIfPresent(String.self, forKey: .manualOverrideConfigId)
        if let pin = legacyPin, configs.contains(where: { $0.id == pin }) {
            activeConfigId = pin
        } else {
            activeConfigId = decodedActive
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(configs, forKey: .configs)
        try c.encodeIfPresent(activeConfigId, forKey: .activeConfigId)
    }

    /// §5.2 — stale activeConfigId falls back to configs[0]; nil iff configs is empty.
    public var activeConfig: ServerConfig? {
        guard !configs.isEmpty else { return nil }
        if let id = activeConfigId, let hit = configs.first(where: { $0.id == id }) { return hit }
        return configs.first
    }

    /// §5.3 — the server we'd *suggest* switching to for the current Wi-Fi,
    /// or `nil` if there's nothing worth suggesting. The active server is
    /// always `activeConfig` (§5.2); `autoSwitchWifiNames` no longer
    /// silently re-routes it — it only drives a one-tap UI nudge. Returns:
    /// - `nil` when the SSID is unknown/empty (no basis to suggest).
    /// - `nil` when the current `activeConfig` itself matches the SSID
    ///   (already on the right server — nothing to suggest).
    /// - otherwise the first OTHER config matching the SSID, in `configs`
    ///   array order. Two configs sharing a SSID is a config accident; the
    ///   deterministic "first wins" stays.
    public func suggestedSwitch(currentSsid: String?) -> ServerConfig? {
        guard ServerConfig.normalizeSSID(currentSsid) != nil else { return nil }
        let current = activeConfig
        if let current, current.matchesWifiName(currentSsid) { return nil }
        for cfg in configs where cfg.id != current?.id {
            if cfg.matchesWifiName(currentSsid) { return cfg }
        }
        return nil
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
