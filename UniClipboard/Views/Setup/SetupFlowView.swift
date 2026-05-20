import SwiftUI

/// First-run setup. Drives the user from "no server configured" to a saved
/// active ServerConfig in three steps: Welcome → ServerForm → AutoSwitch.
/// All network calls are mocked here so the visuals can be evaluated.
///
/// Env-driven shortcuts (debug / screenshots only):
/// - `UC_SETUP_STEP=form`        → start on ServerForm
/// - `UC_SETUP_STEP=autoswitch`  → start on AutoSwitch (assumes prefilled draft)
/// - `UC_PREFILL=1`              → prefill the form with reasonable defaults
/// - `UC_PREFILL_TEST=success|authFailed|unreachable|missingFields`
///                                → seed the test-connection result
struct SetupFlowView: View {
    @Bindable var vm: AppViewModel
    var onComplete: () -> Void

    @State private var path: [Step] = Step.initialPath()

    /// Alias for the server being configured. Hoisted up here (rather than
    /// inside `ServerFormStepView`) so popping back to the form preserves
    /// what the user typed — destinations get torn down on pop.
    @State private var draftName: String = ""

    private var existingNames: Set<String> {
        Set(vm.servers.configs.compactMap(\.name))
    }

    enum Step: Hashable {
        case form
        /// Form with the three credential fields pre-filled from a
        /// `uniclipboard://connect?…` URI. The shape is the same as
        /// `.form`; carrying the values through the path makes the step
        /// poppable + restorable (NavigationStack tears down destinations
        /// on pop, so `@State` defaults inside `ServerFormStepView` wouldn't
        /// survive a back-and-forth).
        case formPrefilled(url: String, username: String, password: String)
        case autoSwitch(name: String, url: String, username: String, password: String)

        static func initialPath() -> [Step] {
            switch ProcessInfo.processInfo.environment["UC_SETUP_STEP"] {
            case "form":
                return [.form]
            case "autoswitch":
                return [
                    .form,
                    .autoSwitch(
                        name: SetupPrefill.name,
                        url: SetupPrefill.url,
                        username: SetupPrefill.username,
                        password: SetupPrefill.password
                    ),
                ]
            default:
                return []
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            WelcomeStepView(onScanned: handleScanned(_:))
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .form:
                        ServerFormStepView(
                            name: $draftName,
                            existingNames: existingNames
                        )
                    case .formPrefilled(let url, let username, let password):
                        ServerFormStepView(
                            name: $draftName,
                            existingNames: existingNames,
                            initialURL: url,
                            initialUsername: username,
                            initialPassword: password
                        )
                    case .autoSwitch(let name, let url, let username, let password):
                        AutoSwitchStepView(
                            name: name,
                            url: url,
                            username: username,
                            password: password,
                            servers: $vm.servers,
                            ssidProvider: vm.ssidProvider,
                            onComplete: onComplete
                        )
                    }
                }
        }
        .task(id: vm.pendingImport) {
            // QR landed via `.onOpenURL` (system Camera) while still in
            // setup. Replace the nav path with the prefilled form — the
            // user came from outside the app and shouldn't have to retrace
            // Welcome → Form by hand. Seed `draftName` from the optional
            // label so the alias field isn't empty after navigation.
            guard let p = vm.consumePendingImport() else { return }
            draftName = p.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            path = [.formPrefilled(url: p.url, username: p.user, password: p.pwd)]
        }
    }

    /// Shared landing point for both the Welcome in-app QR scanner and the
    /// external `.onOpenURL` route — push the prefilled form, seed the
    /// alias from the optional label. `ServerQRPayload` is the common
    /// shape (ConnectURI's label is mapped to `name` upstream).
    private func handleScanned(_ payload: ServerQRPayload) {
        draftName = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        path = [.formPrefilled(url: payload.url, username: payload.username, password: payload.password)]
    }
}

// MARK: - Step 1 · Welcome

private struct WelcomeStepView: View {
    var onScanned: (ServerQRPayload) -> Void

