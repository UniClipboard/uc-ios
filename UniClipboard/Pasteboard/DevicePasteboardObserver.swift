import Foundation
import UIKit
import Observation

/// Reads `UIPasteboard.general` and exposes the result as an observable
/// `Clipboard?`. App-target-only (UIKit dependency); not built by SwiftPM.
///
/// Re-reads on:
/// - init (for the cold-launch initial value)
/// - `UIPasteboard.changedNotification`
/// - `UIApplication.didBecomeActiveNotification` (foreground)
/// - explicit `read()` calls from the UI (refresh button / pull-to-refresh)
///
/// Reads text and images. Image read priority is PNG > HEIC > JPEG > GIF
/// (PNG is the screenshot default; HEIC over JPEG matches modern Photos).
/// Bytes are pulled via `data(forPasteboardType:)` — never `pb.image`,
/// which decodes through `UIImage` and breaks the §4.2 hash by changing
/// bytes. File and Group reads from UIPasteboard are not meaningful on
/// iOS (Files-app + Share Extension is the right surface for those).
///
/// DEBUG env hooks (only present so design can be inspected without
/// interactive simulator; not feature flags):
/// - `UC_DEVICE_IMAGE=<fixtureName>` → bypass UIPasteboard, return the
///   named built-in image fixture. Optional `UC_DEVICE_IMAGE_EXT=<ext>`
///   overrides the file extension (default `png`). Image hook takes
///   priority over `UC_DEVICE_TEXT` when both are set.
/// - `UC_DEVICE_TEXT`:
///   - unset           → real `UIPasteboard.general` reads
///   - empty string    → reports `nil` (drives empty-state UI)
///   - any other value → reports `Clipboard.fromText(value)`
///
/// Reads on iOS 16+ paint the system "pasted from <App>" banner.
/// Acceptable for now; switching to `UIPasteControl` to suppress is its
/// own UI cycle.
@MainActor
@Observable
final class DevicePasteboardObserver {

    private(set) var current: Clipboard?

    @ObservationIgnored
    private let envMode: EnvMode

    @ObservationIgnored
    private var observers: [NSObjectProtocol] = []

    @ObservationIgnored
    private let notificationCenter: NotificationCenter

    /// `UIPasteboard.changeCount` recorded immediately after our own write.
    /// `read()` short-circuits when the current changeCount matches this —
    /// the changedNotification firing for our own setData/string assignment
    /// is the echo case we want to ignore (otherwise live-mode image apply
    /// would re-canonicalize basename to `image.<ext>` and mis-flag §4.2
    /// as mismatched). External copies always advance changeCount further,
    /// so they still propagate. `-1` as initial sentinel is safe because
    /// `UIPasteboard.changeCount` is non-negative.
    @ObservationIgnored
    private var lastWriteChangeCount: Int = -1

    /// `UIPasteboard.changeCount` recorded after the last successful read,
    /// regardless of who wrote (us or another app). `pollIfChanged()` uses
    /// this to skip the content-access call (which paints iOS's "pasted
    /// from X" banner) when nothing has actually changed since we last
    /// looked. `-1` sentinel so the very first poll always reads.
    ///
    /// Reason this exists: `UIPasteboard.changedNotification` is unreliable
    /// for cross-app changes — and when iOS shows the "Allow Paste" modal
    /// the read that triggered it returns nil, so `current` is stuck nil
    /// until something re-reads. SyncEngine drives that re-read once per
    /// tick via `pollIfChanged`, which is cheap when nothing changed.
    @ObservationIgnored
    private var lastObservedChangeCount: Int = -1

    /// Content hash of the most recent value we wrote to `UIPasteboard`,
    /// uppercase. Secondary echo guard: when changeCount drifts past
    /// `lastWriteChangeCount` (an unrelated process bumped the pasteboard,
    /// iOS posted an extra notification, etc.) we re-snapshot — but if
    /// the snapshot's §4.1/§4.2 hash matches `lastWrittenContentHash`,
    /// the bytes are still ours and we suppress the read. Without this,
    /// the apply path can re-snapshot to a Clipboard with a slightly
    /// different §4.2 basename (because `imageUTIPriority` canonicalizes
    /// to `image.<ext>`), and that re-snapshotted hash drives a spurious
    /// push that pings back as the next pull — the apply↔push pong.
    @ObservationIgnored
    private var lastWrittenContentHash: String?

    /// Gate that defers the first live `UIPasteboard.general` access until
    /// the UI explicitly calls `activate()`. Without this, the observer
    /// reads at init (and again on `didBecomeActiveNotification` during the
    /// initial activation), which fires iOS 16+'s "Allow Paste" prompt
    /// before the user has any visual context — they see the system alert
    /// over a splash / Setup flow they're still trying to read. Env-driven
    /// modes never touch `UIPasteboard.general`, so they auto-activate in
    /// init and previews / screenshot recipes keep working unchanged.
    @ObservationIgnored
    private var isActive: Bool = false

