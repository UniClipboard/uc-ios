import Foundation

/// Uploads a single `ShareItem` to the active SyncClipboard server.
/// Lives in the Share Extension target — owns the §3.5 file-first PUT
/// sequence (file bytes first, metadata second) so the main app's sync
/// engine, when it next ticks, sees a fully-consistent server state.
///
/// Writes `lastSyncedContentHash` to the App-Group `SettingsStore` after
/// a successful push. This is what keeps the main app's `SyncEngine` from
/// interpreting the just-pushed entry as "server has new content" and
/// echoing it back to the device pasteboard on next tick (which would
/// trigger iOS's "Allow Paste" prompt — see CLAUDE.md notes on engine
/// dedup against `lastSyncedContentHash`).
struct ShareUploader {
    let store: SettingsStore

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
    }

    func upload(_ item: ShareItem, to server: ServerConfig, trustInsecureCert: Bool) async throws {
        let client = try SyncClipboardClient(server: server, trustInsecureCert: trustInsecureCert)
        let (entry, payload) = build(from: item)

        if entry.hasData, let payload, let name = entry.dataName {
            try await client.putFile(name: name, body: payload)
            if let hash = entry.hash, !hash.isEmpty {
                let profileId = HistoryRecord.profileId(type: entry.type, hash: hash)
                try? await PayloadCache.shared.write(profileId: profileId, bytes: payload)
            }
        }
        try await client.putClipboard(entry)

        if let hash = entry.hash, !hash.isEmpty {
            store.saveLastSyncedHash(hash)
        }

        // Tell iOS Sharing Suggestions "the user just sent this to this
        // server" so next time the share sheet ranks the server's
        // contact tile higher. Best-effort: failures are swallowed inside.
        await ShareIntentDonation.donateSend(to: server, summary: item.displayName)
    }

    private func build(from item: ShareItem) -> (clipboard: Clipboard, payload: Data?) {
        switch item {
        case .text(let s):
            let (c, p) = Clipboard.publishText(s)
            return (c, p)
        case .image(let bytes, let ext):
            let (c, p) = Clipboard.publishImage(bytes: bytes, ext: ext)
            return (c, p)
        case .file(let name, let bytes):
            let (c, p) = Clipboard.publishFile(name: name, bytes: bytes)
            return (c, p)
        }
    }
}
