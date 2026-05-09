import SwiftUI

struct HistoryView: View {
    var items: [ClipboardHistoryItem] = Mock.history

    var body: some View {
        List {
            Section {
                ForEach(items) { item in
                    HistoryRow(item: item)
                }
            } header: {
                Text("最近 \(items.count) 条")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } footer: {
                Text("仅本机缓存。服务器只保留最新一份。")
                    .font(.caption)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("历史")
        .navigationBarTitleDisplayMode(.large)
    }
}

private struct HistoryRow: View {
    let item: ClipboardHistoryItem

    var body: some View {
        HStack(spacing: 12) {
            ClipboardKindBadge(kind: item.entry.type, size: .medium, showsLabel: false)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.entry.text)
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Image(systemName: item.direction == .pulled ? "arrow.down.circle" : "arrow.up.circle")
                        .font(.caption)
                        .foregroundStyle(item.direction == .pulled ? Color.blue : Color.indigo)
                    Text(item.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let size = item.entry.size {
                        Text("·").foregroundStyle(.tertiary)
                        Text(formatSize(size, kind: item.entry.type))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                // re-apply this entry to local clipboard
            } label: {
                Label("应用", systemImage: "arrow.down.to.line")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                // remove from local cache
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

private func formatSize(_ size: Int, kind: Clipboard.Kind) -> String {
    switch kind {
    case .text:
        return String(localized: "\(size) 字")
    case .image, .file, .group:
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(size))
    }
}

#Preview {
    NavigationStack {
        HistoryView()
    }
    .tint(.indigo)
}