    init(
        notificationCenter: NotificationCenter = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.notificationCenter = notificationCenter
        self.envMode = EnvMode(environment: environment)
        subscribe()
        if case .live = envMode {
            // Defer first read to activate() — see `isActive`.
        } else {
            isActive = true
            read()
        }
    }

    /// Permit pasteboard reads and perform the initial read. Call once
    /// the home tab is on screen so the iOS "Allow Paste" prompt fires
    /// in a context the user can reason about. Idempotent — subsequent
    /// calls just re-read (cheap and useful when re-entering foreground).
    func activate() {
        isActive = true
        read()
    }

    /// Cheap poll: read `UIPasteboard.general.changeCount` (free, no
    /// privacy banner) and only call `read()` when it has advanced past
    /// both our own last write and our last observed value. Called from
    /// `SyncEngine.tick()` at 1Hz so cross-app pasteboard changes — which
    /// `UIPasteboard.changedNotification` does not reliably deliver, and
    /// which `didBecomeActive` only covers on the foreground transition —
    /// get picked up within one tick. Also recovers the case where the
    /// iOS "Allow Paste" modal swallowed the first read after foreground
    /// (the triggering call returned nil; tapping Allow doesn't re-deliver
    /// the bytes — but the next tick will see the same changeCount, read
    /// once more silently, and surface the content).
    ///
    /// Env-driven modes are deterministic and have no changeCount, so this
    /// is a no-op for them — their `current` is set in init and at
    /// `activate()`.
    func pollIfChanged() {
        guard isActive, case .live = envMode else { return }
        let cc = UIPasteboard.general.changeCount
        if cc == lastWriteChangeCount { return }
        if cc == lastObservedChangeCount { return }
        read()
    }

    /// Write `text` to `UIPasteboard.general`. We adopt `current` to the
    /// publish-shape clipboard immediately (don't wait for the change
    /// notification) and capture changeCount so the echo notification is
    /// ignored. Two-layer defense: even if changeCount tracking races, the
    /// adopted `current` already shows the synced state. Under env hooks,
    /// we skip the system call to keep simctl recipes hermetic.
    func write(text: String) {
        switch envMode {
        case .live:
            UIPasteboard.general.string = text
            lastWriteChangeCount = UIPasteboard.general.changeCount
            let adopted = Clipboard.publishText(text).clipboard
            lastWrittenContentHash = adopted.hash?.uppercased()
            current = adopted
        case .forceNil, .forceText, .forceImage:
            let adopted = Clipboard.fromText(text)
            lastWrittenContentHash = adopted.hash?.uppercased()
            current = adopted
        }
    }

    /// Write `data` to `UIPasteboard.general` under a specific UTI. Used
    /// for image apply (write server image bytes back to the device
    /// pasteboard so they can be pasted into another app).
    ///
    /// `originalName`, when non-nil, is the dataName from the server entry
    /// being applied. We adopt it directly so the observer's `current`
    /// carries the same §4.2 basename binding as the server, and the
    /// connector reads "synced" instead of falsely reporting mismatch.
    /// In live mode we ALSO call `setData` and capture `changeCount`; the
    /// echo notification that fires next is ignored by `read()` because
    /// changeCount matches. UIPasteboard discards basename, so without
    /// these two layers a live re-read would canonicalize to `image.<ext>`
    /// and falsely flag `§4.2` mismatch.
    func write(data: Data, uti: String, originalName: String? = nil) {
        let name = originalName ?? "image.\(Self.ext(forUTI: uti))"
        let adopted = Clipboard(
            type: .image,
            hash: Clipboard.computeFileHash(name: name, bytes: data),
            text: name,
            hasData: true,
            dataName: name,
            size: data.count
        )
        // Also stash the canonical-basename hash that `liveSnapshot` would
        // compute when re-reading. UIPasteboard discards basename, so the
        // re-snap always lands on `image.<ext>` — that hash is the one
        // the echo guard needs to compare against. If they're already
        // equal (originalName already in canonical form, or text path),
        // this is the same as adopted.hash.
        let canonicalBasename = "image.\(Self.ext(forUTI: uti))"
        let canonicalHash = Clipboard.computeFileHash(name: canonicalBasename, bytes: data)
        switch envMode {
        case .live:
            UIPasteboard.general.setData(data, forPasteboardType: uti)
            lastWriteChangeCount = UIPasteboard.general.changeCount
        case .forceNil, .forceText, .forceImage:
            break
        }
        lastWrittenContentHash = canonicalHash.uppercased()
        current = adopted
    }