    @Environment(\.openURL) private var openURL
    @State private var scannerPresented: Bool =
        ProcessInfo.processInfo.environment["UC_OPEN_SETUP_QR"] == "1"

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.10), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 168, height: 168)
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 72, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                .padding(.bottom, 36)

                VStack(spacing: 14) {
                    Text("和其他设备共享剪贴板")
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("扫描桌面端的配对二维码,几秒钟完成连接")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        scannerPresented = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "qrcode.viewfinder")
                            Text("扫描二维码添加")
                                .font(.body.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        // AccentColor is near-black in light mode but
                        // ivory in dark mode, so the default white
                        // borderedProminent label gives no contrast on
                        // dark. systemBackground flips with appearance
                        // and lands on the correct contrasting tone.
                        .foregroundStyle(Color(.systemBackground))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    NavigationLink(value: SetupFlowView.Step.form) {
                        Text("手动输入服务器信息")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        if let url = URL(string: "https://github.com/UniClipboard/UniClipboard") {
                            openURL(url)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle")
                            Text("我还没有服务器")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $scannerPresented) {
            QRScannerView(
                onScan: { payload in
                    scannerPresented = false
                    // Defer path replacement by one runloop tick so the
                    // fullScreenCover finishes dismissing — stacking the
                    // NavigationStack mutation on the same tick swallows
                    // the transition and leaves the cover half-dismissed.
                    DispatchQueue.main.async {
                        onScanned(payload)
                    }
                },
                onCancel: { scannerPresented = false }
            )
        }
    }
}

// MARK: - Step 2 · ServerForm

private struct ServerFormStepView: View {
    @Binding var name: String
    let existingNames: Set<String>

    @State private var url: String
    @State private var username: String
    @State private var password: String
    @State private var trustInsecure: Bool = false
    @State private var test: TestState

    /// - Parameters:
    ///   - initialURL/Username/Password: when non-nil, seed the form with
    ///     these values and skip the `UC_PREFILL` env defaults. Used by
    ///     `Step.formPrefilled` so a connect-URI scan from outside the app
    ///     lands the user on a ready-to-test form. Initial test state is
    ///     forced to `.idle` so the user explicitly presses "测试连接" — we
    ///     don't want a stale `.success` ribbon implying the QR credentials
    ///     were already verified.
    init(
        name: Binding<String>,
        existingNames: Set<String>,
        initialURL: String? = nil,
        initialUsername: String? = nil,
        initialPassword: String? = nil
    ) {
        _name = name
        self.existingNames = existingNames
        _url = State(initialValue: initialURL ?? SetupPrefill.url)
        _username = State(initialValue: initialUsername ?? SetupPrefill.username)
        _password = State(initialValue: initialPassword ?? SetupPrefill.password)
        let prefilled = (initialURL != nil) || (initialUsername != nil) || (initialPassword != nil)
        _test = State(initialValue: prefilled ? .idle : SetupPrefill.initialTestState)
    }

    enum TestState: Equatable {
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

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("便于辨识的名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        name = ServerNameGenerator.generate(avoiding: existingNames)
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
                TextField("https://your-server.com:5033/", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle(isOn: $trustInsecure) {
                    Text("允许不安全证书")
                }
            } header: {
                Text("服务器地址")
            } footer: {
                Text("局域网或自签名证书时勾选")
            }

            Section("凭据") {
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
            }

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

                if test == .success {
                    NavigationLink(
                        value: SetupFlowView.Step.autoSwitch(
                            name: name, url: url, username: username, password: password
                        )
                    ) {
                        HStack {
                            Text("继续")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.tint)
                            Spacer()
                        }
                    }
                }
            } header: {
                Text("连接")
            }
        }
        .navigationTitle("服务器配置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // First visit: seed with a fresh alias. If the user clears it
            // intentionally we don't refill — `.isEmpty` will be saved as
            // `nil` and `displayLabel` falls back to URL per §5.1.
            if name.isEmpty {
                name = ServerNameGenerator.generate(avoiding: existingNames)
            }
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
        // Short-circuit missingFields before showing the spinner so the
        // status label snaps to the hint without a brief "正在连接…" flash.
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
            trustInsecureCert: trustInsecure
        )
        test = TestState(result)
    }
}

