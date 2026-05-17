import SwiftUI

struct ContentView: View {
    @Bindable var vm: AppViewModel

    @State private var selection: Int = Self.initialTab

    /// Path for the Settings tab's NavigationStack. Initial value lets a
    /// `UC_SETTINGS_ROUTE=servers` env hook deep-link into the Servers
    /// list (or `servers/edit/<idx>` to land on the editor) — needed
    /// because simctl can't synthesize taps for screenshot recipes.
    @State private var settingsPath: [SettingsRoute] = SettingsRoute.initialPath()

    @Environment(\.scenePhase) private var scenePhase

    private static var initialTab: Int {
        guard let i = ProcessInfo.processInfo.environment["UC_INIT_TAB"].flatMap(Int.init) else {
            return 0
        }
        return max(0, min(1, i))
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
                    HomeView(vm: vm, onGoToSettings: { selection = 1 })
                }
            }
            Tab("设置", systemImage: "gearshape.fill", value: 1) {
                NavigationStack(path: $settingsPath) {
                    SettingsView(vm: vm, path: $settingsPath)
                }
            }
        }
        .tint(.indigo)
        .task {
            // Unblock pasteboard reads before the engine ticks — the
            // engine's push path reads UIPasteboard via snapshot(), and
            // gating activation here is what defers the iOS "Allow Paste"
            // prompt past the Setup flow into the home tab.
            vm.activatePasteboard()
            vm.engine.start()
            // simctl regression hooks — not feature flags. The engine
            // already handles push/apply automatically via the 1Hz loop;
            // these just kick off an immediate first tick so test recipes
            // don't have to wait the full cadence before screenshotting.
            // UC_AUTO_SAVE stays a direct call: saving to Documents is a
            // discrete user action, not part of the auto-sync loop.
            let env = ProcessInfo.processInfo.environment
            if env["UC_AUTO_PUSH"] == "1" || env["UC_AUTO_APPLY"] == "1" {
                vm.engine.forceTickNow()
            }
            if env["UC_AUTO_SAVE"] == "1" {
                await vm.saveServerAttachment()
            }
            // §2.11 regression hook: after the first history-sync wave
            // populates `vm.history`, save the first image/file entry
            // via the history endpoint. Sleep is intentional — simctl
            // recipes have no way to observe `vm.history` mutations,
            // so a small grace window beats polling here.
            if env["UC_AUTO_SAVE_HISTORY"] == "1" {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let target = vm.history.first(where: {
                    $0.entry.hasData && ($0.entry.type == .image || $0.entry.type == .file)
                }) {
                    await vm.saveAttachment(for: target)
                }
            }
            // §2.11 + UIPasteboard regression hook: same grace window
            // as save, but targets an image-type history row and writes
            // back to the device pasteboard. file-type rows aren't valid
            // — `applyAttachment` rejects them.
            if env["UC_AUTO_APPLY_HISTORY"] == "1" {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let target = vm.history.first(where: {
                    $0.entry.hasData && $0.entry.type == .image
                }) {
                    await vm.applyAttachment(for: target)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Refresh SSID before the engine reads `effectiveActiveConfig`
                // so a Wi-Fi flip while the app was backgrounded surfaces
                // on the first foreground tick instead of one cycle later.
                vm.ssidProvider.refresh()
                vm.engine.start()
            case .background: vm.engine.stop()
            case .inactive:   break  // brief — Notification Center pull-down etc; keep ticking
            @unknown default: break
            }
        }
    }
}

#Preview {
    ContentView(vm: .preview())
}
