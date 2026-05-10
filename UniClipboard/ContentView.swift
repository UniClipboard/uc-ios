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
                    HomeView(vm: vm)
                        .task {
                            await vm.refresh()
                            // DEBUG hooks for simctl regression — see CLAUDE.md.
                            // Not feature flags; remove on ship.
                            let env = ProcessInfo.processInfo.environment
                            if env["UC_AUTO_PUSH"] == "1" {
                                await vm.push()
                            }
                            if env["UC_AUTO_APPLY"] == "1" {
                                await vm.applyServerToDevice()
                            }
                            if env["UC_AUTO_SAVE"] == "1" {
                                await vm.saveServerAttachment()
                            }
                        }
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
