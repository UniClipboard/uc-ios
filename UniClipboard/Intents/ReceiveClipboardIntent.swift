import AppIntents
import Foundation
import UIKit

/// "接收" App Intent — pulls the server's latest entry and writes it
/// onto `UIPasteboard.general`. `openAppWhenRun = false` so the user
/// can run it from a Home-Screen icon they made via the Shortcuts app
/// and immediately switch to another app to paste, without ever seeing
/// the UniClipboard window.
///
/// Mirrors `AppViewModel.applyServerToDevice()`'s switch on `Clipboard.Kind`:
/// - `.text` (short): write `entry.text` directly.
/// - `.text` (long, `hasData`): §2.4 `getFile` → §4.1 verify → UTF-8 decode.
/// - `.image` (`hasData`): §2.4 `getFile` → §4.2 verify → `setData` under
///    the matching UTI so apps that read images get the original bytes.
/// - `.file` / `.group`: out of scope (`UIPasteboard` has no meaningful
///    UTI for an arbitrary binary; group needs §4.3).
///
/// Writes `lastSyncedContentHash` after a successful paste so the main
/// app's `SyncEngine`, when it next ticks, sees the device pasteboard
/// matching its watermark and skips an immediate push-back round-trip.
struct ReceiveClipboardIntent: AppIntent {
    static var title: LocalizedStringResource = "接收剪贴板"
    static var description = IntentDescription(
        "从 UniClipboard 服务器拉取最新的剪贴板内容,写入到本机剪贴板。"
    )

    static var openAppWhenRun: Bool = false

    /// See `SendClipboardIntent.perform` for the `@MainActor` rationale —
    /// `SyncClipboardClient` and `SettingsStore` are MainActor-isolated
    /// in this target by the project's default isolation setting.
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = SettingsStore()
        let servers = store.loadServers()
        let appSettings = store.loadAppSettings()
        guard let server = servers.activeConfig else {
            return .result(dialog: "请先在 UniClipboard 中添加一台服务器")
        }

        do {
            let client = try SyncClipboardClient(
                server: server,
                trustInsecureCert: appSettings.trustInsecureCert
            )
            let entry = try await client.getClipboard()

            switch entry.type {
            case .text:
                let text: String
                if entry.hasData, let name = entry.dataName {
                    let bytes = try await client.getFile(name: name)
                    try Self.verify(bytes: bytes, against: entry)
                    text = String(decoding: bytes, as: UTF8.self)
                } else {
                    text = entry.text
                }
                UIPasteboard.general.string = text
            case .image:
                guard entry.hasData, let name = entry.dataName else {
                    return .result(dialog: "服务器最新内容没有图像数据")
                }
                let bytes = try await client.getFile(name: name)
                try Self.verify(bytes: bytes, against: entry)
                let uti = Self.utiForDataName(name)
                UIPasteboard.general.setData(bytes, forPasteboardType: uti)
            case .file, .group:
                return .result(dialog: "服务器最新内容是文件或多类型组合,无法直接粘贴到剪贴板")
            }

            if let hash = entry.hash, !hash.isEmpty {
                store.saveLastSyncedHash(hash)
            }
            return .result(dialog: "已接收最新内容到本机剪贴板")
        } catch let e as SyncError where e.kind == .notFound {
            return .result(dialog: "服务器上还没有任何内容")
        } catch let e as SyncError {
            return .result(dialog: IntentDialog(stringLiteral: "接收失败:\(SendClipboardIntent.errorMessage(e))"))
        }
    }

    /// §4.4 verify, branching on the entry's type because the hash
    /// algorithm differs (§4.1 raw SHA-256 vs §4.2 basename-bound).
    /// Mirrors `AppViewModel.verify(bytes:against:)`.
    private static func verify(bytes: Data, against entry: Clipboard) throws {
        let actual: String
        switch entry.type {
        case .text:
            actual = Clipboard.computeBytesHash(bytes)
        case .image, .file:
            guard let name = entry.dataName else {
                throw SyncError(kind: .hashMismatch, underlying: "missing dataName for \(entry.type)")
            }
            actual = Clipboard.computeFileHash(name: name, bytes: bytes)
        case .group:
            return
        }
        guard Clipboard.hashMatches(expected: entry.hash, actual: actual) else {
            throw SyncError(
                kind: .hashMismatch,
                underlying: "expected=\(entry.hash ?? "<nil>") actual=\(actual)"
            )
        }
    }

    /// Mirror of `AppViewModel.utiForDataName(_:)`.
    private static func utiForDataName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png":          return "public.png"
        case "heic", "heif": return "public.heic"
        case "jpg", "jpeg":  return "public.jpeg"
        case "gif":          return "com.compuserve.gif"
        default:             return "public.data"
        }
    }
}
