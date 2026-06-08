import XCTest
@testable import UniClipboardModels

final class FixturesTests: XCTestCase {

    // MARK: - helpers

    /// Resolves to the repo's `docs/examples/` directory at test-runtime via
    /// the source location of this file. Keeps the fixtures single-sourced
    /// (no copy/symlink dance) and lets `swift test` work from the repo root.
    private static let fixturesDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()                // Tests/UniClipboardModelsTests/
            .deletingLastPathComponent()                // Tests/
            .deletingLastPathComponent()                // <repo root>/
            .appendingPathComponent("docs/examples", isDirectory: true)
    }()

    private func loadFixture(_ name: String) throws -> Data {
        let url = Self.fixturesDir.appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Fixture not found at \(url.path)")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    private func keys(_ data: Data) throws -> Set<String> {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return Set(obj.keys)
    }

    private func nestedConfigs(_ data: Data) throws -> [[String: Any]] {
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return obj["configs"] as? [[String: Any]] ?? []
    }

    // MARK: - Clipboard wire fixtures (§3)

    func test_clipboardTextShort_decodes_and_roundTripsWithoutNullKeys() throws {
        let data = try loadFixture("clipboard_text_short")
        let entry = try JSONDecoder().decode(Clipboard.self, from: data)

        XCTAssertEqual(entry.type, .text)
        XCTAssertEqual(entry.hash,
            "3F4E62D9F184380BAD1B0F94B5518DCBF35ACB79B34F6D6E34F3DAB16CD7BC8F")
        XCTAssertEqual(entry.text, "Hello, SyncClipboard!")
        XCTAssertEqual(entry.size, 21)
        XCTAssertFalse(entry.hasData)
        XCTAssertNil(entry.dataName)

        let re = try JSONEncoder().encode(entry)
        XCTAssertFalse(String(data: re, encoding: .utf8)!.contains("null"))
        XCTAssertEqual(try keys(re), ["type", "hash", "text", "hasData", "size"])
    }

    func test_clipboardTextLong_hasDataTrueWithDataName() throws {
        let data = try loadFixture("clipboard_text_long")
        let entry = try JSONDecoder().decode(Clipboard.self, from: data)

        XCTAssertEqual(entry.type, .text)
        XCTAssertTrue(entry.hasData)
        XCTAssertEqual(entry.dataName,
            "text_B7E8C3D4F5A6071829304152637485A6B7C8D9E0F1A2B3C4D5E6F70819203142.txt")
        XCTAssertEqual(entry.size, 23457)

        let re = try JSONEncoder().encode(entry)
        XCTAssertEqual(try keys(re), ["type", "hash", "text", "hasData", "dataName", "size"])
    }

    func test_clipboardImage_decodesImageKind() throws {
        let data = try loadFixture("clipboard_image")
        let entry = try JSONDecoder().decode(Clipboard.self, from: data)

        XCTAssertEqual(entry.type, .image)
        XCTAssertEqual(entry.dataName, "photo_2026.png")
        XCTAssertEqual(entry.size, 184320)
        XCTAssertTrue(entry.hasData)

        let re = try JSONEncoder().encode(entry)
        XCTAssertEqual(try keys(re), ["type", "hash", "text", "hasData", "dataName", "size"])
    }

    func test_clipboardFile_decodesFileKind() throws {
        let data = try loadFixture("clipboard_file")
        let entry = try JSONDecoder().decode(Clipboard.self, from: data)

        XCTAssertEqual(entry.type, .file)
        XCTAssertEqual(entry.dataName, "report.pdf")

        let re = try JSONEncoder().encode(entry)
        XCTAssertEqual(try keys(re), ["type", "hash", "text", "hasData", "dataName", "size"])
    }

    func test_clipboardGroup_decodesGroupKind() throws {
        let data = try loadFixture("clipboard_group")
        let entry = try JSONDecoder().decode(Clipboard.self, from: data)

        XCTAssertEqual(entry.type, .group)
        XCTAssertEqual(entry.dataName, "screenshots.zip")

        let re = try JSONEncoder().encode(entry)
        XCTAssertEqual(try keys(re), ["type", "hash", "text", "hasData", "dataName", "size"])
    }

    func test_clipboardNoHash_optionalKeysAreOmittedNotNullified() throws {
        let data = try loadFixture("clipboard_no_hash")
        let entry = try JSONDecoder().decode(Clipboard.self, from: data)

        XCTAssertEqual(entry.type, .text)
        XCTAssertNil(entry.hash)
        XCTAssertNil(entry.dataName)
        XCTAssertNil(entry.size)
        XCTAssertFalse(entry.hasData)

        let re = try JSONEncoder().encode(entry)
        let str = String(data: re, encoding: .utf8)!
        XCTAssertFalse(str.contains("null"),
            "optional fields must be omitted, not encoded as null")
        XCTAssertEqual(try keys(re), ["type", "text", "hasData"])
    }

    func test_clipboard_hashWhitespaceNormalizesToNil() throws {
        let json = #"{"type":"Text","hash":"   ","text":"x","hasData":false}"#
        let entry = try JSONDecoder().decode(Clipboard.self, from: Data(json.utf8))
        XCTAssertNil(entry.hash)
    }

    func test_clipboard_kindRawValuesMatchWire() {
        XCTAssertEqual(Clipboard.Kind.text.rawValue,  "Text")
        XCTAssertEqual(Clipboard.Kind.image.rawValue, "Image")
        XCTAssertEqual(Clipboard.Kind.file.rawValue,  "File")
        XCTAssertEqual(Clipboard.Kind.group.rawValue, "Group")
    }

    func test_hashMatches_nilOrEmptyExpectedMatchesAnything() {
        XCTAssertTrue(Clipboard.hashMatches(expected: nil, actual: "DEADBEEF"))
        XCTAssertTrue(Clipboard.hashMatches(expected: "", actual: "DEADBEEF"))
        XCTAssertTrue(Clipboard.hashMatches(expected: "  ", actual: "DEADBEEF"))
        XCTAssertTrue(Clipboard.hashMatches(expected: "deadbeef", actual: "DEADBEEF"))
        XCTAssertFalse(Clipboard.hashMatches(expected: "AAA", actual: "BBB"))
    }

    // MARK: - ServerConfig persistence fixtures (§5)

    func test_serverConfigList_decodesThreeConfigs() throws {
        let data = try loadFixture("server_config_list")
        let list = try JSONDecoder().decode(ServerConfigList.self, from: data)

        XCTAssertEqual(list.configs.count, 3)
        XCTAssertEqual(list.activeConfigId, "ff112233-4455-6677-8899-aabbccddeeff")

        XCTAssertEqual(list.configs[0].name, "Home NAS")
        XCTAssertEqual(list.configs[0].autoSwitchWifiNames, ["Home-5G", "Home-2.4G"])
        XCTAssertEqual(list.configs[1].autoSwitchWifiNames, ["Corp-WiFi"])
        XCTAssertNil(list.configs[2].name)
        XCTAssertEqual(list.configs[2].autoSwitchWifiNames, [])

        XCTAssertEqual(list.activeConfig?.id, list.configs[2].id)
    }

    func test_serverConfigList_roundTripPreservesMissingNameAsAbsentKey() throws {
        let data = try loadFixture("server_config_list")
        let list = try JSONDecoder().decode(ServerConfigList.self, from: data)
        let re = try JSONEncoder().encode(list)

        XCTAssertFalse(String(data: re, encoding: .utf8)!.contains("\"name\":null"))
        let configs = try nestedConfigs(re)
        XCTAssertEqual(configs.count, 3)
        XCTAssertNotNil(configs[0]["name"])
        XCTAssertNotNil(configs[1]["name"])
        XCTAssertNil(configs[2]["name"], "third config has no name → key must be absent")
    }

    func test_activeConfig_fallsBackToFirstWhenIdIsStale() {
        let cfg = ServerConfig(id: "alpha", url: "http://x", username: "u", password: "p")
        let list = ServerConfigList(configs: [cfg], activeConfigId: "stale-id")
        XCTAssertEqual(list.activeConfig?.id, "alpha")
    }

    func test_activeConfig_isNilWhenConfigsIsEmpty() {
        XCTAssertNil(ServerConfigList().activeConfig)
        XCTAssertNil(ServerConfigList(configs: [], activeConfigId: "anything").activeConfig)
    }

    func test_serverConfig_displayLabelFallsBackToURLWhenNameEmpty() {
        let cfg = ServerConfig(id: "x", name: "  ", url: "http://h", username: "u", password: "p")
        XCTAssertEqual(cfg.displayLabel, "http://h")
    }

    // MARK: - §5.3 network auto-switch resolver

    private func net(_ ssid: String? = nil, cellular: Bool = false, tailscale: Bool = false) -> NetworkContext {
        NetworkContext(ssid: ssid, isCellular: cellular, isTailscale: tailscale)
    }

    func test_resolve_wifiStrategyMatchesSSID() {
        // Only a `.wifi` config listing the SSID matches → it overrides baseline.
        let a = ServerConfig(id: "a", url: "http://a", username: "u", password: "p")
        let b = ServerConfig(id: "b", url: "http://b", username: "u", password: "p",
                             autoSwitchWifiNames: ["Home"], autoSwitchStrategy: .wifi)
        let list = ServerConfigList(configs: [a, b], activeConfigId: "a")
        XCTAssertEqual(list.effectiveActiveConfig(network: net("Home"))?.id, "b")
    }

    func test_resolve_wifiNamesInertUnlessStrategyIsWifi() {
        // A config carries SSIDs but its strategy isn't .wifi → it does NOT
        // auto-switch (single-strategy model; SSIDs only count under .wifi).
        let a = ServerConfig(id: "a", url: "http://a", username: "u", password: "p")
        let b = ServerConfig(id: "b", url: "http://b", username: "u", password: "p",
                             autoSwitchWifiNames: ["Home"], autoSwitchStrategy: .none)
        let list = ServerConfigList(configs: [a, b], activeConfigId: "a")
        XCTAssertEqual(list.effectiveActiveConfig(network: net("Home"))?.id, "a")
    }

    func test_resolve_wifiKeepsActiveWhenItQualifies() {
        let a = ServerConfig(id: "a", url: "http://a", username: "u", password: "p",
                             autoSwitchWifiNames: ["Home"], autoSwitchStrategy: .wifi)
        let b = ServerConfig(id: "b", url: "http://b", username: "u", password: "p",
                             autoSwitchWifiNames: ["Home"], autoSwitchStrategy: .wifi)
        let list = ServerConfigList(configs: [a, b], activeConfigId: "a")
        XCTAssertEqual(list.effectiveActiveConfig(network: net("Home"))?.id, "a",
                       "anti-flap: active config that fits stays")
    }

    func test_resolve_cellularStrategy() {
        let a = ServerConfig(id: "a", url: "http://a", username: "u", password: "p")
        let b = ServerConfig(id: "b", url: "http://b", username: "u", password: "p",
                             autoSwitchStrategy: .cellular)
        let list = ServerConfigList(configs: [a, b], activeConfigId: "a")
        XCTAssertEqual(list.effectiveActiveConfig(network: net(cellular: true))?.id, "b")
    }

    func test_resolve_tailscaleBeatsWifi() {
        // Tailscale is P1: up + a config opts in → it wins over the Wi-Fi the
        // device is physically on.
        let wifi = ServerConfig(id: "w", url: "http://w", username: "u", password: "p",
                                autoSwitchWifiNames: ["Home"], autoSwitchStrategy: .wifi)
        let ts = ServerConfig(id: "t", url: "http://t", username: "u", password: "p",
                              autoSwitchStrategy: .tailscale)
        let list = ServerConfigList(configs: [wifi, ts], activeConfigId: "w")
        XCTAssertEqual(list.effectiveActiveConfig(network: net("Home", tailscale: true))?.id, "t")
    }

    func test_resolve_tailscaleUpButNoConfigFallsThroughToWifi() {
        // Tailscale up but nobody opted into it → fall through to the Wi-Fi tier.
        let wifi = ServerConfig(id: "w", url: "http://w", username: "u", password: "p",
                                autoSwitchWifiNames: ["Home"], autoSwitchStrategy: .wifi)
        let cell = ServerConfig(id: "c", url: "http://c", username: "u", password: "p",
                                autoSwitchStrategy: .cellular)
        let list = ServerConfigList(configs: [wifi, cell], activeConfigId: "c")
        XCTAssertEqual(list.effectiveActiveConfig(network: net("Home", tailscale: true))?.id, "w")
    }

    func test_resolve_fallsBackToBaseline() {
        // No tier matches → manual baseline (§5.2); empty list → nil.
        let a = ServerConfig(id: "a", url: "http://a", username: "u", password: "p")
        let b = ServerConfig(id: "b", url: "http://b", username: "u", password: "p",
                             autoSwitchWifiNames: ["Home"], autoSwitchStrategy: .wifi)
        let list = ServerConfigList(configs: [a, b], activeConfigId: "a")
        XCTAssertEqual(list.effectiveActiveConfig(network: net("Cafe"))?.id, "a",
                       "unconfigured Wi-Fi → baseline (no catch-all tier)")
        XCTAssertEqual(list.effectiveActiveConfig(network: net())?.id, "a", "offline → baseline")
        XCTAssertNil(ServerConfigList().effectiveActiveConfig(network: net("Home")),
                     "empty list → nil, mirroring activeConfig")
    }

    func test_serverConfig_codable_roundTripsStrategy() throws {
        let cfg = ServerConfig(id: "a", url: "http://a", username: "u", password: "p",
                               autoSwitchWifiNames: ["Home"], autoSwitchStrategy: .tailscale)
        let back = try JSONDecoder().decode(ServerConfig.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back, cfg)
        XCTAssertEqual(back.autoSwitchStrategy, .tailscale)
    }

    func test_serverConfig_migratesLegacyWifiNamesToStrategy() throws {
        // Pre-strategy JSON: a non-empty SSID list → .wifi; empty/absent → .none.
        let withSSIDs = #"{"id":"a","url":"http://a","username":"u","password":"p","autoSwitchWifiNames":["Home"]}"#
        XCTAssertEqual(try JSONDecoder().decode(ServerConfig.self, from: Data(withSSIDs.utf8)).autoSwitchStrategy, .wifi)
        let noSSIDs = #"{"id":"b","url":"http://b","username":"u","password":"p"}"#
        XCTAssertEqual(try JSONDecoder().decode(ServerConfig.self, from: Data(noSSIDs.utf8)).autoSwitchStrategy, AutoSwitchStrategy.none)
    }

    func test_serverConfig_unknownStrategyDegradesToNone_notWifi() throws {
        // §5.1: an *unknown* strategy raw value degrades to .none. The SSID-list
        // → .wifi migration must apply ONLY when the key is absent (pre-strategy
        // data) — a present-but-unknown value (a newer build's strategy, or
        // null) must NOT inherit .wifi just because an SSID list is also present.
        let unknownWithSSIDs = #"{"id":"a","url":"http://a","username":"u","password":"p","autoSwitchWifiNames":["Home"],"autoSwitchStrategy":"vpn"}"#
        XCTAssertEqual(try JSONDecoder().decode(ServerConfig.self, from: Data(unknownWithSSIDs.utf8)).autoSwitchStrategy,
                       AutoSwitchStrategy.none)
        let nullStrategy = #"{"id":"b","url":"http://b","username":"u","password":"p","autoSwitchStrategy":null}"#
        XCTAssertEqual(try JSONDecoder().decode(ServerConfig.self, from: Data(nullStrategy.utf8)).autoSwitchStrategy,
                       AutoSwitchStrategy.none)
    }

    func test_legacyManualOverride_promotedToActiveConfigOnDecode() throws {
        // Pre-unification installs persisted a home-chip "pin" in
        // `manualOverrideConfigId`. On decode it must be promoted to
        // `activeConfigId` (the user's last explicit pick becomes current).
        let json = #"{"configs":[{"id":"a","url":"http://a","username":"u","password":"p"},{"id":"b","url":"http://b","username":"u","password":"p"}],"activeConfigId":"a","manualOverrideConfigId":"b"}"#
        let decoded = try JSONDecoder().decode(ServerConfigList.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.activeConfigId, "b",
                       "a resolvable legacy pin must become the current server")
    }

    func test_legacyManualOverride_ignoredWhenUnresolvableAndNotReEncoded() throws {
        // A phantom legacy pin keeps the persisted activeConfigId, and the
        // old key is never written back out.
        let json = #"{"configs":[{"id":"a","url":"http://a","username":"u","password":"p"}],"activeConfigId":"a","manualOverrideConfigId":"ghost"}"#
        let decoded = try JSONDecoder().decode(ServerConfigList.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.activeConfigId, "a")
        let reencoded = String(data: try JSONEncoder().encode(decoded), encoding: .utf8)!
        XCTAssertFalse(reencoded.contains("manualOverrideConfigId"),
                       "the legacy key must not be re-encoded")
    }

    func test_serverConfig_normalizeSSID_stripsQuotesAndRejectsPlaceholders() {
        XCTAssertEqual(ServerConfig.normalizeSSID("\"Home-5G\""), "Home-5G")
        XCTAssertEqual(ServerConfig.normalizeSSID("  Home-5G  "), "Home-5G")
        XCTAssertNil(ServerConfig.normalizeSSID(""))
        XCTAssertNil(ServerConfig.normalizeSSID(nil))
        XCTAssertNil(ServerConfig.normalizeSSID("<unknown ssid>"))
        XCTAssertNil(ServerConfig.normalizeSSID("0x"))
    }

    func test_effectiveActiveConfig_fromFixturePrefersWifiOverCellular() throws {
        let data = try loadFixture("server_config_list")
        let list = try JSONDecoder().decode(ServerConfigList.self, from: data)
        // Active is config #3 (remote, strategy = cellular). On "Home-5G",
        // config #1's Wi-Fi rule (P2) wins → config #1.
        XCTAssertEqual(list.effectiveActiveConfig(network: net("Home-5G"))?.id,
                       "0c1f2e3a-4b5c-6d7e-8f90-123456789abc")
    }

    func test_effectiveActiveConfig_fromFixtureCellularAndOffline() throws {
        let data = try loadFixture("server_config_list")
        let list = try JSONDecoder().decode(ServerConfigList.self, from: data)
        let remoteId = "ff112233-4455-6677-8899-aabbccddeeff"
        // Config #3's strategy is cellular → on cellular it's the effective server.
        XCTAssertEqual(list.effectiveActiveConfig(network: net(cellular: true))?.id, remoteId)
        // Offline → no rule applies → the baseline (§5.2 active = #3) stands.
        XCTAssertEqual(list.effectiveActiveConfig(network: net())?.id, remoteId)
    }

    func test_legacyServerConfig_migrationProducesActiveSingleConfig() throws {
        let data = try loadFixture("server_config_legacy")
        let legacy = try JSONDecoder().decode(LegacyServerConfig.self, from: data)
        XCTAssertEqual(legacy.url, "https://clip.home.lan:5033/")
        XCTAssertEqual(legacy.username, "alice")
        XCTAssertEqual(legacy.password, "p4ssw0rd!")

        let migrated = legacy.migrated(idProvider: { "fixed-uuid" })
        XCTAssertEqual(migrated.configs.count, 1)
        XCTAssertEqual(migrated.activeConfigId, "fixed-uuid")
        XCTAssertEqual(migrated.configs[0].id, "fixed-uuid")
        XCTAssertNil(migrated.configs[0].name)
        XCTAssertEqual(migrated.configs[0].autoSwitchWifiNames, [])
    }

    // MARK: - AppSettings persistence fixtures (§5.4)

    func test_appSettings_full_roundTripsIgnoredVersion() throws {
        let data = try loadFixture("app_settings")
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertFalse(settings.trustInsecureCert)
        XCTAssertTrue(settings.autoCheckUpdate)
        XCTAssertTrue(settings.manualUploadDialogShown)
        XCTAssertEqual(settings.downloadRelativePath, "SyncClipboard/Inbox")
        XCTAssertEqual(settings.logViewLevelFilter, "info")
        XCTAssertEqual(settings.ignoredVersion, "0.3.2")

        let re = try JSONEncoder().encode(settings)
        XCTAssertTrue(try keys(re).contains("ignoredVersion"))
    }

    func test_appSettings_minimal_omitsNilIgnoredVersionOnReencode() throws {
        let data = try loadFixture("app_settings_minimal")
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertNil(settings.ignoredVersion)

        let re = try JSONEncoder().encode(settings)
        let str = String(data: re, encoding: .utf8)!
        XCTAssertFalse(str.contains("ignoredVersion"))
        XCTAssertFalse(str.contains("null"))
        XCTAssertEqual(try keys(re), [
            "trustInsecureCert", "autoCheckUpdate", "manualUploadDialogShown",
            "downloadRelativePath", "logViewLevelFilter",
            // Cycle 9 — auto-sync engine. Always encoded (Bool, no nil
            // semantics); fixture omits it and decode falls back to true.
            "autoApplyServerChanges",
            // Consent-push cycle — auto-read/push of the device pasteboard.
            // Always encoded (Bool); fixture omits it and decode falls back
            // to false (manual PasteButton push is the default).
            "autoPushDeviceChanges",
            // Cycle 12 — PayloadCache settings. Same Bool/Int defaulting
            // rule: fixture omits them and decode falls back to defaults.
            "prefetchAttachments", "prefetchOnCellular", "payloadCacheMaxBytes",
            // UI appearance preference (light/dark/system). Always encoded
            // as a raw String; decode falls back to .system when missing.
            "appearance",
            // Keyboard-extension feedback toggles. Always encoded (Bool);
            // fixture omits them and decode falls back to true (stock-keyboard
            // feel). Read by the keyboard via the App Group.
            "keyboardSoundFeedback", "keyboardHapticFeedback",
            // First-run onboarding flag. Always encoded (Bool); fixture omits
            // it and decode falls back to false (fresh install shows onboarding).
            "onboardingShown",
            // Home paste-permission hint dismissal. Always encoded (Bool).
            "pastePermissionHintDismissed",
            // Post-pairing enhancements carousel "shown once" flag. Always
            // encoded (Bool); fixture omits it and decode falls back to false.
            "enhancementsPromptShown",
        ])
    }

    func test_appSettings_acceptsUnknownKeys_forwardCompatibility() throws {
        let json = #"""
        {
          "trustInsecureCert": false,
          "autoCheckUpdate": true,
          "manualUploadDialogShown": false,
          "downloadRelativePath": "",
          "logViewLevelFilter": "info",
          "_schemaVersion": 7,
          "futureField": "tolerated"
        }
        """#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.logViewLevelFilter, "info")
    }

    func test_appSettings_fillsDefaultsForMissingKeys() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, .defaults)
    }

    func test_appSettings_persistenceKeysMatchSpec() {
        XCTAssertEqual(AppSettings.PersistenceKey.serverConfigList,   "server_config_list")
        XCTAssertEqual(AppSettings.PersistenceKey.appSettings,        "app_settings")
        XCTAssertEqual(AppSettings.PersistenceKey.legacyServerConfig, "server_config")
    }

    // MARK: - HistoryRecord wire fixtures (§3.6)

    func test_historyRecordText_decodesAllOptionalFields() throws {
        let data = try loadFixture("history_record_text")
        let record = try JSONDecoder().decode(HistoryRecord.self, from: data)

        XCTAssertEqual(record.type, .text)
        XCTAssertEqual(record.hash, "3F4E62D9F184380BAD1B0F94B5518DCBF35ACB79B34F6D6E34F3DAB16CD7BC8F")
        XCTAssertEqual(record.text, "Hello, SyncClipboard!")
        XCTAssertFalse(record.hasData)
        XCTAssertEqual(record.size, 21)
        XCTAssertNotNil(record.createTime)
        XCTAssertNotNil(record.lastModified)
        XCTAssertNotNil(record.lastAccessed)
        XCTAssertFalse(record.starred)
        XCTAssertFalse(record.pinned)
        XCTAssertEqual(record.version, 0)
        XCTAssertFalse(record.isDeleted)
    }

    func test_historyRecordText_roundTripPreservesISOTimestamps() throws {
        let data = try loadFixture("history_record_text")
        let decoded = try JSONDecoder().decode(HistoryRecord.self, from: data)
        let reEncoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(HistoryRecord.self, from: reEncoded)
        // Date equality holds to sub-millisecond because the fractional-ISO
        // formatter we encode through has millisecond resolution and the
        // fixture's timestamps already round to whole milliseconds.
        XCTAssertEqual(decoded, redecoded)
    }

    func test_historyRecordMinimal_fillsDefaults() throws {
        let data = try loadFixture("history_record_minimal")
        let record = try JSONDecoder().decode(HistoryRecord.self, from: data)

        XCTAssertEqual(record.type, .file)
        XCTAssertEqual(record.hash, "088EA33D054B64459EA2EB0CBD9F9152DD0BE4C38C6350963BBA00FDDC94CCEA")
        XCTAssertNil(record.text)
        XCTAssertFalse(record.hasData)
        XCTAssertNil(record.size)
        XCTAssertNil(record.createTime)
        XCTAssertNil(record.lastModified)
        XCTAssertNil(record.lastAccessed)
        XCTAssertFalse(record.starred)
        XCTAssertFalse(record.pinned)
        XCTAssertNil(record.version)
        XCTAssertFalse(record.isDeleted)
    }

    func test_historyRecordDeleted_isDeletedReadAndRoundTrip() throws {
        let data = try loadFixture("history_record_deleted")
        let record = try JSONDecoder().decode(HistoryRecord.self, from: data)

        XCTAssertTrue(record.isDeleted, "Read shape uses isDeleted (not isDelete)")
        XCTAssertEqual(record.version, 3)

        // Re-encoding must NOT introduce isDelete (no trailing d) — that
        // key is the PATCH-update-body convention, not the read shape.
        let reEncoded = try JSONEncoder().encode(record)
        let keys = try keys(reEncoded)
        XCTAssertTrue(keys.contains("isDeleted"))
        XCTAssertFalse(keys.contains("isDelete"))
    }

    func test_historyRecord_idIsCompositeTypeDashHash() {
        let r = HistoryRecord(hash: "ABCDEF", type: .text)
        XCTAssertEqual(r.id, "Text-ABCDEF")
        XCTAssertEqual(HistoryRecord.profileId(type: .image, hash: "XYZ"), "Image-XYZ")
    }

    /// The Android wire emits `…Z` timestamps; some hand-rolled servers
    /// truncate fractional seconds. Both shapes MUST decode.
    func test_historyRecord_decodesPlainISOWithoutFractionalSeconds() throws {
        let json = #"""
        {
          "hash": "AA",
          "type": "Text",
          "createTime": "2026-05-17T16:43:00Z"
        }
        """#
        let r = try JSONDecoder().decode(HistoryRecord.self, from: Data(json.utf8))
        XCTAssertNotNil(r.createTime)
    }

    /// Empty/whitespace timestamps decode to nil rather than throwing,
    /// matching the `hash` normalization on `Clipboard`.
    func test_historyRecord_emptyTimestampDecodesToNil() throws {
        let json = #"""
        {
          "hash": "AA",
          "type": "Text",
          "createTime": "",
          "lastModified": "   "
        }
        """#
        let r = try JSONDecoder().decode(HistoryRecord.self, from: Data(json.utf8))
        XCTAssertNil(r.createTime)
        XCTAssertNil(r.lastModified)
    }
}
