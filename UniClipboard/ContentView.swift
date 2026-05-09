import SwiftUI

struct ContentView: View {
    @State private var servers: ServerConfigList = Self.initialServers
    @State private var appSettings: AppSettings = AppSettings(
        manualUploadDialogShown: true,
        downloadRelativePath: "SyncClipboard/Inbox",
        ignoredVersion: "0.3.2"
    )
    @State private var selection: Int = Self.initialTab

    private static var initialTab: Int {
        guard let i = ProcessInfo.processInfo.environment["UC_INIT_TAB"].flatMap(Int.init) else {
            return 0
        }
        return max(0, min(2, i))
    }

    private static var initialServers: ServerConfigList {
        if ProcessInfo.processInfo.environment["UC_FRESH"] == "1" {
            return ServerConfigList()
        }
        return Mock.servers
    }

    var body: some View {
        if servers.configs.isEmpty {
            SetupFlowView(servers: $servers) {
                // No-op: ContentView re-renders to TabView once configs is non-empty.
            }
            .tint(.indigo)
        } else {
            mainTabs
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selection) {
            Tab("剪贴板", systemImage: "doc.on.clipboard.fill", value: 0) {
                NavigationStack {
                    HomeView(
                        servers: $servers,
                        serverLatest: Mock.serverLatest,
                        serverLastSyncedAt: Mock.serverLastSyncedAt,
                        deviceClipboard: Mock.deviceClipboard
                    )
                }
            }
            Tab("历史", systemImage: "clock.fill", value: 1) {
                NavigationStack {
                    HistoryView()
                }
            }
            Tab("设置", systemImage: "gearshape.fill", value: 2) {
                NavigationStack {
                    SettingsView(servers: $servers, appSettings: $appSettings)
                }
            }
        }
        .tint(.indigo)
    }
}

#Preview {
    ContentView()
}
