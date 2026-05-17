import XCTest
@testable import UniClipboardModels

final class SettingsStoreTests: XCTestCase {

    // MARK: - helpers

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        XCTAssertNotNil(defaults, "Failed to create test UserDefaults suite")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> SettingsStore {
        SettingsStore(defaults: defaults)
    }

    private func seed(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    private func seedJSON<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try JSONEncoder().encode(value)
        defaults.set(data, forKey: key)
    }

    // MARK: - T1: empty defaults → defaults

    func test_loadServers_whenEmptyDefaults_returnsEmptyList() {
        let store = makeStore()
        let list = store.loadServers()
        XCTAssertTrue(list.configs.isEmpty)
        XCTAssertNil(list.activeConfigId)
    }

    func test_loadAppSettings_whenEmptyDefaults_returnsDefaults() {
        let store = makeStore()
        XCTAssertEqual(store.loadAppSettings(), AppSettings.defaults)
    }

    // MARK: - T2: round-trip

    func test_servers_saveThenLoad_isRoundTripEqual() {
        let store = makeStore()
        let original = ServerConfigList(
            configs: [
                ServerConfig(
                    id: "abc",
                    name: "NAS",
                    url: "https://nas.lan/",
                    username: "u",
                    password: "p",
                    autoSwitchWifiNames: ["Home"]
                )
            ],
            activeConfigId: "abc"
        )

        store.saveServers(original)
        XCTAssertEqual(store.loadServers(), original)
    }

    func test_appSettings_saveThenLoad_isRoundTripEqual() {
        let store = makeStore()
        let original = AppSettings(
            trustInsecureCert: true,
            autoCheckUpdate: false,
            manualUploadDialogShown: true,
            downloadRelativePath: "Inbox",
            logViewLevelFilter: "warn",
            ignoredVersion: "1.2.3"
        )

        store.saveAppSettings(original)
        XCTAssertEqual(store.loadAppSettings(), original)
    }

    // MARK: - T3: legacy migration

    func test_loadServers_whenOnlyLegacyKeyPresent_migratesAndDropsLegacy() throws {
        let legacy = LegacyServerConfig(
            url: "https://legacy.example.com/",
            username: "user",
            password: "pw"
        )
        try seedJSON(legacy, forKey: AppSettings.PersistenceKey.legacyServerConfig)

        let store = makeStore()
        let migrated = store.loadServers()

        XCTAssertEqual(migrated.configs.count, 1)
        let cfg = try XCTUnwrap(migrated.configs.first)
        XCTAssertEqual(cfg.url, legacy.url)
        XCTAssertEqual(cfg.username, legacy.username)
        XCTAssertEqual(cfg.password, legacy.password)
        XCTAssertNil(cfg.name)
        XCTAssertEqual(cfg.autoSwitchWifiNames, [])
        XCTAssertEqual(migrated.activeConfigId, cfg.id, "Migrated config must be marked active")

        XCTAssertNotNil(
            defaults.data(forKey: AppSettings.PersistenceKey.serverConfigList),
            "New key must be written"
        )
        XCTAssertNil(
            defaults.data(forKey: AppSettings.PersistenceKey.legacyServerConfig),
            "Legacy key must be removed after migration"
        )

        let secondLoad = store.loadServers()
        XCTAssertEqual(secondLoad, migrated, "Subsequent loads return the migrated list as-is")
    }

    // MARK: - T4: both keys → new wins

    func test_loadServers_whenBothKeysPresent_newWinsAndLegacyUntouched() throws {
        let newList = ServerConfigList(
            configs: [
                ServerConfig(id: "new", url: "https://new/", username: "n", password: "n")
            ],
            activeConfigId: "new"
        )
        try seedJSON(newList, forKey: AppSettings.PersistenceKey.serverConfigList)

        let legacy = LegacyServerConfig(url: "https://old/", username: "o", password: "o")
        try seedJSON(legacy, forKey: AppSettings.PersistenceKey.legacyServerConfig)

        let store = makeStore()
        XCTAssertEqual(store.loadServers(), newList)
        XCTAssertNotNil(
            defaults.data(forKey: AppSettings.PersistenceKey.legacyServerConfig),
            "Legacy key must be left alone when the new key is present"
        )
    }

    // MARK: - T5/T6: corrupt JSON → defaults

    func test_loadServers_whenJSONIsCorrupt_returnsEmptyList() {
        seed(Data("not json".utf8), forKey: AppSettings.PersistenceKey.serverConfigList)
        let store = makeStore()
        XCTAssertEqual(store.loadServers(), ServerConfigList())
    }

