import SwiftUI

/// Home tab — the focal point. Two cards (Server vs Device) and a bottom
/// floating accessory for the primary push action.
struct HomeView: View {
    @Bindable var vm: AppViewModel
    var serverLatest: Clipboard?
    var serverLastSyncedAt: Date?
    var deviceClipboard: Clipboard?

    @State private var lastPushedAt: Date?

    private var inSync: Bool {
        guard let s = serverLatest, let d = deviceClipboard else { return false }
        return Clipboard.hashMatches(expected: s.hash, actual: d.hash ?? "")
            && s.hash != nil && d.hash != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ServerSnapshotCard(
                    entry: serverLatest,
                    lastSyncedAt: serverLastSyncedAt
                )

                connector

                DeviceClipboardCard(
                    entry: deviceClipboard,
                    inSyncWithServer: inSync,
                    lastPushedAt: lastPushedAt
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 110) // leave room for the floating bar
        }
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("剪贴板")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ServerChip(
                    activeServer: vm.servers.activeConfig,
                    allServers: vm.servers.configs,
                    onSelect: { id in vm.servers.activeConfigId = id }
                )
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    // pull-to-refresh placeholder
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            PushAccessoryBar(
                activeServer: vm.servers.activeConfig,
                allServers: vm.servers.configs,
                canPush: !inSync && deviceClipboard != nil,
                onPush: { lastPushedAt = .now },
                onSelectServer: { id in vm.servers.activeConfigId = id }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    private var connector: some View {
        HStack(spacing: 8) {
            Image(systemName: inSync ? "checkmark.circle.fill" : "arrow.up.arrow.down.circle")
                .foregroundStyle(inSync ? .green : .secondary)
            Text(inSync ? "本机与服务器一致" : "本机与服务器不一致 · 可推送")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Server's-latest card

private struct ServerSnapshotCard: View {
    let entry: Clipboard?
    let lastSyncedAt: Date?

    var body: some View {
        GlassCard {
            if let entry {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        ClipboardKindBadge(kind: entry.type, size: .medium)
                        Spacer()
                        Text("服务器")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(.tertiary.opacity(0.4), in: Capsule())
                    }

                    previewBlock(entry: entry)

                    metadataRow(entry: entry)

                    Divider().opacity(0.4)

                    HStack(spacing: 10) {
                        Button {
                            // apply to local pasteboard
                        } label: {
                            Label("应用到本机", systemImage: "arrow.down.to.line")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        if entry.hasData {
                            Button {
                                // save attachment
                            } label: {
                                Label("保存", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                }
            } else {
                emptyState
            }
        }
    }

    @ViewBuilder
    private func previewBlock(entry: Clipboard) -> some View {
        switch entry.type {
        case .text:
            Text(entry.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        case .image, .file, .group:
            HStack(spacing: 14) {
                ClipboardKindBadge(kind: entry.type, size: .large, showsLabel: false)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if let dataName = entry.dataName, dataName != entry.text {
                        Text(dataName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(14)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func metadataRow(entry: Clipboard) -> some View {
        HStack(spacing: 12) {
            if let size = entry.size {
                Label(formatSize(size, kind: entry.type), systemImage: "ruler")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let lastSyncedAt {
                Label(lastSyncedAt.relativeShort, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let hash = entry.hash {
                Text(hash.shortHash)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "icloud.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("服务器还没有发布过剪贴板")
                .font(.subheadline.weight(.semibold))
            Text("从下方推送你的第一份内容")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Device-current card

private struct DeviceClipboardCard: View {
    let entry: Clipboard?
    let inSyncWithServer: Bool
    let lastPushedAt: Date?

    var body: some View {
        GlassCard {
            if let entry {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        ClipboardKindBadge(kind: entry.type, size: .medium)
                        Spacer()
                        Text(inSyncWithServer ? "已同步" : "本机")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(inSyncWithServer ? .green : .indigo)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                (inSyncWithServer ? Color.green : Color.indigo).opacity(0.12),
                                in: Capsule()
                            )
                    }

                    Text(entry.text)
                        .font(.callout)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))

                    HStack(spacing: 10) {
                        if let size = entry.size {
                            Label("\(size) 字符", systemImage: "character")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let lastPushedAt {
                            Label("上次推送 \(lastPushedAt.relativeShort)", systemImage: "arrow.up.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            } else {
                Text("无法读取本机剪贴板")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        }
    }
}

// MARK: - Top toolbar server chip

private struct ServerChip: View {
    let activeServer: ServerConfig?
    let allServers: [ServerConfig]
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(allServers) { server in
                Button {
                    onSelect(server.id)
                } label: {
                    if server.id == activeServer?.id {
                        Label(server.displayLabel, systemImage: "checkmark")
                    } else {
                        Text(server.displayLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                Text(activeServer?.displayLabel ?? "未配置")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(.thinMaterial, in: Capsule())
        }
    }
}

// MARK: - Glass card container

private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
    }
}

// MARK: - Helpers

private extension Date {
    var relativeShort: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: .now)
    }
}

private extension String {
    var shortHash: String {
        guard count >= 12 else { return self }
        return String(prefix(6)) + "…" + String(suffix(4))
    }
}

private func formatSize(_ size: Int, kind: Clipboard.Kind) -> String {
    switch kind {
    case .text:
        return String(localized: "\(size) 字")
    case .image, .file, .group:
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

// MARK: - Preview

#Preview("Home — 不一致") {
    NavigationStack {
        HomeView(
            vm: .preview(),
            serverLatest: Mock.serverLatest,
            serverLastSyncedAt: Mock.serverLastSyncedAt,
            deviceClipboard: Mock.deviceClipboard
        )
    }
    .tint(.indigo)
}

#Preview("Home — 已同步") {
    NavigationStack {
        HomeView(
            vm: .preview(),
            serverLatest: Mock.serverLatest,
            serverLastSyncedAt: Mock.serverLastSyncedAt,
            deviceClipboard: Mock.serverLatest
        )
    }
    .tint(.indigo)
}

#Preview("Home — 服务器空") {
    NavigationStack {
        HomeView(
            vm: .preview(),
            serverLatest: nil,
            serverLastSyncedAt: nil,
            deviceClipboard: Mock.deviceClipboard
        )
    }
    .tint(.indigo)
}
