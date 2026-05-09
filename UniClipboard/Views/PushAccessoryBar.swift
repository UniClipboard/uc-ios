import SwiftUI

/// The floating "推送 + active server" capsule that hovers above the TabBar
/// on Home. Liquid-glass styling via `.ultraThinMaterial` + thin stroke.
struct PushAccessoryBar: View {
    var activeServer: ServerConfig?
    var allServers: [ServerConfig]
    var canPush: Bool
    var onPush: () -> Void
    var onSelectServer: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            pushButton
            Divider()
                .frame(height: 28)
                .opacity(0.3)
            serverMenu
        }
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }

    private var pushButton: some View {
        Button(action: onPush) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text("推送当前剪贴板")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canPush || activeServer == nil)
        .opacity(canPush && activeServer != nil ? 1 : 0.45)
    }

    private var serverMenu: some View {
        Menu {
            ForEach(allServers) { server in
                Button {
                    onSelectServer(server.id)
                } label: {
                    if server.id == activeServer?.id {
                        Label(server.displayLabel, systemImage: "checkmark")
                    } else {
                        Text(server.displayLabel)
                    }
                }
            }
            Divider()
            Button {
                // hook up later
            } label: {
                Label("管理服务器", systemImage: "server.rack")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(activeServer == nil ? Color.gray : Color.green)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle()
                            .stroke(.white.opacity(0.6), lineWidth: 0.5)
                    )
                Text(activeServer?.displayLabel ?? "未配置")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: 160)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
    }
}

#Preview("Floating Bar") {
    ZStack {
        LinearGradient(
            colors: [.cyan.opacity(0.3), .purple.opacity(0.3)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        VStack {
            Spacer()
            PushAccessoryBar(
                activeServer: Mock.servers.activeConfig,
                allServers: Mock.servers.configs,
                canPush: true,
                onPush: {},
                onSelectServer: { _ in }
            )
            .padding(.horizontal, 16)
        }
    }
    .tint(.indigo)
}
