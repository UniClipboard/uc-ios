import SwiftUI

struct ContentView: View {
    @Bindable var vm: AppViewModel

    @State private var selection: Int = Self.initialTab

    private static var initialTab: Int {
        guard let i = ProcessInfo.processInfo.environment["UC_INIT_TAB"].flatMap(Int.init) else {
            return 0
        }
        return max(0, min(2, i))
    }

    var body: some View {
        if vm.servers.configs.isEmpty {
            SetupFlowView(vm: vm) {
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
                        vm: vm,
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
                    SettingsView(vm: vm)
                }
            }
        }
        .tint(.indigo)
    }
}

#Preview {
    ContentView(vm: .preview())
}