    func test_loadAppSettings_whenJSONIsCorrupt_returnsDefaults() {
        seed(Data("not json".utf8), forKey: AppSettings.PersistenceKey.appSettings)
        let store = makeStore()
        XCTAssertEqual(store.loadAppSettings(), AppSettings.defaults)
    }

    // MARK: - T7: forward-compat — partial appSettings JSON fills in defaults

    // MARK: - T8: clipboard history round-trip + corruption

    func test_loadHistory_whenEmptyDefaults_returnsEmptyArray() {
        let store = makeStore()
        XCTAssertEqual(store.loadHistory(), [])
    }

    func test_history_saveThenLoad_preservesOrderIdsAndDirections() {
        let store = makeStore()
        let items: [ClipboardHistoryItem] = [
            ClipboardHistoryItem(
                entry: Clipboard(type: .text, hash: nil, text: "first", hasData: false, size: 5),
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                direction: .pulled
            ),
            ClipboardHistoryItem(
                entry: Clipboard(
                    type: .image,
                    hash: "AA11BB22",
                    text: "snap.png",
                    hasData: true,
                    dataName: "snap.png",
                    size: 1024
                ),
                timestamp: Date(timeIntervalSince1970: 1_700_000_100),
                direction: .pushed
            ),
        ]
        store.saveHistory(items)
        // ID stability is the whole reason `id` is `var` — without that,
        // a Codable round-trip mints fresh UUIDs and the SwiftUI list
        // ForEach loses its diffing identity on every cold launch.
        XCTAssertEqual(store.loadHistory(), items)
    }

    func test_saveHistory_emptyArray_persistsAndRoundTrips() {
        let store = makeStore()
        let seed = [
            ClipboardHistoryItem(
                entry: Clipboard(type: .text, text: "x", hasData: false),
                timestamp: Date(timeIntervalSince1970: 0),
                direction: .pulled
            )
        ]
        store.saveHistory(seed)
        XCTAssertEqual(store.loadHistory().count, 1)
        store.saveHistory([])
        XCTAssertEqual(store.loadHistory(), [])
    }

    func test_loadHistory_whenJSONIsCorrupt_returnsEmptyArray() {
        seed(Data("not json".utf8), forKey: AppSettings.PersistenceKey.clipboardHistory)
        let store = makeStore()
        XCTAssertEqual(store.loadHistory(), [])
    }

    // MARK: - T9: history watermark

    func test_loadHistoryWatermark_whenEmpty_returnsNil() {
        let store = makeStore()
        XCTAssertNil(store.loadHistoryWatermark())
    }

    func test_historyWatermark_saveThenLoad_roundTripsToMillisecond() {
        let store = makeStore()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: "2026-05-17T16:43:21.420Z")!
        store.saveHistoryWatermark(date)
        XCTAssertEqual(store.loadHistoryWatermark(), date)
    }

    func test_historyWatermark_nilClearsTheKey() {
        let store = makeStore()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        store.saveHistoryWatermark(date)
        XCTAssertNotNil(store.loadHistoryWatermark())
        store.saveHistoryWatermark(nil)
        XCTAssertNil(store.loadHistoryWatermark())
        XCTAssertNil(defaults.string(forKey: AppSettings.PersistenceKey.historyModifiedAfter))
    }

    func test_historyWatermark_acceptsPlainISOWithoutFractionalSeconds() {
        // Hand-rolled servers / DB exports sometimes truncate fractional
        // seconds. The loader MUST still parse.
        seed("2026-05-17T16:43:21Z", forKey: AppSettings.PersistenceKey.historyModifiedAfter)
        let store = makeStore()
        XCTAssertNotNil(store.loadHistoryWatermark())
    }

    func test_historyWatermark_corruptStringReturnsNil() {
        seed("not a date", forKey: AppSettings.PersistenceKey.historyModifiedAfter)
        let store = makeStore()
        XCTAssertNil(store.loadHistoryWatermark())
    }

    func test_loadAppSettings_whenJSONIsPartial_missingKeysGetDefaults() throws {
        let partial = "{ \"trustInsecureCert\": true }"
        seed(Data(partial.utf8), forKey: AppSettings.PersistenceKey.appSettings)

        let store = makeStore()
        let loaded = store.loadAppSettings()

        XCTAssertEqual(loaded.trustInsecureCert, true, "Present key preserved")
        XCTAssertEqual(loaded.autoCheckUpdate, AppSettings.defaults.autoCheckUpdate)
        XCTAssertEqual(loaded.manualUploadDialogShown, AppSettings.defaults.manualUploadDialogShown)
        XCTAssertEqual(loaded.downloadRelativePath, AppSettings.defaults.downloadRelativePath)
        XCTAssertEqual(loaded.logViewLevelFilter, AppSettings.defaults.logViewLevelFilter)
        XCTAssertNil(loaded.ignoredVersion)
    }
}
