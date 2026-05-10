import Foundation
import Observation

/// Owns the app's persisted state and writes mutations back to disk
/// automatically. Sits between the views and `SettingsStore`.
///
/// Lives in the app layer (not in the SwiftPM `Models` target) because
/// `@Observable` and `@MainActor` are SwiftUI-shaped concerns; the model
/// types it carries (`ServerConfigList`, `AppSettings`) are the
/// Foundation-only ones from `Models/`.
@MainActor
@Observable
final class AppViewModel {
    var servers: ServerConfigList {
        didSet { store.saveServers(servers) }
    }

    var appSettings: AppSettings {
        didSet { store.saveAppSettings(appSettings) }
    }

    /// Last clipboard fetched from the active server. Runtime state, not
    /// persisted — spec §5.5 doesn't list a key for it and stale data on
    /// cold launch would mislead.
    var serverLatest: Clipboard?

    /// When `serverLatest` was last refreshed (success or 404). Reset on
    /// every `refresh()` outcome so the UI's "5 minutes ago" label tracks
    /// reality.
    var lastSyncedAt: Date?

    /// Last error from `refresh()`. Cleared on success.
    var refreshError: SyncError?

    /// Whether a refresh is in flight.
    var isRefreshing: Bool = false

    /// When the device clipboard was last successfully pushed to the
    /// active server. Runtime state — not persisted. Cleared on push
    /// failure so the UI doesn't show a misleading "上次推送 5 秒前"
    /// next to a fresh error banner.
    var lastPushedAt: Date?

    /// Last error from `push()`. Cleared on success.
    var pushError: SyncError?

    /// Whether a push is in flight.
    var isPushing: Bool = false

    /// Whether `applyServerToDevice()` is in flight (long-text path only;
    /// short text completes synchronously and never sets this).
    var isApplying: Bool = false

    /// Last error from `applyServerToDevice()`. Cleared on success.
    var applyError: SyncError?

    /// Whether `saveServerAttachment()` is in flight.
    var isSaving: Bool = false

    /// Last error from `saveServerAttachment()`. Cleared on success.
    var saveError: SyncError?

    /// File URL of the most-recent successful `saveServerAttachment()`.
    /// Cleared on the next refresh or save attempt so the UI's
    /// "已保存到 …" caption doesn't outlive its relevance.
    var lastSavedFileURL: URL?

    /// Current device pasteboard snapshot. Computed; the observer is the
    /// source of truth and `@Observable` propagates its `current` reads
    /// through this accessor automatically.
    var deviceClipboard: Clipboard? { pasteboard.current }

    @ObservationIgnored
    private let store: SettingsStore

    @ObservationIgnored
    private let pasteboard: DevicePasteboardObserver

    /// - Parameters:
    ///   - store: persistence backend; default uses `UserDefaults.standard`.
    ///   - forceFreshServers: when true, ignore stored servers and start
    ///     with an empty list (drives the SetupFlow). Defaults to reading
    ///     `UC_FRESH=1` from the environment so screenshot recipes work.
    ///   - pasteboard: device pasteboard observer; default reads
    ///     `UIPasteboard.general` (or honors `UC_DEVICE_TEXT` env hook).
    init(
        store: SettingsStore = SettingsStore(),
        forceFreshServers: Bool = ProcessInfo.processInfo.environment["UC_FRESH"] == "1",
        pasteboard: DevicePasteboardObserver? = nil
    ) {
        // `DevicePasteboardObserver` is `@MainActor`, so its default value
        // must be constructed inside the init body — default-argument
        // expressions are evaluated in a nonisolated context.
        self.store = store
        self.pasteboard = pasteboard ?? DevicePasteboardObserver()
        self.servers = forceFreshServers ? ServerConfigList() : store.loadServers()
        self.appSettings = store.loadAppSettings()
    }

    /// Re-read the device pasteboard. Triggered by toolbar refresh and
    /// pull-to-refresh; foreground / pasteboard-changed notifications
    /// re-read automatically.
    func readPasteboard() { pasteboard.read() }

