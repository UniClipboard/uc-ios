import SwiftUI

/// Routes for the Settings tab's NavigationStack. Hashable so they can
/// drive `NavigationLink(value:)` and live in a stack path.
enum SettingsRoute: Hashable {
    case servers
    case serverEdit(index: Int)

    /// `UC_SETTINGS_ROUTE` env hook — lets screenshot recipes deep-link
    /// past the Settings root since simctl has no synthetic-tap.
    static func initialPath() -> [SettingsRoute] {
        let env = ProcessInfo.processInfo.environment["UC_SETTINGS_ROUTE"] ?? ""
        switch env {
        case "servers":
            return [.servers]
        case let s where s.hasPrefix("servers/edit/"):
            let idx = Int(s.dropFirst("servers/edit/".count)) ?? 0
            return [.servers, .serverEdit(index: idx)]
        default:
            return []
        }
    }
}

struct SettingsView: View {
    @Bindable var vm: AppViewModel
    @Binding var path: [SettingsRoute]

    private var ssidProvider: CurrentSSIDProvider { vm.ssidProvider }

    var body: some View {
        List {
            Section("同步") {
                NavigationLink(value: SettingsRoute.servers) {
                    HStack {
                        Label("服务器列表", systemImage: "server.rack")
                        Spacer()
                        Text("\(vm.servers.configs.count) 个")
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $vm.appSettings.trustInsecureCert) {
                    Label("允许不安全证书", systemImage: "lock.open")
                }
            }

            Section {
                Toggle(isOn: $vm.appSettings.autoApplyServerChanges) {
                    Label("自动写入本机剪贴板", systemImage: "doc.on.clipboard")
                }
            } header: {
                Text("行为")
            } footer: {
                Text("开启后，服务器有新内容时会立即覆盖本机剪贴板；关闭则只在主页高亮提示，不修改剪贴板。")
                    .font(.caption)
            }

            Section {
                Toggle(isOn: $vm.appSettings.autoPushDeviceChanges) {
                    Label("自动推送本机剪贴板", systemImage: "arrow.up.doc")
                }
            } footer: {
                Text("关闭（推荐）：在主页用「粘贴」按钮一键推送，iOS 不会弹窗。开启后会自动读取并推送本机复制的内容——iOS 在读取其他 App 复制的内容时会弹出「允许粘贴」确认。")
                    .font(.caption)
            }

            Section {
                NavigationLink {
                    KeyboardSetupView(appSettings: $vm.appSettings)
                } label: {
                    Label("键盘与自动同步", systemImage: "keyboard")
                }
            } footer: {
                Text("用 UniClip 键盘在任意 App 里打开即自动同步剪贴板；并可在此授权「粘贴自其他 App」。")
                    .font(.caption)
            }

            Section {
                Toggle(isOn: $vm.appSettings.autoCheckUpdate) {
                    Label("启动时检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                NavigationLink {
                    Form {
                        TextField("下载子目录", text: $vm.appSettings.downloadRelativePath)
                            .textInputAutocapitalization(.never)
                    }
                    .navigationTitle("下载路径")
                } label: {
                    HStack {
                        Label("下载路径", systemImage: "folder")
                        Spacer()
                        Text(vm.appSettings.downloadRelativePath.isEmpty ? String(localized: "默认") : vm.appSettings.downloadRelativePath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            StorageSettingsSection(appSettings: $vm.appSettings)

            Section {
                Picker(selection: $vm.appSettings.appearance) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.localizedLabel).tag(mode)
                    }
                } label: {
                    Label("主题", systemImage: "circle.lefthalf.filled")
                }
                .pickerStyle(.menu)
            } header: {
                Text("外观")
            }

            Section("诊断") {
                NavigationLink {
                    LogsPlaceholderView()
                } label: {
                    Label("日志", systemImage: "doc.text.magnifyingglass")
                }
                NavigationLink {
                    AboutView(appSettings: $vm.appSettings)
                } label: {
                    Label("关于", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("设置")
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .servers:
                ServersListView(
                    servers: $vm.servers,
                    trustInsecureCert: $vm.appSettings.trustInsecureCert,
                    ssidProvider: ssidProvider
                )
            case .serverEdit(let index):
                // Bounds-check defensively because deep-link env hooks
                // can specify an invalid index after configs change.
                if vm.servers.configs.indices.contains(index) {
                    ServerEditView(
                        server: $vm.servers.configs[index],
                        trustInsecureCert: $vm.appSettings.trustInsecureCert,
                        ssidProvider: ssidProvider,
                        existingNames: Set(
                            vm.servers.configs
                                .enumerated()
                                .lazy
                                .filter { $0.offset != index }
                                .compactMap { $0.element.name }
                        )
                    )
                } else {
                    Text("服务器已不存在")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Servers list

private struct ServersListView: View {
    @Binding var servers: ServerConfigList
    @Binding var trustInsecureCert: Bool
    let ssidProvider: CurrentSSIDProvider

    @State private var pendingDelete: ServerConfig?
    @State private var addDraft: ServerDraft?
    @State private var scannerPresented: Bool =
        ProcessInfo.processInfo.environment["UC_OPEN_QR_SCANNER"] == "1"

    var body: some View {
        List {
            Section {
                if servers.configs.isEmpty {
                    Text("还没有服务器")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                } else {
                    ForEach($servers.configs) { $server in
                        NavigationLink {
                            ServerEditView(
                                server: $server,
                                trustInsecureCert: $trustInsecureCert,
                                ssidProvider: ssidProvider,
                                existingNames: existingNames(excludingId: server.id)
                            )
                        } label: {
                            ServerRow(
                                server: server,
                                isActive: server.id == servers.activeConfigId
                            )
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            // No `role: .destructive` here — that triggers
                            // SwiftUI's row-removal animation immediately on
                            // tap, which conflicts with the confirmation
                            // alert (row collapses, then snaps back when the
                            // data source is unchanged). `.tint(.red)` keeps
                            // the destructive look without the auto-anim.
                            Button {
                                pendingDelete = server
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                            .tint(.red)
                            if server.id != servers.activeConfigId {
                                Button {
                                    servers.activeConfigId = server.id
                                } label: {
                                    Label("设为当前服务器", systemImage: "checkmark.circle")
                                }
                                .tint(.green)
                            }
                        }
                    }
                }
            } footer: {
                Text("左滑可设为当前服务器或删除。WiFi 自动切换：连接到匹配 SSID 时会提示切换到该服务器。")
                    .font(.caption)
            }

            Section {
                Button {
                    addDraft = ServerDraft(existingNames: existingNames(excludingId: ""))
                } label: {
                    Label("添加服务器", systemImage: "plus.circle.fill")
                }
                Button {
                    scannerPresented = true
                } label: {
                    Label("扫一扫", systemImage: "qrcode.viewfinder")
                }
            }
        }
        .navigationTitle("服务器列表")
        .task {
            if ProcessInfo.processInfo.environment["UC_OPEN_ADD_SHEET"] == "1" {
                addDraft = ServerDraft(existingNames: existingNames(excludingId: ""))
            }
        }
        .sheet(item: $addDraft) { draft in
            // Seed the sheet with the presented draft and let it own the
            // edit buffer internally. We deliberately do NOT hand it a
            // Binding back to `addDraft`: a trailing field commit during
            // the dismiss animation would flow through that Binding's
            // setter and — because the getter synthesizes a fresh draft
            // when `addDraft == nil` — resurrect `addDraft` into a new
            // blank draft, re-presenting the sheet as if "add another".
            AddServerSheet(
                draft: draft,
                trustInsecureCert: $trustInsecureCert,
                ssidProvider: ssidProvider,
                onCancel: { addDraft = nil },
                onSave: { saved in
                    commit(draft: saved)
                    addDraft = nil
                }
            )
        }
        .fullScreenCover(isPresented: $scannerPresented) {
            QRScannerView(
                onScan: { payload in
                    scannerPresented = false
                    // Defer the sheet present by a tick so the cover has
                    // time to dismiss — stacking presentations on the same
                    // runloop tick swallows the second one.
                    DispatchQueue.main.async {
                        addDraft = ServerDraft(
                            existingNames: existingNames(excludingId: ""),
                            payload: payload
                        )
                    }
                },
                onCancel: { scannerPresented = false }
            )
        }
        .alert(
            "删除服务器",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { server in
            Button("删除", role: .destructive) {
                delete(server: server)
                pendingDelete = nil
            }
            Button("取消", role: .cancel) {
                pendingDelete = nil
            }
        } message: { server in
            if servers.configs.count == 1 {
                Text("「\(server.displayLabel)」是最后一台服务器。删除后将返回首次设置流程。")
            } else if server.id == servers.activeConfigId {
                Text("「\(server.displayLabel)」是当前活动服务器。删除后将自动切换到列表中剩余的服务器。")
            } else {
                Text("将删除「\(server.displayLabel)」。此操作无法撤销。")
            }
        }
    }

    private func existingNames(excludingId: String) -> Set<String> {
        Set(servers.configs.lazy.filter { $0.id != excludingId }.compactMap(\.name))
    }

    private func delete(server: ServerConfig) {
        let wasActive = (server.id == servers.activeConfigId)
        servers.configs.removeAll { $0.id == server.id }
        if wasActive {
            // §5.2 — activeConfig already falls back to configs[0], but
            // pin the id so the persisted state is in sync with what the
            // UI shows.
            servers.activeConfigId = servers.configs.first?.id
        }
        // Drop any Sharing-Suggestions tiles the system is showing for
        // this server. Without this, iOS would keep suggesting a dead
        // destination on the share sheet until the suggestion ages out.
        ShareIntentDonation.deleteAllDonations(forServerId: server.id)
    }

    private func commit(draft: ServerDraft) {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = ServerConfig(
            id: UUID().uuidString.lowercased(),
            name: trimmedName.isEmpty ? nil : trimmedName,
            url: draft.url.trimmingCharacters(in: .whitespacesAndNewlines),
            username: draft.username,
            password: draft.password,
            autoSwitchWifiNames: draft.ssids
        )
        servers.configs.append(server)
        // First server in: make it active so the rest of the app has a
        // valid `activeConfig` immediately.
        if servers.activeConfigId == nil || servers.configs.count == 1 {
            servers.activeConfigId = server.id
        }
    }
}

private struct ServerRow: View {
    let server: ServerConfig
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: isActive ? "checkmark" : "server.rack")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isActive ? Color.green : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayLabel)
                    .font(.callout.weight(.semibold))
                Text(server.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !server.autoSwitchWifiNames.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "wifi")
                            .font(.caption2)
                        Text(server.autoSwitchWifiNames.joined(separator: ", "))
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Server edit (existing server)

private struct ServerEditView: View {
    @Binding var server: ServerConfig
    @Binding var trustInsecureCert: Bool
    let ssidProvider: CurrentSSIDProvider
    let existingNames: Set<String>

    /// Local edit buffer for the name so we can normalize on commit
    /// (trim → empty becomes nil).
    @State private var nameDraft: String = ""
    @State private var newSSID: String = ""
    @State private var test: ConnectionTestState = .idle

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("便于辨识的名称", text: $nameDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        nameDraft = ServerNameGenerator.generate(avoiding: existingNames)
                    } label: {
                        Image(systemName: "shuffle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("换一个名称")
                }
            } header: {
                Text("名称")
            } footer: {
                Text("将显示在剪贴板顶栏。留空会用服务器地址替代。")
            }

            Section {
                TextField("https://your-server.com:5033/", text: $server.url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle(isOn: $trustInsecureCert) {
                    Text("允许不安全证书")
                }
            } header: {
                Text("服务器地址")
            } footer: {
                Text("局域网或自签名证书时勾选。此设置全局生效。")
            }

            Section("凭据") {
                TextField("用户名", text: $server.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $server.password)
            }

            SSIDEditorSection(
                ssids: $server.autoSwitchWifiNames,
                newSSID: $newSSID,
                ssidProvider: ssidProvider
            )

            TestConnectionSection(
                test: $test,
                trustInsecureCert: trustInsecureCert,
                url: server.url,
                username: server.username,
                password: server.password
            )
        }
        .navigationTitle(server.displayLabel)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            nameDraft = server.name ?? ""
        }
        .onChange(of: nameDraft) { _, _ in
            // Commit on every keystroke — onDisappear is unreliable when
            // SwiftUI rebuilds the navigation stack mid-edit.
            let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            server.name = trimmed.isEmpty ? nil : trimmed
        }
    }
}

// MARK: - Add server sheet

/// Working state for "Add server". Identifiable so `.sheet(item:)` can
/// present it, with `id` regenerated whenever a fresh draft is created
/// (each presentation needs a new id or SwiftUI won't re-present).
private struct ServerDraft: Identifiable, Equatable {
    let id: UUID = .init()
    var name: String
    var url: String
    var username: String
    var password: String
    var ssids: [String]

    init(existingNames: Set<String>, payload: ServerQRPayload? = nil) {
        self.name = payload?.name
            ?? ServerNameGenerator.generate(avoiding: existingNames)
        self.url = payload?.url ?? ""
        self.username = payload?.username ?? ""
        self.password = payload?.password ?? ""
        self.ssids = []
    }
}

private struct AddServerSheet: View {
    /// Local working copy, seeded once from the presented draft. Kept as
    /// `@State` (not a Binding back to the parent's `addDraft`) so edits —
    /// including the keyboard's trailing commit on dismiss — stay inside
    /// the sheet and can't resurrect `addDraft` into a fresh blank form.
    @State private var draft: ServerDraft
    @Binding var trustInsecureCert: Bool
    let ssidProvider: CurrentSSIDProvider
    var onCancel: () -> Void
    var onSave: (ServerDraft) -> Void

    @State private var newSSID: String = ""
    @State private var test: ConnectionTestState = .idle
    @State private var scannerPresented: Bool = false

    init(
        draft: ServerDraft,
        trustInsecureCert: Binding<Bool>,
        ssidProvider: CurrentSSIDProvider,
        onCancel: @escaping () -> Void,
        onSave: @escaping (ServerDraft) -> Void
    ) {
        _draft = State(initialValue: draft)
        _trustInsecureCert = trustInsecureCert
        self.ssidProvider = ssidProvider
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var canSave: Bool {
        !draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.username.isEmpty
            && !draft.password.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        TextField("便于辨识的名称", text: $draft.name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            draft.name = ServerNameGenerator.generate(avoiding: [])
                        } label: {
                            Image(systemName: "shuffle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("换一个名称")
                    }
                } header: {
                    Text("名称")
                } footer: {
                    Text("将显示在剪贴板顶栏。留空会用服务器地址替代。")
                }

                Section {
                    TextField("https://your-server.com:5033/", text: $draft.url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle(isOn: $trustInsecureCert) {
                        Text("允许不安全证书")
                    }
                } header: {
                    Text("服务器地址")
                } footer: {
                    Text("局域网或自签名证书时勾选。此设置全局生效。")
                }

                Section("凭据") {
                    TextField("用户名", text: $draft.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $draft.password)
                }

                SSIDEditorSection(
                    ssids: $draft.ssids,
                    newSSID: $newSSID,
                    ssidProvider: ssidProvider
                )

                TestConnectionSection(
                    test: $test,
                    trustInsecureCert: trustInsecureCert,
                    url: draft.url,
                    username: draft.username,
                    password: draft.password
                )

                Section {
                    Button {
                        scannerPresented = true
                    } label: {
                        Label("从二维码填充", systemImage: "qrcode.viewfinder")
                    }
                }
            }
            .navigationTitle("添加服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { onSave(draft) }
                        .disabled(!canSave)
                }
            }
            .fullScreenCover(isPresented: $scannerPresented) {
                QRScannerView(
                    onScan: { payload in
                        // In-place merge: keep whatever the user has
                        // already typed unless a scanned field overwrites
                        // it. Username/password always overwrite because
                        // they're typically the reason to scan.
                        if let n = payload.name, draft.name.isEmpty { draft.name = n }
                        draft.url = payload.url
                        draft.username = payload.username
                        draft.password = payload.password
                        scannerPresented = false
                    },
                    onCancel: { scannerPresented = false }
                )
            }
        }
    }
}

// MARK: - Shared form components

/// Editable SSID list. Add via inline text field or one-tap from the
/// detected current network, remove via swipe / delete.
private struct SSIDEditorSection: View {
    @Binding var ssids: [String]
    @Binding var newSSID: String
    @Bindable var ssidProvider: CurrentSSIDProvider

    var body: some View {
        Section {
            currentNetworkRow

            ForEach(ssids, id: \.self) { ssid in
                Label(ssid, systemImage: "wifi")
            }
            .onDelete { indices in
                ssids.remove(atOffsets: indices)
            }
            HStack {
                Image(systemName: "wifi.circle")
                    .foregroundStyle(.secondary)
                TextField("手动添加 WiFi 名称", text: $newSSID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(addManualSSID)
                if !newSSID.isEmpty {
                    Button(action: addManualSSID) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("WiFi 切换提示")
        } footer: {
            Text("连接到这里的任一 SSID 时，会提示切换到该服务器。")
                .font(.caption)
        }
        .task {
            ssidProvider.refresh()
        }
    }

    /// Header row showing the system's currently-connected SSID, with a
    /// one-tap "添加" button. Renders different states for: undetermined
    /// auth (with a "授权" button), denied (link to Settings), and
    /// unavailable (simulator — silently hidden so manual entry still
    /// works without confusing affordances).
    @ViewBuilder
    private var currentNetworkRow: some View {
        switch ssidProvider.authState {
        case .unavailable:
            EmptyView()
        case .notDetermined:
            HStack(spacing: 10) {
                Image(systemName: "location.circle")
                    .foregroundStyle(.tint)
                Text("授权位置以读取当前 WiFi")
                    .font(.callout)
                Spacer()
                Button("授权") { ssidProvider.requestAuthorization() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .denied:
            HStack(spacing: 10) {
                Image(systemName: "location.slash")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("位置权限未授予")
                        .font(.callout)
                    Text("在系统设置中开启「位置」权限以读取当前 WiFi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开设置") { openSystemSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .authorized:
            HStack(spacing: 10) {
                Image(systemName: "wifi")
                    .foregroundStyle(.tint)
                if let ssid = ssidProvider.currentSSID {
                    Text(ssid)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    if ssids.contains(ssid) {
                        Label("已添加", systemImage: "checkmark.circle.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.green)
                    } else {
                        Button("添加") { ssids.append(ssid) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                } else {
                    Text("未连接 WiFi")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        ssidProvider.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func addManualSSID() {
        guard let normalized = ServerConfig.normalizeSSID(newSSID) else { return }
        if !ssids.contains(normalized) {
            ssids.append(normalized)
        }
        newSSID = ""
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }
}

private enum ConnectionTestState: Equatable {
    case idle
    case connecting
    case success
    case authFailed
    case unreachable
    case missingFields

    init(_ result: ConnectionTester.Result) {
        switch result {
        case .success:        self = .success
        case .authFailed:     self = .authFailed
        case .unreachable:    self = .unreachable
        case .missingFields:  self = .missingFields
        }
    }
}

private struct TestConnectionSection: View {
    @Binding var test: ConnectionTestState
    let trustInsecureCert: Bool
    let url: String
    let username: String
    let password: String

    var body: some View {
        Section {
            statusRow

            Button {
                Task { await runTest() }
            } label: {
                HStack {
                    if test == .connecting {
                        ProgressView().controlSize(.small)
                        Text("正在连接…")
                    } else {
                        Image(systemName: "bolt.horizontal.circle")
                        Text("测试连接")
                    }
                    Spacer()
                }
            }
            .disabled(test == .connecting)
        } header: {
            Text("连接")
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch test {
        case .idle, .connecting:
            EmptyView()
        case .success:
            Label {
                Text("已连接 — 服务器可达")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .authFailed:
            Label {
                Text("认证失败 — 检查用户名和密码")
            } icon: {
                Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                    .foregroundStyle(.red)
            }
        case .unreachable:
            Label {
                Text("无法连接 — 检查 URL 和网络")
            } icon: {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
        case .missingFields:
            Label {
                Text("请填写 URL、用户名和密码")
            } icon: {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runTest() async {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty || username.isEmpty || password.isEmpty {
            test = .missingFields
            return
        }
        test = .connecting
        let result = await ConnectionTester.test(
            url: url,
            username: username,
            password: password,
            trustInsecureCert: trustInsecureCert
        )
        test = ConnectionTestState(result)
    }
}

// MARK: - Misc settings destinations

private struct LogsPlaceholderView: View {
    var body: some View {
        List {
            ForEach(0..<8) { i in
                HStack {
                    Text("INFO")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(.green)
                        .frame(width: 44, alignment: .leading)
                    Text("Pulled clipboard from server (\(i * 7 + 12) min ago)")
                        .font(.caption.monospaced())
                        .lineLimit(2)
                }
            }
        }
        .navigationTitle("日志")
    }
}

// MARK: - Storage (PayloadCache)

/// Settings section for the on-device payload cache: prefetch toggle,
/// cellular gate, disk cap, and "current size + 清除" row.
///
/// Cache size is read async via `PayloadCache.totalSize()`. We populate
/// once on appear and re-read after a purge — settings pages don't need
/// live updates, so no polling.
private struct StorageSettingsSection: View {
    @Binding var appSettings: AppSettings

    /// Discrete cap presets matching the Picker options. Stored in bytes
    /// so the source of truth for the cap value is the same encoding the
    /// rest of the codebase uses.
    private static let capOptionsBytes: [Int] = [
        50 * 1024 * 1024,
        200 * 1024 * 1024,
        500 * 1024 * 1024,
        1000 * 1024 * 1024,
    ]

    @State private var sizeBytes: Int? = nil
    @State private var showingPurgeConfirm = false
    @State private var purging = false

    var body: some View {
        Section {
            Toggle(isOn: $appSettings.prefetchAttachments) {
                Label("预下载附件", systemImage: "icloud.and.arrow.down")
            }
            if appSettings.prefetchAttachments {
                Toggle(isOn: $appSettings.prefetchOnCellular) {
                    Label("蜂窝下也预下载", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            Picker(selection: $appSettings.payloadCacheMaxBytes) {
                ForEach(Self.capOptionsBytes, id: \.self) { bytes in
                    Text(Self.formatCap(bytes)).tag(bytes)
                }
            } label: {
                Label("缓存上限", systemImage: "externaldrive")
            }
            HStack {
                Label("缓存占用", systemImage: "internaldrive")
                Spacer()
                Text(sizeLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    showingPurgeConfirm = true
                } label: {
                    Text("清除")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(purging || (sizeBytes ?? 0) == 0)
            }
        } header: {
            Text("存储")
        } footer: {
            Text("开启预下载后，新内容会在后台静默缓存，点击预览无需等待。")
                .font(.caption)
        }
        .task(id: refreshTrigger) {
            await refreshSize()
        }
        .onChange(of: appSettings.payloadCacheMaxBytes) { _, newValue in
            Task {
                await PayloadCache.shared.setMaxBytes(newValue)
                await refreshSize()
            }
        }
        .alert("确认清除缓存?", isPresented: $showingPurgeConfirm) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                purgeNow()
            }
        } message: {
            Text("已下载的图片和长文本将被删除。下次查看时会重新下载。")
        }
    }

    /// Bumped after purge to re-fire `.task(id:)` and refresh the size.
    @State private var refreshTrigger = 0

    private var sizeLabel: String {
        if purging { return String(localized: "清除中…") }
        guard let sizeBytes else { return "—" }
        return Self.formatSize(sizeBytes)
    }

    private func refreshSize() async {
        let bytes = await PayloadCache.shared.totalSize()
        sizeBytes = bytes
    }

    private func purgeNow() {
        Task {
            purging = true
            await PayloadCache.shared.purgeAll()
            purging = false
            refreshTrigger &+= 1
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static func formatSize(_ bytes: Int) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }

    private static func formatCap(_ bytes: Int) -> String {
        // Discrete presets are exact MiB multiples, so render them as
        // round integers rather than letting ByteCountFormatter pick
        // "47.7 MB"-style decimals.
        let mib = bytes / (1024 * 1024)
        return "\(mib) MB"
    }
}

private struct AboutView: View {
    @Binding var appSettings: AppSettings
    var body: some View {
        List {
            Section {
                LabeledContent("版本", value: "UniClipboard 1.0 (1)")
                LabeledContent("协议", value: "兼容 SyncClipboard v1")
            }
            Section {
                Link(destination: URL(string: "https://github.com/UniClipboard/UniClipboard")!) {
                    Label("项目主页", systemImage: "globe")
                }
            } footer: {
                Text("查看服务器部署指南、桌面端下载与使用文档。")
            }
            if let v = appSettings.ignoredVersion {
                Section("忽略的版本") {
                    HStack {
                        Text(v)
                        Spacer()
                        Button("清除") { appSettings.ignoredVersion = nil }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
        .navigationTitle("关于")
    }
}

#Preview {
    @Previewable @State var path: [SettingsRoute] = []
    return NavigationStack(path: $path) {
        SettingsView(vm: .preview(), path: $path)
    }
}
