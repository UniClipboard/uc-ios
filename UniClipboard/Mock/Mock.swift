import Foundation

/// One row in the History tab — a Clipboard entry with provenance.
struct ClipboardHistoryItem: Identifiable, Hashable {
    enum Direction: Hashable { case pulled, pushed }

    let id = UUID()
    var entry: Clipboard
    var timestamp: Date
    var direction: Direction
}

/// In-memory fake state used while we iterate on the UI. Replace the source of
/// `Mock.servers` / `Mock.serverLatest` / `Mock.deviceClipboard` / `Mock.history`
/// with the real network + UserDefaults layer once the visual design is locked.
enum Mock {
    static let servers = ServerConfigList(
        configs: [
            ServerConfig(
                id: "0c1f2e3a-4b5c-6d7e-8f90-123456789abc",
                name: "Home NAS",
                url: "https://clip.home.lan:5033/",
                username: "alice",
                password: "p4ssw0rd!",
                autoSwitchWifiNames: ["Home-5G", "Home-2.4G"]
            ),
            ServerConfig(
                id: "11223344-5566-7788-99aa-bbccddeeff00",
                name: "Office",
                url: "http://192.168.10.20:5033",
                username: "alice",
                password: "office-secret",
                autoSwitchWifiNames: ["Corp-WiFi"]
            ),
            ServerConfig(
                id: "ff112233-4455-6677-8899-aabbccddeeff",
                name: nil,
                url: "https://clip.example.com",
                username: "alice",
                password: "remote-pass",
                autoSwitchWifiNames: []
            ),
        ],
        activeConfigId: "0c1f2e3a-4b5c-6d7e-8f90-123456789abc"
    )

    static let serverLatest = Clipboard(
        type: .image,
        hash: "4DD7CC4227AA3FB2FDAC2597CB4F88EAC6F69A10BC1994F6B87CF8890C345AFC",
        text: "photo_2026.png",
        hasData: true,
        dataName: "photo_2026.png",
        size: 184320
    )

    /// Device clipboard differs from the server's snapshot — exercises the
    /// "ready to push" UI state.
    static let deviceClipboard = Clipboard(
        type: .text,
        hash: "9F1B0C3D4E5F60718293A4B5C6D7E8F90A1B2C3D4E5F60718293A4B5C6D7E8F9",
        text: "ssh alice@dev.home.lan -p 2222",
        hasData: false,
        size: 30
    )

    static let serverLastSyncedAt: Date = .now.addingTimeInterval(-12 * 60)

    static let history: [ClipboardHistoryItem] = [
        ClipboardHistoryItem(
            entry: serverLatest,
            timestamp: serverLastSyncedAt,
            direction: .pulled
        ),
        ClipboardHistoryItem(
            entry: Clipboard(
                type: .text,
                hash: "3F4E62D9F184380BAD1B0F94B5518DCBF35ACB79B34F6D6E34F3DAB16CD7BC8F",
                text: "Hello, SyncClipboard!",
                hasData: false,
                size: 21
            ),
            timestamp: .now.addingTimeInterval(-55 * 60),
            direction: .pushed
        ),
        ClipboardHistoryItem(
            entry: Clipboard(
                type: .file,
                hash: "088EA33D054B64459EA2EB0CBD9F9152DD0BE4C38C6350963BBA00FDDC94CCEA",
                text: "report.pdf",
                hasData: true,
                dataName: "report.pdf",
                size: 1_048_576
            ),
            timestamp: .now.addingTimeInterval(-3 * 3600),
            direction: .pulled
        ),
        ClipboardHistoryItem(
            entry: Clipboard(
                type: .text,
                hash: "B7E8C3D4F5A6071829304152637485A6B7C8D9E0F1A2B3C4D5E6F70819203142",
                text: "—— BEGIN LONG NOTE ——\n会议纪要 2026-05-08 ……（前 10240 字符为预览）",
                hasData: true,
                dataName: "text_B7E8C3D4F5A6071829304152637485A6B7C8D9E0F1A2B3C4D5E6F70819203142.txt",
                size: 23457
            ),
            timestamp: .now.addingTimeInterval(-26 * 3600),
            direction: .pushed
        ),
        ClipboardHistoryItem(
            entry: Clipboard(
                type: .group,
                hash: "C9D8E7F605142332A1B0C9D8E7F60514233241506A7B8C9DAEBFC0D1E2F30415",
                text: "screenshots.zip",
                hasData: true,
                dataName: "screenshots.zip",
                size: 5_242_880
            ),
            timestamp: .now.addingTimeInterval(-2 * 86400),
            direction: .pulled
        ),
        ClipboardHistoryItem(
            entry: Clipboard(
                type: .text,
                text: "publisher omitted hash; receivers must treat as 'matches anything'",
                hasData: false
            ),
            timestamp: .now.addingTimeInterval(-5 * 86400),
            direction: .pulled
        ),
    ]
}
