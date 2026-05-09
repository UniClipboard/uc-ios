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

    @ObservationIgnored
    private let store: SettingsStore

    /// - Parameters:
    ///   - store: persistence backend; default uses `UserDefaults.standard`.
    ///   - forceFreshServers: when true, ignore stored servers and start
    ///     with an empty list (drives the SetupFlow). Defaults to reading
    ///     `UC_FRESH=1` from the environment so screenshot recipes work.
    init(
        store: SettingsStore = SettingsStore(),
        forceFreshServers: Bool = ProcessInfo.processInfo.environment["UC_FRESH"] == "1"
    ) {
        self.store = store
        self.servers = forceFreshServers ? ServerConfigList() : store.loadServers()
        self.appSettings = store.loadAppSettings()
    }
}

extension AppViewModel {
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
    static func preview(
        servers: ServerConfigList = Mock.servers,
        appSettings: AppSettings = AppSettings(
            manualUploadDialogShown: true,
            downloadRelativePath: "SyncClipboard/Inbox",
            ignoredVersion: "0.3.2"
        )
    ) -> AppViewModel {
        let suite = UserDefaults(suiteName: "AppViewModel.preview-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: suite)
        store.saveServers(servers)
        store.saveAppSettings(appSettings)
        return AppViewModel(store: store, forceFreshServers: false)
    }
}