// MARK: - Step 3 · AutoSwitch

private struct AutoSwitchStepView: View {
    let name: String
    let url: String
    let username: String
    let password: String
    @Binding var servers: ServerConfigList
    @Bindable var ssidProvider: CurrentSSIDProvider
    var onComplete: () -> Void

    @State private var ssids: [String] = []

    var body: some View {
        Form {
            Section {
                Text("在指定 WiFi 下自动启用此服务器（可选）。\n稍后也可以在「设置 → 服务器列表」修改。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }

            Section("当前网络") {
                currentNetworkRow
            }

            Section("已添加的 WiFi") {
                if ssids.isEmpty {
                    Text("无").foregroundStyle(.secondary)
                } else {
                    ForEach(ssids, id: \.self) { ssid in
                        Label(ssid, systemImage: "wifi")
                    }
                    .onDelete { indices in
                        ssids.remove(atOffsets: indices)
                    }
                }
            }

            Section {
                Button {
                    save()
                } label: {
                    Text("完成")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(Color(.systemBackground))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    save()
                } label: {
                    Text("稍后设置")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("自动切换 WiFi")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            ssidProvider.refresh()
        }
    }

    @ViewBuilder
    private var currentNetworkRow: some View {
        switch ssidProvider.authState {
        case .unavailable:
            HStack {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
                Text("当前设备无法读取 WiFi 名称")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .notDetermined:
            HStack {
                Image(systemName: "location.circle")
                    .foregroundStyle(.tint)
                Text("授权位置以读取当前 WiFi")
                Spacer()
                Button("授权") { ssidProvider.requestAuthorization() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        case .denied:
            HStack {
                Image(systemName: "location.slash")
                    .foregroundStyle(.orange)
                Text("位置权限未授予")
                    .font(.callout)
                Spacer()
                Button("打开设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .authorized:
            HStack {
                Image(systemName: "wifi")
                    .foregroundStyle(.tint)
                if let ssid = ssidProvider.currentSSID {
                    Text(ssid)
                    Spacer()
                    if ssids.contains(ssid) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("添加") { ssids.append(ssid) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                } else {
                    Text("未连接 WiFi")
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

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = ServerConfig(
            id: UUID().uuidString.lowercased(),
            name: trimmedName.isEmpty ? nil : trimmedName,
            url: url,
            username: username,
            password: password,
            autoSwitchWifiNames: ssids
        )
        servers.configs.append(server)
        servers.activeConfigId = server.id
        onComplete()
    }
}

// MARK: - Prefill (env-driven for screenshots / quick demo)

private enum SetupPrefill {
    static var name:     String { value("UC_PREFILL_NAME",     fallback: "happy-otter") }
    static var url:      String { value("UC_PREFILL_URL",      fallback: "https://clip.home.lan:5033/") }
    static var username: String { value("UC_PREFILL_USERNAME", fallback: "alice") }
    static var password: String { value("UC_PREFILL_PASSWORD", fallback: "p4ssw0rd!") }

    static var initialTestState: ServerFormStepView.TestState {
        switch ProcessInfo.processInfo.environment["UC_PREFILL_TEST"] {
        case "success":       return .success
        case "authFailed":    return .authFailed
        case "unreachable":   return .unreachable
        case "missingFields": return .missingFields
        default:              return .idle
        }
    }

    private static func value(_ key: String, fallback: String) -> String {
        let env = ProcessInfo.processInfo.environment
        guard env["UC_PREFILL"] == "1" else { return "" }
        return env[key] ?? fallback
    }
}

#Preview("Welcome") {
    SetupFlowView(vm: .preview(servers: ServerConfigList())) {}
}
