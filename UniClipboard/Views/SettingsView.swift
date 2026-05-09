import SwiftUI

struct SettingsView: View {
    @Binding var servers: ServerConfigList
    @Binding var appSettings: AppSettings

    var body: some View {
        List {
            Section("同步") {
                NavigationLink {
                    ServersListView(servers: $servers)
                } label: {
                    HStack {
                        Label("服务器列表", systemImage: "server.rack")
                        Spacer()
                        Text("\(servers.configs.count) 个")
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: $appSettings.trustInsecureCert) {
                    Label("允许不安全证书", systemImage: "lock.open")
                }
            }

            Section("行为") {
                Toggle(isOn: $appSettings.autoCheckUpdate) {
                    Label("启动时检查更新", systemImage: "arrow.triangle.2.circlepath")
                }
                NavigationLink {
                    Form {
                        TextField("下载子目录", text: $appSettings.downloadRelativePath)
                            .textInputAutocapitalization(.never)
                    }
                    .navigationTitle("下载路径")
                } label: {
                    HStack {
                        Label("下载路径", systemImage: "folder")
                        Spacer()
                        Text(appSettings.downloadRelativePath.isEmpty ? "默认" : appSettings.downloadRelativePath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Section("诊断") {
                NavigationLink {
                    LogsPlaceholderView()
                } label: {
                    Label("日志", systemImage: "doc.text.magnifyingglass")
                }
                NavigationLink {
                    AboutView(appSettings: $appSettings)
                } label: {
                    Label("关于", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("设置")
    }
}

// MARK: - Servers list

private struct ServersListView: View {
    @Binding var servers: ServerConfigList

    var body: some View {
        List {
            Section {
                ForEach(servers.configs) { server in
                    NavigationLink {
                        ServerEditPlaceholderView(server: server)
                    } label: {
                        ServerRow(
                            server: server,
                            isActive: server.id == servers.activeConfigId
                        )
                    }
                    .swipeActions {
                        if server.id != servers.activeConfigId {
                            Button {
                                servers.activeConfigId = server.id
                            } label: {
                                Label("设为活动", systemImage: "checkmark.circle")
                            }
                            .tint(.green)
                        }
                    }
                }
            } footer: {
                Text("自动切换：连接到匹配 SSID 时自动切换到该服务器。")
                    .font(.caption)
            }

            Section {
                Button {
                    // add new server flow
                } label: {
                    Label("添加服务器", systemImage: "plus.circle.fill")
                }
                Button {
                    // import flow
                } label: {
                    Label("从文件导入", systemImage: "square.and.arrow.down")
                }
            }
        }
        .navigationTitle("服务器列表")
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

// MARK: - Placeholders

private struct ServerEditPlaceholderView: View {
    let server: ServerConfig
    var body: some View {
        Form {
            Section("基本") {
                LabeledContent("名称") {
                    if let name = server.name {
                        Text(name)
                    } else {
                        Text("（未命名）")
                    }
                }
                LabeledContent("URL", value: server.url)
                LabeledContent("用户名", value: server.username)
                LabeledContent("密码", value: String(repeating: "•", count: server.password.count))
            }
            Section("自动切换") {
                if server.autoSwitchWifiNames.isEmpty {
                    Text("无").foregroundStyle(.secondary)
                } else {
                    ForEach(server.autoSwitchWifiNames, id: \.self) { ssid in
                        Label(ssid, systemImage: "wifi")
                    }
                }
            }
            Section {
                Button("测试连接") {}
            }
        }
        .navigationTitle(server.displayLabel)
    }
}

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

private struct AboutView: View {
    @Binding var appSettings: AppSettings
    var body: some View {
        List {
            Section {
                LabeledContent("版本", value: "UniClipboard 1.0 (1)")
                LabeledContent("协议", value: "兼容 SyncClipboard v1")
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
    @Previewable @State var servers = Mock.servers
    @Previewable @State var settings = AppSettings(
        manualUploadDialogShown: true,
        downloadRelativePath: "SyncClipboard/Inbox",
        ignoredVersion: "0.3.2"
    )
    NavigationStack {
        SettingsView(servers: $servers, appSettings: $settings)
    }
    .tint(.indigo)
}
