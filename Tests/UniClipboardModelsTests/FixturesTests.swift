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

    func test_suggestedSwitch_nilWhenCurrentItselfMatchesSSID() {
        // Current server A matches "Home". Even though non-default B also
        // matches, there's nothing to suggest — we're already on a server
        // that fits this network.
        let a = ServerConfig(id: "a", url: "http://a", username: "u", password: "p", autoSwitchWifiNames: ["Home"])
        let b = ServerConfig(id: "b", url: "http://b", username: "u", password: "p", autoSwitchWifiNames: ["Home"])
        let list = ServerConfigList(configs: [a, b], activeConfigId: "a")
        XCTAssertNil(list.suggestedSwitch(currentSsid: "Home"),
                     "no suggestion when the current server already matches")
    }

    func test_suggestedSwitch_returnsNonDefaultMatchWhenCurrentDoesNotMatch() {
        // Current A has no rule; B has "Home". On "Home" → suggest B.
        let a = ServerConfig(id: "a", url: "http://a", username: "u", password: "p")
        let b = ServerConfig(id: "b", url: "http://b", username: "u", password: "p", autoSwitchWifiNames: ["Home"])
        let list = ServerConfigList(configs: [a, b], activeConfigId: "a")
        XCTAssertEqual(list.suggestedSwitch(currentSsid: "Home")?.id, "b")
    }

    func test_suggestedSwitch_nilWhenSsidUnknownOrNoMatch() {
        let a = ServerConfig(id: "a", url: "http://a", username: "u", password: "p")
        let b = ServerConfig(id: "b", url: "http://b", username: "u", password: "p", autoSwitchWifiNames: ["Home"])
        let list = ServerConfigList(configs: [a, b], activeConfigId: "a")
        XCTAssertNil(list.suggestedSwitch(currentSsid: nil), "no SSID → no basis to suggest")
        XCTAssertNil(list.suggestedSwitch(currentSsid: "<unknown ssid>"))
        XCTAssertNil(list.suggestedSwitch(currentSsid: "Cafe"), "no rule matches → no suggestion")
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

    func test_suggestedSwitch_fromFixturePrefersNonDefaultMatch() throws {
        let data = try loadFixture("server_config_list")
        let list = try JSONDecoder().decode(ServerConfigList.self, from: data)
        // Active is config #3 (no SSIDs). Connected to "Home-5G" → suggest config #1.
        let suggestion = list.suggestedSwitch(currentSsid: "Home-5G")
        XCTAssertEqual(suggestion?.id, "0c1f2e3a-4b5c-6d7e-8f90-123456789abc")
    }

    func test_suggestedSwitch_fromFixtureNilWhenSsidUnknown() throws {
        let data = try loadFixture("server_config_list")
        let list = try JSONDecoder().decode(ServerConfigList.self, from: data)
        XCTAssertNil(list.suggestedSwitch(currentSsid: nil))
        XCTAssertNil(list.suggestedSwitch(currentSsid: "<unknown ssid>"))
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