    /// Write the active server's text clipboard to the device. Short
    /// text (`hasData=false`) writes synchronously from the metadata
    /// `text` field. Long text (`hasData=true`) downloads the §2.4
    /// payload, verifies the §4.4 hash, decodes UTF-8, and writes the
    /// result. Image/file/group entries are no-ops — apply means "write
    /// to device pasteboard" and binary entries need UTI handling that
    /// pairs with the image-push cycle.
    func applyServerToDevice() async {
        guard let entry = serverLatest, entry.type == .text else { return }
        if !entry.hasData {
            pasteboard.write(text: entry.text)
            applyError = nil
            return
        }
        guard !isApplying else { return }
        guard let server = servers.activeConfig, let dataName = entry.dataName else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: appSettings.trustInsecureCert)
            let bytes = try await client.getFile(name: dataName)
            try Self.verify(bytes: bytes, against: entry.hash)
            let text = String(decoding: bytes, as: UTF8.self)
            pasteboard.write(text: text)
            applyError = nil
        } catch let e as SyncError {
            applyError = e
        } catch {
            applyError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    /// Download an image or file server entry's payload and write it to
    /// `Documents/<sanitized downloadRelativePath>/<dataName>`. Group
    /// entries are out of scope this cycle (§4.3 ZIP-traversal hash is
    /// its own slice). Overwrites on collision — matches Files-app
    /// behavior.
    func saveServerAttachment() async {
        guard !isSaving else { return }
        guard let entry = serverLatest,
              entry.hasData,
              entry.type == .image || entry.type == .file,
              let dataName = entry.dataName,
              let server = servers.activeConfig
        else { return }
        isSaving = true
        defer { isSaving = false }
        lastSavedFileURL = nil
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: appSettings.trustInsecureCert)
            let bytes = try await client.getFile(name: dataName)
            try Self.verify(bytes: bytes, against: entry.hash)
            let url = try Self.targetURL(for: dataName, relative: appSettings.downloadRelativePath)
            try bytes.write(to: url, options: .atomic)
            lastSavedFileURL = url
            saveError = nil
        } catch let e as SyncError {
            saveError = e
        } catch {
            saveError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    private static func verify(bytes: Data, against expected: String?) throws {
        // §4.4: null/whitespace `expected` matches anything — short-circuits
        // here because hashMatches returns true in that case, never throws.
        let actual = Clipboard.computeBytesHash(bytes)
        guard Clipboard.hashMatches(expected: expected, actual: actual) else {
            throw SyncError(kind: .hashMismatch)
        }
    }

    private static func targetURL(for dataName: String, relative: String) throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Sanitize against container escape and weird input. Drops `..`,
        // `.`, and empty segments; strips leading/trailing slashes by virtue
        // of the split. Trailing-slash and leading-slash users still get
        // their intended subdir.
        let sanitized = relative
            .split(separator: "/")
            .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
            .map(String.init)
        var dir = docs
        for segment in sanitized {
            dir.appendPathComponent(segment, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(dataName, isDirectory: false)
    }
}

extension AppViewModel {
    /// Publish the device clipboard to the active server. Spec §2.2 +
    /// §2.3 + §3.4 + §3.5. Text-only this cycle.
    /// - Returns silently if no active server, no device clipboard, or
    ///   already pushing.
    /// - Long text (>10240 chars) goes file-first per §3.5; failures in
    ///   the file PUT skip the metadata PUT so the server never sees a
    ///   metadata pointer to a missing file.
    /// - On success, optimistically updates `serverLatest` to the
    ///   metadata-only entry so the server card reflects reality without
    ///   a follow-up GET.
    func push() async {
        guard !isPushing else { return }
        guard let server = servers.activeConfig else { return }
        guard let device = deviceClipboard, device.type == .text else { return }
        isPushing = true
        defer { isPushing = false }
        let trustInsecure = appSettings.trustInsecureCert
        let (entry, payload) = Clipboard.publishText(device.text)
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: trustInsecure)
            if let payload, let dataName = entry.dataName {
                try await client.putFile(name: dataName, body: payload)
            }
            try await client.putClipboard(entry)
            serverLatest = entry
            lastSyncedAt = .now
            lastPushedAt = .now
            pushError = nil
            refreshError = nil
        } catch let e as SyncError {
            pushError = e
        } catch {
            pushError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    /// Pull the active server's latest clipboard. Spec §2.1.
    /// - 404 is the documented empty state — clears `serverLatest`,
    ///   updates `lastSyncedAt`, leaves `refreshError` nil.
    /// - Other errors keep the previous `serverLatest` (stale > blank)
    ///   and surface via `refreshError`.
    /// - No active config → spec §5.2 forbids the call; returns silently.
    func refresh() async {
        guard let server = servers.activeConfig else { return }
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // The "已保存到 …" caption is bound to the last save attempt, not
        // the server-side state. A refresh changes what's on screen, so the
        // caption no longer matches the entry above it — clear it.
        lastSavedFileURL = nil
        let trustInsecure = appSettings.trustInsecureCert
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: trustInsecure)
            let clip = try await client.getClipboard()
            serverLatest = clip
            lastSyncedAt = .now
            refreshError = nil
        } catch let e as SyncError where e.kind == .notFound {
            serverLatest = nil
            lastSyncedAt = .now
            refreshError = nil
        } catch let e as SyncError {
            refreshError = e
        } catch {
            refreshError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    /// Builds a VM bound to an isolated `UserDefaults` suite — for use in
    /// `#Preview` blocks so previews don't read or write `.standard`.
    /// `deviceText: nil` keeps the device pasteboard empty in the preview;
    /// pass a string to seed `vm.deviceClipboard` without touching the
    /// real `UIPasteboard.general`.
    static func preview(
        servers: ServerConfigList = Mock.servers,
        appSettings: AppSettings = AppSettings(
            manualUploadDialogShown: true,
            downloadRelativePath: "SyncClipboard/Inbox",
            ignoredVersion: "0.3.2"
        ),
        deviceText: String? = nil
    ) -> AppViewModel {
        let suite = UserDefaults(suiteName: "AppViewModel.preview-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: suite)
        store.saveServers(servers)
        store.saveAppSettings(appSettings)
        let pasteboardEnv: [String: String] = ["UC_DEVICE_TEXT": deviceText ?? ""]
        let pasteboard = DevicePasteboardObserver(environment: pasteboardEnv)
        return AppViewModel(store: store, forceFreshServers: false, pasteboard: pasteboard)
    }
}
