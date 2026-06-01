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
        // Read inside body so the Observation framework registers
        // `ContentView` as an observer of `ShortcutInbox.shared.pending`
        // — without this read, `.onChange` would never fire when the
        // delegate writes a runtime shortcut invocation.
        let pendingShortcut = ShortcutInbox.shared.pending

        return Group {
            if vm.servers.configs.isEmpty {
                SetupFlowView(vm: vm) {
                    // No-op: ContentView re-renders to TabView once configs is non-empty.
                }
            } else {
                mainTabs
            }
        }
        // Apply the user's appearance preference. `.system` resolves to
        // nil so SwiftUI releases the override and follows iOS. The
        // share-extension process reads the same setting in ShareRootView.
        .preferredColorScheme(vm.appSettings.appearance.colorScheme)
        // `.onOpenURL` fires on the root regardless of which branch is on
        // screen, including while a sheet/modal is up. The dispatcher in
        // AppViewModel stages the parsed payload (or error) into
        // observable state, and the relevant branch consumes it:
        //   • Setup branch reads `pendingImport` via its own `.task(id:)`
        //     and seeds the prefilled form step.
        //   • Tabs branch shows `ConnectImportSheet` below.
        .onOpenURL { vm.handleIncomingURL($0) }
        // Runtime path: app already on screen when a quick action fires.
        // The delegate writes to the inbox, body re-renders, onChange
        // sees the transition and dispatches. `initial: true` covers the
        // cold-launch case where the delegate wrote *before* SwiftUI
        // mounted, so `pendingShortcut` is non-nil on the very first
        // body evaluation and no nil→value transition will occur.
        .onChange(of: pendingShortcut, initial: true) { _, action in
            guard let action else { return }
            ShortcutInbox.shared.pending = nil
            Task { await vm.runShortcut(action) }
        }
        // Confirmation sheet — only meaningful when configs is non-empty.
        // While in Setup, the SetupFlowView's `.task(id:)` consumes
        // `pendingImport` first, so the sheet binding never fires.
        .sheet(item: $vm.pendingImport) { payload in
            ConnectImportSheet(
                payload: payload,
                onConfirm: { vm.acceptPendingImport(payload) },
                onCancel: { vm.pendingImport = nil }
            )
            .presentationDetents([.medium, .large])
        }
        .alert(
            "无法识别该二维码",
            isPresented: Binding(
                get: { vm.importError != nil },
                set: { if !$0 { vm.importError = nil } }
            ),
            presenting: vm.importError
        ) { _ in
            Button("好") { vm.importError = nil }
        } message: { err in
            Text(connectURIErrorMessage(err))
        }
    }

    private var mainTabs: some View {
        TabView(selection: $selection) {
            NavigationStack {
                HomeView(vm: vm, onGoToSettings: { selection = 1 })
            }
            .tabItem { Label("剪贴板", systemImage: "doc.on.clipboard.fill") }
            .tag(0)

            NavigationStack(path: $settingsPath) {
                SettingsView(vm: vm, path: $settingsPath)
            }
            .tabItem { Label("设置", systemImage: "gearshape.fill") }
            .tag(1)
        }
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
            if env["UC_AUTO_PUSH"] == "1" {
                // Auto-push is opt-in now (default off — the headline push
                // path is the Home PasteButton). The screenshot recipe wants
                // the engine to push the env-seeded pasteboard, so enable the
                // opt-in for this run before kicking the tick.
                vm.appSettings.autoPushDeviceChanges = true
            }
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
                vm.engine.isSceneInactive = false
                vm.engine.start()
            case .background:
                vm.engine.stop()
            case .inactive:
                // .inactive covers Control Center pull-down, incoming
                // calls, app switcher previews, etc. The system
                // pasteboard is still reachable, so we keep the loop
                // running — but at a reduced cadence (5s) so a
                // long-running .inactive (an answered call) doesn't
                // burn battery on per-second polling.
                vm.engine.isSceneInactive = true
            @unknown default: break
            }
        }
    }
}

#Preview {
    ContentView(vm: .preview())
}