    /// Re-read the pasteboard (or env override) into `current`. Idempotent;
    /// safe to call from notifications and explicit UI triggers. Discards
    /// payload bytes — the UI doesn't need them. Push uses `snapshot()`
    /// instead so it gets fresh bytes at push time.
    ///
    /// Echo guard: when the live `changeCount` equals the one we recorded
    /// after our own most recent write, this is the notification firing
    /// for that write and `current` is already the adopted entry — bail
    /// out so we don't re-canonicalize basename. External copies advance
    /// changeCount further and fall through to the fresh read.
    ///
    /// Secondary hash-equivalence echo guard: when changeCount has drifted
    /// past `lastWriteChangeCount` (an unrelated process bumped the
    /// pasteboard, iOS posted an extra notification, …) we re-snapshot
    /// — but if the snapshot's hash matches `lastWrittenContentHash`,
    /// the bytes are still ours and any further mutation of `current`
    /// would discard the server's `dataName` binding we just adopted.
    /// Keep `current` as-is so the SyncEngine's apply-vs-push gate stays
    /// stable.
    func read() {
        guard isActive else { return }
        if case .live = envMode,
           UIPasteboard.general.changeCount == lastWriteChangeCount {
            return
        }
        guard let snap = snapshot()?.clipboard else {
            // Likely the iOS "Allow Paste" modal swallowed this read — the
            // bytes are not actually nil on the device, we just don't have
            // permission yet. Deliberately do NOT advance
            // `lastObservedChangeCount` here so the next `pollIfChanged`
            // re-reads at the same changeCount once permission lands.
            current = nil
            return
        }
        if case .live = envMode {
            lastObservedChangeCount = UIPasteboard.general.changeCount
        }
        if let written = lastWrittenContentHash,
           let snapHash = snap.hash?.uppercased(),
           written == snapHash {
            // Echo (delayed / out-of-order notification, or external
            // changeCount bump). Don't overwrite `current` — it still
            // carries the server-side basename binding the SyncEngine
            // needs for its dedup.
            return
        }
        current = snap
    }

    /// Bytes-fresh read. Returns the current pasteboard contents as a
    /// `Clipboard` plus the raw bytes (when applicable). Push reads at
    /// push time via this API rather than relying on the cached `current`,
    /// which closes the race where the user copies a new item between an
    /// observer notification firing and the push action firing.
    func snapshot() -> DeviceClipboardSnapshot? {
        guard isActive else { return nil }
        switch envMode {
        case .live:
            return liveSnapshot()
        case .forceNil:
            return nil
        case .forceText(let s):
            let (clip, payload) = Clipboard.publishText(s)
            return DeviceClipboardSnapshot(clipboard: clip, payload: payload)
        case .forceImage(let data, let ext):
            let (clip, payload) = Clipboard.publishImage(bytes: data, ext: ext)
            return DeviceClipboardSnapshot(clipboard: clip, payload: payload)
        }
    }

    private func liveSnapshot() -> DeviceClipboardSnapshot? {
        let pb = UIPasteboard.general
        for (uti, ext) in Self.imageUTIPriority {
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

    /// PNG first (screenshot default + lossless), HEIC over JPEG (modern
    /// Photos), GIF last (rare).
    private static let imageUTIPriority: [(uti: String, ext: String)] = [
        ("public.png", "png"),
        ("public.heic", "heic"),
        ("public.jpeg", "jpg"),
        ("com.compuserve.gif", "gif"),
    ]

    private static func ext(forUTI uti: String) -> String {
        switch uti {
        case "public.png":         return "png"
        case "public.heic", "public.heif": return "heic"
        case "public.jpeg":        return "jpg"
        case "com.compuserve.gif": return "gif"
        default:                   return "bin"
        }
    }

    private func subscribe() {
        observers.append(
            notificationCenter.addObserver(
                forName: UIPasteboard.changedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.read() }
            }
        )
        observers.append(
            notificationCenter.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.read() }
            }
        )
    }

    private enum EnvMode {
        case live
        case forceNil
        case forceText(String)
        case forceImage(Data, String)

        init(environment: [String: String]) {
            if let imgKey = environment["UC_DEVICE_IMAGE"],
               let bytes = ImageFixtures.bytes(for: imgKey) {
                let ext = environment["UC_DEVICE_IMAGE_EXT"] ?? "png"
                self = .forceImage(bytes, ext)
                return
            }
            switch environment["UC_DEVICE_TEXT"] {
            case .none:                        self = .live
            case .some(let s) where s.isEmpty: self = .forceNil
            case .some(let s):                 self = .forceText(s)
            }
        }
    }
}

/// Bytes-fresh read of the device pasteboard. The clipboard metadata for
/// UI display + the raw payload bytes for the push path. Payload is
/// `nil` for short text (everything is in `clipboard.text` already) and
/// non-nil for long text and images.
struct DeviceClipboardSnapshot {
    let clipboard: Clipboard
    let payload: Data?
}

/// Built-in image fixtures keyed by a short name. Same `red8x8` PNG the
/// simctl stub serves so device-side `publishImage` and stub-side
/// `computeFileHash` produce identical §4.2 hashes — cross-recipe
/// consistency without copy-paste.
private enum ImageFixtures {
    static let red8x8PNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAIAQMAAAD+wSzIAAAABGdBTUEAALGP" +
        "C/xhBQAAAAFzUkdCAK7OHOkAAAAGUExURf8AAP///8jJRKEAAAAOSURBVAjX" +
        "Y/jPwMDAAAAEAQEAQYxqNwAAAABJRU5ErkJggg=="
    )!

    static func bytes(for name: String) -> Data? {
        switch name {
        case "red8x8": return red8x8PNG
        default: return nil
        }
    }
}
