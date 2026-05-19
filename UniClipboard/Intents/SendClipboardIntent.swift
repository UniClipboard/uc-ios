import AppIntents
import Foundation
import UIKit

/// "发送" App Intent — pushes the current device pasteboard to the
/// active server. `openAppWhenRun = false` so the user can run it from
/// the Shortcuts app (or a Home-Screen icon they made from it, or
/// Siri, or the Action Button) without the main app window appearing.
///
/// Mirrors `AppViewModel.push()` and the Share Extension's `ShareUploader`
/// closely: same §3.5 file-first sequence, same `lastSyncedContentHash`
/// watermark write so the main app's `SyncEngine`, on its next 1Hz tick,
/// doesn't see the just-pushed entry as "new server content" and echo
/// it back to the device pasteboard (which would otherwise raise the
/// iOS "Allow Paste" banner for no benefit).
///
/// Pasteboard read fires iOS's "Pasted from X" toast — that's the same
/// surface the long-press quick action takes, so behavior matches user
/// expectations across the two entry points.
struct SendClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "发送剪贴板"
    static var description = IntentDescription(
        "把这台设备当前的剪贴板发到 UniClipboard 服务器,供其他设备接收。"
    )

    /// Run silently. Foregrounding the app for a push the user already
    /// understands is just noise on the Springboard.
    static var openAppWhenRun: Bool = false

    /// `@MainActor` because the project sets
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which makes
    /// `SettingsStore`, `ServerConfigList.activeConfig`, and
    /// `SyncClipboardClient.init` all MainActor-isolated in this target.
    /// The AppIntent protocol leaves `perform()` unisolated, so without
    /// this annotation the compiler emits Swift-6-error-class warnings on
    /// every cross-isolation call. The body is `await`-heavy and hops to
    /// background work via URLSession internally — keeping the perform
    /// on MainActor doesn't pin the network.
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = SettingsStore()
        let servers = store.loadServers()
        let appSettings = store.loadAppSettings()
        guard let server = servers.activeConfig else {
            return .result(dialog: "请先在 UniClipboard 中添加一台服务器")
        }

        guard let snapshot = pasteboardSnapshot() else {
            return .result(dialog: "剪贴板为空,没有可发送的内容")
        }

        do {
            let client = try SyncClipboardClient(
                server: server,
                trustInsecureCert: appSettings.trustInsecureCert
            )
            // §3.5: payload bytes first, metadata second. Without this
            // order the server can briefly serve a metadata pointer to a
            // missing file.
            if snapshot.clipboard.hasData,
               let payload = snapshot.payload,
               let name = snapshot.clipboard.dataName {
                try await client.putFile(name: name, body: payload)
            }
            try await client.putClipboard(snapshot.clipboard)
            if let hash = snapshot.clipboard.hash, !hash.isEmpty {
                store.saveLastSyncedHash(hash)
            }
            return .result(dialog: IntentDialog("已发送到 \(server.displayLabel)"))
        } catch let e as SyncError {
            return .result(dialog: IntentDialog(stringLiteral: "发送失败:\(Self.errorMessage(e))"))
        }
    }

    /// Mirrors `DevicePasteboardObserver.liveSnapshot()` — kept inline
    /// instead of plumbed through the observer because the intent runs
    /// outside the SwiftUI/`AppViewModel` graph and shouldn't drag a
    /// MainActor-isolated `@Observable` along for one read.
    private func pasteboardSnapshot() -> DeviceClipboardSnapshot? {
        let pb = UIPasteboard.general
        // PNG > HEIC > JPEG > GIF, same priority as the observer so a
        // screenshot pushed via the intent hashes identically to one
        // pushed via the auto-sync tick.
        let imageUTIs: [(uti: String, ext: String)] = [
            ("public.png", "png"),
            ("public.heic", "heic"),
            ("public.jpeg", "jpg"),
            ("com.compuserve.gif", "gif"),
        ]
        for (uti, ext) in imageUTIs {
            if let data = pb.data(forPasteboardType: uti), !data.isEmpty {
                let (clip, payload) = Clipboard.publishImage(bytes: data, ext: ext)
                return DeviceClipboardSnapshot(clipboard: clip, payload: payload)
            }
        }
        if let s = pb.string, !s.isEmpty {
            let (clip, payload) = Clipboard.publishText(s)
            return DeviceClipboardSnapshot(clipboard: clip, payload: payload)
        }
        return nil
    }

    /// User-facing message for `SyncError`. Duplicated from the
    /// HomeView's private `errorMessage(_:)` rather than extracted to a
    /// shared helper — Intent dialogs are short, the catalog of cases
    /// is small, and tying the two together creates a refactoring
    /// blast radius we don't need.
    static func errorMessage(_ err: SyncError) -> String {
        switch err.kind {
        case .authFailed:                return String(localized: "认证失败 — 请检查用户名和密码")
        case .connectTimeout:            return String(localized: "连接超时 — 请检查服务器地址")
        case .receiveTimeout:            return String(localized: "接收超时 — 请稍后重试")
        case .networkUnreachable:        return String(localized: "无法连接 — 请检查网络和 URL")
        case .invalidURL:                return String(localized: "服务器地址无效")
        case .decodingFailed:            return String(localized: "服务器返回的数据无法解析")
        case .protocolError(let code):   return String(localized: "服务器返回 HTTP \(code)")
        case .serverError(let code):     return String(localized: "服务器错误 \(code)")
        case .notFound:                  return String(localized: "服务器尚未发布剪贴板")
        case .hashMismatch:              return String(localized: "内容校验失败 — 文件可能损坏")
        }
    }
}
