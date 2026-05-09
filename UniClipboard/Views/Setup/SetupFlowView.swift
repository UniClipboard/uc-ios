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

    enum Step: Hashable {
        case form
        case autoSwitch(url: String, username: String, password: String)

        static func initialPath() -> [Step] {
            switch ProcessInfo.processInfo.environment["UC_SETUP_STEP"] {
            case "form":
                return [.form]
            case "autoswitch":
                return [
                    .form,
                    .autoSwitch(
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
            WelcomeStepView()
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .form:
                        ServerFormStepView()
                    case .autoSwitch(let url, let username, let password):
                        AutoSwitchStepView(
                            url: url,
                            username: username,
                            password: password,
                            servers: $vm.servers,
                            onComplete: onComplete
                        )
                    }
                }
        }
    }
}

// MARK: - Step 1 · Welcome

private struct WelcomeStepView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo.opacity(0.18), .purple.opacity(0.08), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(.indigo.gradient.opacity(0.18))
                        .frame(width: 168, height: 168)
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 72, weight: .semibold))
                        .foregroundStyle(.indigo.gradient)
                }
                .padding(.bottom, 36)

                VStack(spacing: 14) {
                    Text("和其他设备共享剪贴板")
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("通过 UniClipboard 服务器同步")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)

                Spacer()

                VStack(spacing: 12) {
                    NavigationLink(value: SetupFlowView.Step.form) {
                        Text("开始配置")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        // open docs in real flow
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "questionmark.circle")
                            Text("我还没有服务器")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .navigationBarHidden(true)
    }
}

// MARK: - Step 2 · ServerForm

private struct ServerFormStepView: View {
    @State private var url: String = SetupPrefill.url
    @State private var username: String = SetupPrefill.username
    @State private var password: String = SetupPrefill.password
    @State private var trustInsecure: Bool = false
    @State private var test: TestState = SetupPrefill.initialTestState

    enum TestState: Equatable {
        case idle
        case connecting
        case success
        case authFailed
        case unreachable
        case missingFields
    }

    var body: some View {
        Form {
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
                            url: url, username: username, password: password
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
        test = .connecting
        try? await Task.sleep(for: .milliseconds(1100))
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty || username.isEmpty || password.isEmpty {
            test = .missingFields
            return
        }
        if !trimmedURL.contains("://") || trimmedURL.contains("unreachable") {
            test = .unreachable
            return
        }
        if username.lowercased() == "wrong" || password.lowercased() == "wrong" {
            test = .authFailed
            return
        }
        test = .success
    }
}

// MARK: - Step 3 · AutoSwitch

private struct AutoSwitchStepView: View {
    let url: String
    let username: String
    let password: String
    @Binding var servers: ServerConfigList
    var onComplete: () -> Void

    @State private var ssids: [String] = []

    private let mockCurrentSSID = "Home-5G"

    var body: some View {
        Form {
            Section {
                Text("在指定 WiFi 下自动启用此服务器（可选）。\n稍后也可以在「设置 → 服务器列表」修改。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }

            Section("当前网络") {
                HStack {
                    Image(systemName: "wifi")
                        .foregroundStyle(.tint)
                    Text(mockCurrentSSID)
                    Spacer()
                    if ssids.contains(mockCurrentSSID) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("添加") { ssids.append(mockCurrentSSID) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
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
    }

    private func save() {
        let server = ServerConfig(
            id: UUID().uuidString.lowercased(),
            name: nil,
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
