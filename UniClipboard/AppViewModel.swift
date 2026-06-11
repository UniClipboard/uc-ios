import Foundation
import Observation
import OSLog
import SentryWithoutUIKit

private let log = Logger(subsystem: "app.uniclipboard", category: "app")

/// Owns the app's persisted state and writes mutations back to disk
/// automatically. Sits between the views and `SettingsStore`.
///
/// Lives in the app layer (not in the SwiftPM `Models` target) because
/// `@Observable` and `@MainActor` are SwiftUI-shaped concerns; the model
/// types it carries (`ServerConfigList`, `AppSettings`) are the
/// Foundation-only ones from `Models/`.
@MainActor
@Observable
final class AppViewModel {
    var servers: ServerConfigList {
        didSet {
            store.saveServers(servers)
            // A manual pick / add / delete / edit may change which server is
            // *effective* (§5.3 baseline + Wi-Fi overlay); reconcile drops
            // per-server engine state when so.
            reconcileActiveServer()
            // Same-server credential edit (same id, new password): the
            // effective id didn't change, so `reconcileActiveServer` won't
            // restart a paused .authFailed loop — kick it here so the new
            // credentials get retried on the next tick.
            if engine?.state == .authFailed { engine?.start() }
        }
    }

    var appSettings: AppSettings {
        didSet { store.saveAppSettings(appSettings) }
    }

    /// Last clipboard fetched from the active server. Runtime state, not
    /// persisted — spec §5.5 doesn't list a key for it and stale data on
    /// cold launch would mislead.
    var serverLatest: Clipboard?

    /// Recent clipboard entries shown on the Home list, newest-first.
    /// `SyncEngine` is the canonical writer — it appends a `.pulled` entry
    /// on each successful server fetch with new content (§2.1) and a
    /// `.pushed` entry on each successful publish (§2.2). Persisted to
    /// the App Group via `SettingsStore.saveHistory` on every mutation,
    /// so cold launches recover the same list the user just saw.
    /// Hydrated from disk in `init`; previews override post-init.
    var history: [ClipboardHistoryItem] = [] {
        didSet { store.saveHistory(history) }
    }

    /// Cap kept on `history` to bound the persisted JSON size and the
    /// list-render cost. Picked empirically — 200 newest-first entries is
    /// ~30 KB encoded and renders smoothly in `List` without virtualization
    /// tricks. Older entries fall off when `appendHistory` grows past it.
    private static let maxHistoryCount = 200

    /// Incremental-sync watermark for §2.7 `POST /api/history/query`. The
    /// largest `lastModified` seen on any prior page; passed back as
    /// `modifiedAfter` so the server only returns strictly newer records.
    /// `nil` triggers a full pull on the next sync (cold-launch state, or
    /// after switching servers). Persisted as ISO-8601 via `SettingsStore`.
    var historyWatermark: Date? {
        didSet { store.saveHistoryWatermark(historyWatermark) }
    }

    /// When `serverLatest` was last refreshed (success or 404). Reset on
    /// every `refresh()` outcome so the UI's "5 minutes ago" label tracks
    /// reality.
    var lastSyncedAt: Date?

    /// Last error from `refresh()`. Cleared on success.
    var refreshError: SyncError?

    /// Whether a refresh is in flight.
    var isRefreshing: Bool = false

    /// When the device clipboard was last successfully pushed to the
    /// active server. Runtime state — not persisted. Cleared on push
    /// failure so the UI doesn't show a misleading "上次推送 5 秒前"
    /// next to a fresh error banner.
    var lastPushedAt: Date?

    /// Last error from `push()`. Cleared on success.
    var pushError: SyncError?

    /// Whether a push is in flight.
    var isPushing: Bool = false

    /// Whether `applyServerToDevice()` is in flight (long-text path only;
    /// short text completes synchronously and never sets this).
    var isApplying: Bool = false

    /// Last error from `applyServerToDevice()`. Cleared on success.
    var applyError: SyncError?

    /// Whether `saveServerAttachment()` is in flight.
    var isSaving: Bool = false

    /// Last error from `saveServerAttachment()`. Cleared on success.
    var saveError: SyncError?

    /// File URL of the most-recent successful `saveServerAttachment()`.
    /// Cleared on the next refresh or save attempt so the UI's
    /// "已保存到 …" caption doesn't outlive its relevance.
    var lastSavedFileURL: URL?

    /// Parsed `uniclipboard://connect?…` payload waiting for the user to
    /// approve or reject. Set by `handleIncomingURL(_:)` when a connect
    /// URI lands via `.onOpenURL` (system Camera) or any other URL
    /// dispatcher. `ContentView` observes this:
    ///  • configs empty → SetupFlow seeds the form fields and navigates.
    ///  • configs non-empty → a confirmation sheet appears with a masked
    ///    preview; the user appends the new server or dismisses.
    /// Cleared via `consumePendingImport()` once the view has taken over.
    var pendingImport: ConnectURI.Payload?

    /// Last `ConnectURI.parse` failure surfaced from `handleIncomingURL`.
    /// Drives a root-level alert so the user notices that the QR scanned
    /// from the Camera app didn't actually do anything. Cleared on the
    /// next successful URL or when the alert dismisses.
    var importError: ConnectURI.ParseError?

    /// Display name of the most-recent successful `applyAttachment(for:)`
    /// — drives the bottom-banner "已复制 <name> 到剪贴板". Same
    /// transient-feedback lifecycle as `lastSavedFileURL`; cleared on the
    /// next refresh / apply / save attempt.
    var lastAppliedAttachmentName: String?

    /// Current device pasteboard snapshot. Computed; the observer is the
    /// source of truth and `@Observable` propagates its `current` reads
    /// through this accessor automatically.
    var deviceClipboard: Clipboard? { pasteboard.current }

    @ObservationIgnored
    private let store: SettingsStore

    @ObservationIgnored
    private let pasteboard: DevicePasteboardObserver

    /// Auto-sync engine. Constructed during init, started/stopped by the
    /// view layer (`ContentView` watches `scenePhase`). Implicitly
    /// unwrapped because `SyncEngine.init` needs a fully-initialized
    /// `AppViewModel` reference, which only exists after all other stored
    /// properties are assigned.
    @ObservationIgnored
    private(set) var engine: SyncEngine!

    /// Reads the current Wi-Fi SSID via `CNCopyCurrentNetworkInfo`. Owned
    /// at the app-VM layer so the same instance backs the SSID editor
    /// (Settings → Servers) and the SetupFlow auto-switch step.
    /// Observable — views bind directly to `authState` / `currentSSID`.
    let ssidProvider: CurrentSSIDProvider

    /// - Parameters:
    ///   - store: persistence backend; default uses `UserDefaults.standard`.
    ///   - forceFreshServers: when true, ignore stored servers and start
    ///     with an empty list (drives the SetupFlow). Defaults to reading
    ///     `UC_FRESH=1` from the environment so screenshot recipes work.
    ///   - pasteboard: device pasteboard observer; default reads
    ///     `UIPasteboard.general` (or honors `UC_DEVICE_TEXT` env hook).
    init(
        store: SettingsStore? = nil,
        forceFreshServers: Bool = ProcessInfo.processInfo.environment["UC_FRESH"] == "1",
        pasteboard: DevicePasteboardObserver? = nil
    ) {
        // MainActor-isolated defaults (SettingsStore.init, DevicePasteboardObserver)
        // must be built in the init body — default-argument expressions are
        // evaluated in a nonisolated context.
        let store = store ?? SettingsStore()
        self.store = store
        self.pasteboard = pasteboard ?? DevicePasteboardObserver()
        self.servers = forceFreshServers ? ServerConfigList() : store.loadServers()
        self.appSettings = store.loadAppSettings()
        self.history = store.loadHistory()
        self.historyWatermark = store.loadHistoryWatermark()
        self.ssidProvider = CurrentSSIDProvider()
        self.engine = SyncEngine(viewModel: self, store: store)
        // A network change can now flip the *effective* server on its own
        // (§5.3 on-demand auto-switch — Wi-Fi SSID, cellular, or other). On
        // each change we publish the SSID to the App Group (so the keyboard
        // resolves the same server) and reconcile the engine. Captured weakly
        // because the provider outlives the engine reference inside `self`.
        self.ssidProvider.onNetworkChanged = { [weak self] context in
            self?.handleNetworkChanged(context)
        }
        // Seed bookkeeping + the cross-process SSID from the current state:
        // the keyboard then has a network to read even before the first
        // flip, and the first reconcile compares against the right baseline.
        // The live URL persisted by the previous launch's probe is the best
        // first guess until the foreground-triggered probe lands.
        self.liveURL = servers.activeConfig.flatMap { store.loadLiveURL(configId: $0.id) }
        self.lastEffectiveServerId = self.activeServer?.id
        store.saveLastKnownSSID(self.ssidProvider.currentSSID)
        // Upgrade guard: an install that already has servers predates the
        // onboarding flow, so mark both the first-run walkthrough AND the
        // post-pairing enhancements carousel as shown — returning/upgrading
        // users must never get either. Batched into one assignment so the
        // `appSettings` didSet persists once. `forceFreshServers` (UC_FRESH)
        // empties configs, so those screenshot runs are exempt and still reach
        // SetupFlow/onboarding.
        if !servers.configs.isEmpty && !appSettings.onboardingShown {
            var s = appSettings
            s.onboardingShown = true
            s.enhancementsPromptShown = true
            appSettings = s
        }
    }

    /// Mark the first-run onboarding (feature walkthrough) as finished. Flips
    /// `onboardingShown` (persisted via the `appSettings` didSet) so
    /// `ContentView` stops routing into `OnboardingView` and falls through to
    /// the SetupFlow (configs empty) or the main Tabs (configs present).
    func completeOnboarding() {
        guard !appSettings.onboardingShown else { return }
        appSettings.onboardingShown = true
    }

    /// The server in use *right now* — the manual baseline (§5.2
    /// `activeConfig`) with its candidate URLs re-ordered for the current
    /// network AND the last probe's verdict (§5.3 `preferredURLs`): a
    /// probe-confirmed `liveURL` leads, shape-ordered candidates follow as
    /// fallbacks, so `urls[0]` (== `url`, what the per-tick client builder
    /// reads) is the best-known path. Which *profile* is active stays the
    /// user's manual pick — the network only re-orders that profile's URLs.
    /// `servers`, `liveURL`, and `ssidProvider`'s fields are all
    /// `@Observable`, so views recompute when any of them changes.
    var activeServer: ServerConfig? {
        guard var cfg = servers.activeConfig else { return nil }
        cfg.urls = cfg.preferredURLs(live: liveURL, network: ssidProvider.networkContext)
        return cfg
    }

    /// In-memory mirror of the active profile's probe-confirmed URL (§5.3
    /// Layer 2). Source of truth is the App Group `live_urls` file
    /// (`SettingsStore.loadLiveURL`) — mirrored here because the store
    /// isn't observable and `activeServer` is recomputed by SwiftUI on
    /// every render. `nil` = last probe found nothing reachable, or no
    /// probe ran yet (then `activeServer` falls back to pure shape order).
    /// Hydrated on init and on profile switch; written by
    /// `refreshLiveEndpoint()`.
    private(set) var liveURL: String?

    /// Set the manual baseline server to `id`. Called by the home chip
    /// switcher and Settings. Going through the view-model keeps persistence
    /// + engine-restart centralized: `servers.didSet` fires
    /// `reconcileActiveServer`, which resets per-server runtime state
    /// (last-synced hash, history watermark) when the *effective* server
    /// flips. Note a Wi-Fi auto-switch rule can still override this pick
    /// while the matching network is connected (§5.3); the baseline takes
    /// effect again once that network is left.
    func setActiveServer(_ id: String) {
        var list = servers
        list.activeConfigId = id
        servers = list
    }

    /// The effective active-server id (§5.3) as of the last reconcile. Drives
    /// the "did the server actually change?" decision in
    /// `reconcileActiveServer`, so a `servers` mutation or SSID change that
    /// leaves the effective server untouched doesn't needlessly reset the
    /// engine. Pure bookkeeping — not view state.
    @ObservationIgnored
    private var lastEffectiveServerId: String?

    /// Reconcile the engine against the current effective server (§5.3).
    /// Called whenever something that feeds `effectiveActiveConfig` changes:
    /// a `servers` mutation (manual pick / add / delete / edit) or an SSID
    /// change (Wi-Fi auto-switch). When the resolved id differs from the one
    /// we last acted on, hand off to the engine to drop per-server state and
    /// re-tick against the new server.
    func reconcileActiveServer() {
        let newId = activeServer?.id
        guard newId != lastEffectiveServerId else { return }
        log.info("reconcileActiveServer: effective server \(self.lastEffectiveServerId ?? "nil", privacy: .public) → \(newId ?? "nil", privacy: .public)")
        lastEffectiveServerId = newId
        // Different profile → its live URL is whatever the last probe
        // persisted for *it* (possibly from a prior launch). Hydrate the
        // mirror before the engine restarts so the first tick already hits
        // the best-known URL, then re-probe to confirm it's still current.
        liveURL = newId.flatMap { store.loadLiveURL(configId: $0) }
        engine?.handleActiveServerChanged()
        if newId != nil { kickLiveEndpointRefresh(force: true) }
    }

    /// Hook fired by `CurrentSSIDProvider.onNetworkChanged`. Three jobs: (1)
    /// publish the current SSID to the App Group so the keyboard extension
    /// resolves the same on-demand server (`SettingsStore.saveLastKnownSSID`
    /// — `context.ssid` is nil on cellular / no-Wi-Fi, which clears the file
    /// so the keyboard never trusts a stale name), (2) reconcile the engine
    /// in case the change flipped the effective server, and (3) re-probe the
    /// candidates — the URL that was reachable on the old network may not be
    /// on the new one (§5.3 Layer 2).
    private func handleNetworkChanged(_ context: NetworkContext) {
        store.saveLastKnownSSID(context.ssid)
        reconcileActiveServer()
        kickLiveEndpointRefresh(force: true)
    }

    // MARK: - §5.3 Layer 2: live-endpoint probing

    /// In-flight probe, for deduplication — a second caller awaits the
    /// running probe instead of stacking another. Not view state.
    @ObservationIgnored
    private var liveProbeTask: Task<Void, Never>?

    /// When the last probe *finished*, for debouncing. The engine retries a
    /// failing GET at 1Hz and asks for a re-probe on every failure; without
    /// this window each tick would burn a full probe round against every
    /// candidate.
    @ObservationIgnored
    private var lastLiveProbeAt: Date?

    /// Minimum gap between non-forced probes. Forced probes (profile
    /// switch, network change, foreground) bypass it — those events
    /// invalidate the previous verdict by definition.
    private static let liveProbeDebounce: TimeInterval = 10

    /// Fire-and-forget wrapper for synchronous call sites (network-change
    /// hook, scenePhase observer, engine tick).
    func kickLiveEndpointRefresh(force: Bool = false) {
        Task { await refreshLiveEndpoint(force: force) }
    }

    /// "测试连接" already probed every candidate of `configId` (§5.3) —
    /// adopt its verdict as the profile's live URL instead of making the
    /// engine re-discover it on the next failure. `url == nil` (nothing
    /// reachable) clears the cache so readers fall back to shape order.
    func adoptProbedLiveURL(configId: String, url: String?) {
        store.saveLiveURL(configId: configId, url)
        if servers.activeConfig?.id == configId, liveURL != url {
            liveURL = url
        }
    }

    /// §5.3 Layer 2 — probe the active profile's candidates on the current
    /// network and persist the first reachable one (shape order, NOT a
    /// race) as the profile's live URL; all-unreachable persists nil so
    /// readers fall back to pure shape order. The engine is *not* reset
    /// when the URL flips within the same profile — same server, same
    /// content timeline, so the sync watermarks stay valid; the per-tick
    /// client rebuild picks the new `urls[0]` up automatically.
    func refreshLiveEndpoint(force: Bool = false) async {
        if let inflight = liveProbeTask {
            await inflight.value
            return
        }
        guard let base = servers.activeConfig else { return }
        if !force, let last = lastLiveProbeAt,
           Date.now.timeIntervalSince(last) < Self.liveProbeDebounce {
            return
        }
        let ordered = base.orderedURLs(network: ssidProvider.networkContext)
        let trust = appSettings.trustInsecureCert
        let task = Task { [weak self] in
            let results = await ConnectionTester.probe(
                urls: ordered,
                username: base.username,
                password: base.password,
                trustInsecureCert: trust
            )
            let picked = ConnectionTester.firstReachable(in: ordered, results: results)
            guard let self else { return }
            self.lastLiveProbeAt = .now
            // The user switched profiles while the probe was in flight —
            // these results describe the old profile's candidates.
            guard self.servers.activeConfig?.id == base.id else { return }
            if self.liveURL != picked {
                log.info("liveProbe: live URL changed → \(picked ?? "none reachable", privacy: .private)")
            }
            self.store.saveLiveURL(configId: base.id, picked)
            if self.liveURL != picked { self.liveURL = picked }
        }
        liveProbeTask = task
        await task.value
        liveProbeTask = nil
    }

    /// Entry point for `.onOpenURL`. Parses the incoming URL as a
    /// `uniclipboard://connect?…` URI; on success stages the payload in
    /// `pendingImport` for the view layer to confirm, on failure stages
    /// the error in `importError`. Non-`uniclipboard` schemes are not
    /// the system's job to filter (the scheme registration only routes
    /// `uniclipboard://`), but we still validate defensively so a future
    /// dispatcher can call this with arbitrary URLs without breaking the
    /// state machine.
    func handleIncomingURL(_ url: URL) {
        let raw = url.absoluteString
        do {
            let payload = try ConnectURI.parse(raw)
            pendingImport = payload
            importError = nil
        } catch let e as ConnectURI.ParseError {
            // .private: the raw URI / parse detail can embed credentials.
            log.warning("handleIncomingURL: connect URI parse failed: \(String(describing: e), privacy: .private)")
            pendingImport = nil
            importError = e
        } catch {
            // ConnectURI.parse only throws ParseError; this branch keeps
            // the compiler happy and the state machine consistent.
            pendingImport = nil
            importError = .payloadDecodeFailed(detail: "\(error)")
        }
    }

    /// Read-and-clear `pendingImport`. The setup flow calls this when it
    /// finishes navigating to the prefilled form so a stale payload
    /// doesn't trigger the path-replacement task on the next render.
    func consumePendingImport() -> ConnectURI.Payload? {
        let p = pendingImport
        pendingImport = nil
        return p
    }

    /// Append a connect-URI payload as a new `ServerConfig` and switch
    /// to it. Called by `ConnectImportSheet` after the user confirms.
    /// `label` becomes the human-friendly name; missing label falls back
    /// to nil (the `displayLabel` getter handles URL-as-fallback per §5.1).
    /// The full §4 candidate list (`payload.urls` — already validated and
    /// never empty) carries over, so a QR published with lan+tailscale+wan
    /// alternates auto-switches from the first tick.
    func acceptPendingImport(_ payload: ConnectURI.Payload) {
        var list = servers
        let name = payload.label.flatMap {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let config = ServerConfig(
            id: UUID().uuidString.lowercased(),
            name: name,
            urls: payload.urls,
            username: payload.user,
            password: payload.pwd
        )
        list.configs.append(config)
        // The user just expressed intent to use this new server — make it
        // the current one.
        list.activeConfigId = config.id
        servers = list
        pendingImport = nil
    }

    /// Re-read the device pasteboard. Triggered by toolbar refresh and
    /// pull-to-refresh; foreground / pasteboard-changed notifications
    /// re-read automatically.
    func readPasteboard() { pasteboard.read() }

    /// Cheap changeCount-gated CONTENT poll. Reads `UIPasteboard` and may
    /// fire the "Allow Paste" prompt — only called by `SyncEngine` when the
    /// user has opted into auto-push (`autoPushDeviceChanges`).
    func pollPasteboardIfChanged() { pasteboard.pollIfChanged() }

    /// Free, no-prompt detection poll. Updates `pasteboardDetection` from
    /// `changeCount`/`hasStrings` only. Called by `SyncEngine` each tick
    /// when auto-push is OFF (the default) so a fresh local copy surfaces
    /// the Home push hint without ever reading content unprompted.
    func pollPasteboardDetection() { pasteboard.pollDetectionIfChanged() }

    /// No-prompt hint that the device pasteboard holds pushable content.
    /// Drives the Home outgoing push row (`SyncNudgeStack`). `nil` when
    /// there's nothing new to push. Observable through the underlying
    /// observer; cleared by `adoptConsentPush` on a successful push.
    var pasteboardDetection: PasteboardDetection? { pasteboard.detection }

    /// Push content the user just handed us via the Home `PasteButton`.
    /// The system paste control already granted access (no prompt), so we
    /// extract the providers and route them through the engine's consent
    /// push — which PUTs the bytes, advances the synced hash (so the next
    /// pull doesn't echo it back), logs history, and clears the hint.
    func pushPastedProviders(_ providers: [NSItemProvider]) async {
        guard let snapshot = await PastedItemExtractor.snapshot(from: providers) else { return }
        await engine.consentPush(snapshot)
    }

    /// Permit pasteboard access. Call once the main tabs are on screen.
    /// Runs only the free detection poll — it does NOT read content, so it
    /// no longer fires the iOS "Allow Paste" prompt on launch. Idempotent.
    func activatePasteboard() { pasteboard.activate() }

    /// Forwarded from `SyncEngine.consentPush` after a successful Home
    /// `PasteButton` push: mark the pushed content as the current device
    /// clipboard and clear the push hint.
    func adoptConsentPush(_ entry: Clipboard) { pasteboard.adoptConsentPush(entry) }

    /// Re-apply a history item: move it to the top of history, write to
    /// the device pasteboard (text / filename — image bytes are written by
    /// `applyAttachment` before this is called), and record the written
    /// hash with the engine so the next tick neither re-pushes the
    /// self-written content nor logs it as a new `.local` entry.
    ///
    /// `lastSyncedContentHash` is NOT advanced here — that happens in
    /// `pushHistoryEntryToServer` once the PUT actually lands, keeping the
    /// engine's view of the server truthful while the push is in flight
    /// (or if it fails).
    func reapplyHistoryItem(_ item: ClipboardHistoryItem) {
        moveHistoryItemToTop(item)
        switch item.entry.type {
        case .text:
            pasteboard.write(text: item.entry.text)
            // For §3.4 overflow entries `text` is the truncated inline
            // part, so hash what we actually wrote, not `entry.hash`.
            engine.noteReapplyWritten(
                deviceHash: Clipboard.publishText(item.entry.text).clipboard.hash
            )
        case .image:
            // Bytes already adopted by the observer via applyAttachment;
            // verify guarantees they hash to `entry.hash`.
            engine.noteReapplyWritten(deviceHash: item.entry.hash)
        case .file, .group:
            // UIPasteboard can't carry an arbitrary file — copy the
            // filename as text, through the observer so the write is
            // adopted (a raw `UIPasteboard.general.string =` write would
            // be picked up by the next tick as brand-new local content
            // and pushed, overwriting the file entry on the server).
            let name = item.entry.dataName ?? item.entry.text
            pasteboard.write(text: name)
            engine.noteReapplyWritten(
                deviceHash: Clipboard.publishText(name).clipboard.hash
            )
        }
    }

    /// Push a history entry to the server as the new "latest" so other
    /// devices see the re-applied content. For entries with payload data
    /// (images/files), bytes are fetched from the local cache or the
    /// history API (§2.11) and re-uploaded via §3.5.
    func pushHistoryEntryToServer(_ item: ClipboardHistoryItem) async {
        let entry = item.entry
        guard let server = activeServer else { return }
        let engineState = engine.state
        if engineState == .authFailed || engineState == .loopDetected { return }

        do {
            let client = try SyncClipboardClient(
                server: server,
                trustInsecureCert: appSettings.trustInsecureCert
            )

            if entry.hasData, let dataName = entry.dataName,
               let hash = entry.hash, !hash.isEmpty {
                let bytes: Data
                if let cached = store.loadImageData(hash: hash) {
                    bytes = cached
                } else {
                    let profileId = HistoryRecord.profileId(type: entry.type, hash: hash)
                    bytes = try await Self.fetchHistory(client: client, profileId: profileId)
                }
                try await client.putFile(name: dataName, body: bytes)
            }

            try await client.putClipboard(entry)
            serverLatest = entry
        } catch {
            // Best-effort by design (the local re-apply already succeeded),
            // but a silent return left no trace at all when other devices
            // never received the re-applied entry.
            log.error("pushHistoryEntryToServer: failed type=\(entry.type.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            SentrySDK.logger.warn(
                "history re-push failed",
                attributes: ["type": entry.type.rawValue]
            )
            return
        }

        engine.advanceSyncedForReapply(to: entry.hash)
    }

    private func moveHistoryItemToTop(_ item: ClipboardHistoryItem) {
        if let idx = history.firstIndex(where: { $0.id == item.id }) {
            var moved = history.remove(at: idx)
            moved.timestamp = .now
            history.insert(moved, at: 0)
        }
    }

    /// Remove one row from the in-memory `history` list. Operates on the
    /// stable `ClipboardHistoryItem.id` so deletion is safe across
    /// re-sorts. The protocol has no concept of "delete from server" for
    /// the live clipboard — the spec only keeps one record, so this is a
    /// local-cache-only mutation today.
    func removeHistoryItem(id: UUID) {
        let removed = history.filter { $0.id == id }
        history.removeAll { $0.id == id }
        Self.scheduleCacheDelete(removed.compactMap { Self.profileIdIfAny($0.entry) })
    }

    /// Append a sync event to `history`. Inserted at index 0 so the
    /// time-descending UI sort holds without re-scanning. Dedups against
    /// the immediately-prior entry of the same direction + hash — without
    /// this the engine's `lastSyncedContentHash` short-circuits cover the
    /// common case but a quick toggle of auto-apply (which re-routes
    /// through `processServerNew` with the same staged hash) would
    /// double-log. A `nil` hash is treated as "always new" since the
    /// publisher chose not to fingerprint, and we have nothing to dedup
    /// against.
    func appendHistory(entry: Clipboard, direction: ClipboardHistoryItem.Direction, at timestamp: Date = .now) {
        // Same content already at the top → never insert a duplicate row,
        // regardless of direction. Upgrade `.local` provenance to
        // pushed/pulled in place; keep the stronger direction otherwise
        // (a re-observation of content we already attributed shouldn't
        // downgrade it back to `.local`).
        if let hash = entry.hash,
           let last = history.first,
           last.entry.hash == hash {
            if direction != .local, last.direction != direction {
                history[0].direction = direction
            }
            return
        }
        history.insert(
            ClipboardHistoryItem(entry: entry, timestamp: timestamp, direction: direction),
            at: 0
        )
        trimHistoryAndPruneCache()
    }

    func updateHistoryDirection(hash: String?, to newDirection: ClipboardHistoryItem.Direction) {
        guard let hash, !hash.isEmpty else { return }
        let normalized = hash.uppercased()
        if let idx = history.firstIndex(where: {
            $0.entry.hash?.uppercased() == normalized
        }) {
            history[idx].direction = newDirection
        }
    }

    /// Merge one server-side `HistoryRecord` (§3.6) into the local
    /// observation log. Idempotent — call as many times as you like with
    /// the same record.
    ///
    /// Semantics:
    /// - `isDeleted=true` tombstone → remove any local entry with the
    ///   matching hash (case-insensitive). The spec says clients treat
    ///   soft-deleted as absent (§3.6 lifecycle).
    /// - Existing local entry with same hash → keep the entry but pull
    ///   the timestamp earlier if the server's `createTime` is older
    ///   (more accurate — `appendHistory` stamps with `.now`, which is
    ///   close but not the actual creation moment).
    /// - New hash → insert in the right time-descending slot so the UI
    ///   sort holds without re-sorting; preserve the `maxHistoryCount`
    ///   cap.
    ///
    /// The merged `direction` is `.pulled` — from this device's POV the
    /// record arrived from the server. If it was originally pushed from
    /// this device, the local `.pushed` entry already covers that case
    /// (and the hash match above wins, so we don't double-log).
    func mergeHistoryRecord(_ record: HistoryRecord) {
        let normalized = record.hash.uppercased()
        if record.isDeleted {
            history.removeAll { ($0.entry.hash?.uppercased()) == normalized }
            Self.scheduleCacheDelete([HistoryRecord.profileId(type: record.type, hash: normalized)])
            return
        }
        if let idx = history.firstIndex(where: { ($0.entry.hash?.uppercased()) == normalized }) {
            let serverStamp = record.createTime ?? record.lastModified ?? history[idx].timestamp
            history[idx].timestamp = min(history[idx].timestamp, serverStamp)
            return
        }
        // §3.6 doesn't list `dataName` on HistoryRecord, but per §3.3 the
        // `text` field on image/file types IS the basename (the same one
        // the live-clipboard endpoint uses). Reusing it as `dataName`
        // gives downstream save/apply code a filename without forcing a
        // separate endpoint round-trip. For text-type records `dataName`
        // remains nil — the text content is inline in `text`.
        let dataName: String? = {
            switch record.type {
            case .image, .file, .group:
                let t = (record.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            case .text:
                return nil
            }
        }()
        let entry = Clipboard(
            type: record.type,
            hash: record.hash,
            text: record.text ?? "",
            hasData: record.hasData,
            dataName: dataName,
            size: record.size
        )
        let timestamp = record.createTime ?? record.lastModified ?? .now
        let item = ClipboardHistoryItem(entry: entry, timestamp: timestamp, direction: .pulled)
        // Time-descending insert. firstIndex(where:) is O(n) but n is
        // bounded by maxHistoryCount and we run this incrementally per
        // record, so it's a non-issue in practice.
        let insertIdx = history.firstIndex(where: { $0.timestamp < timestamp }) ?? history.count
        history.insert(item, at: insertIdx)
        trimHistoryAndPruneCache()
    }

    /// Write the active server's clipboard to the device. Text: short
    /// path writes from metadata `text`; long path downloads §2.4 payload,
    /// §4.1-verifies via bytes hash, decodes UTF-8, writes. Image:
    /// downloads payload, §4.2-verifies (basename + bytes), writes the
    /// raw bytes under the matching UTI. File/Group are no-ops — file
    /// bytes have no meaningful UIPasteboard target, group needs §4.3.
    func applyServerToDevice() async {
        _ = try? await applyServerToDeviceThrowing()
    }

    /// Throwing variant of `applyServerToDevice()` used by `SyncEngine`.
    /// Returns `true` when bytes actually landed on the pasteboard;
    /// `false` for documented silent skips (file/group entry, no server,
    /// no `dataName`, observer in-flight). Throws `SyncError` on a real
    /// network/verify failure. UI-visible `applyError` is set/cleared in
    /// the same shape as `applyServerToDevice()`, so the rest of the app
    /// doesn't need to know which variant ran.
    @discardableResult
    func applyServerToDeviceThrowing() async throws -> Bool {
        guard let entry = serverLatest else { return false }
        switch entry.type {
        case .text:
            if !entry.hasData {
                pasteboard.write(text: entry.text)
                applyError = nil
                return true
            }
            guard !isApplying else { return false }
            guard let server = activeServer, let dataName = entry.dataName else { return false }
            isApplying = true
            defer { isApplying = false }
            do {
                let client = try SyncClipboardClient(server: server, trustInsecureCert: appSettings.trustInsecureCert)
                let bytes = try await Self.fetchLiveLatest(client: client, entry: entry, dataName: dataName)
                try Self.verify(bytes: bytes, against: entry)
                let text = String(decoding: bytes, as: UTF8.self)
                pasteboard.write(text: text)
                applyError = nil
                return true
            } catch let e as SyncError {
                log.error("applyServerToDevice: \(String(describing: e.kind), privacy: .public): \(e.underlying ?? "", privacy: .private)")
                applyError = e
                throw e
            } catch {
                log.error("applyServerToDevice: unexpected: \(String(describing: error), privacy: .public)")
                let wrapped = SyncError(kind: .networkUnreachable, underlying: "\(error)")
                applyError = wrapped
                throw wrapped
            }
        case .image:
            guard entry.hasData,
                  let dataName = entry.dataName,
                  let server = activeServer
            else { return false }
            guard !isApplying else { return false }
            isApplying = true
            defer { isApplying = false }
            do {
                let client = try SyncClipboardClient(server: server, trustInsecureCert: appSettings.trustInsecureCert)
                let bytes = try await Self.fetchLiveLatest(client: client, entry: entry, dataName: dataName)
                try Self.verify(bytes: bytes, against: entry)
                pasteboard.write(data: bytes, uti: Self.utiForDataName(dataName), originalName: dataName)
                applyError = nil
                return true
            } catch let e as SyncError {
                log.error("applyServerToDevice: \(String(describing: e.kind), privacy: .public): \(e.underlying ?? "", privacy: .private)")
                applyError = e
                throw e
            } catch {
                log.error("applyServerToDevice: unexpected: \(String(describing: error), privacy: .public)")
                let wrapped = SyncError(kind: .networkUnreachable, underlying: "\(error)")
                applyError = wrapped
                throw wrapped
            }
        case .file, .group:
            return false
        }
    }

    /// Download a history row's image payload via §2.11 and write the
    /// bytes onto the device pasteboard. Text rows use `reapplyText`
    /// (no network round-trip), file rows are not supported — UIPasteboard
    /// has no meaningful UTI for an arbitrary binary, and pasting a
    /// "file" into another app is what the Files app's share sheet is
    /// for. Group entries (§4.3) likewise out of scope.
    ///
    /// On success, `lastAppliedAttachmentName` is set so the home view
    /// can surface "已复制 <name> 到剪贴板" — without that the user has
    /// no visible feedback that the bytes landed.
    func applyAttachment(for item: ClipboardHistoryItem) async {
        guard !isApplying else { return }
        let entry = item.entry
        guard entry.hasData,
              entry.type == .image,
              let dataName = entry.dataName,
              let hash = entry.hash, !hash.isEmpty,
              let server = activeServer
        else { return }
        let profileId = HistoryRecord.profileId(type: entry.type, hash: hash)

        isApplying = true
        defer { isApplying = false }
        // Same transient-feedback discipline as save: clear the prior
        // banner before the new attempt so the user doesn't briefly see
        // a stale "已保存 …" while the apply round-trip is in flight.
        lastSavedFileURL = nil
        lastAppliedAttachmentName = nil
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: appSettings.trustInsecureCert)
            let bytes = try await Self.fetchHistory(client: client, profileId: profileId)
            try Self.verify(bytes: bytes, against: entry)
            pasteboard.write(data: bytes, uti: Self.utiForDataName(dataName), originalName: dataName)
            lastAppliedAttachmentName = dataName
            applyError = nil
        } catch let e as SyncError {
            log.error("applyAttachment: \(String(describing: e.kind), privacy: .public): \(e.underlying ?? "", privacy: .private)")
            applyError = e
        } catch {
            log.error("applyAttachment: unexpected: \(String(describing: error), privacy: .public)")
            applyError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    /// Fetch a history row's payload bytes via §2.11 for read-only preview
    /// rendering. Does not touch the clipboard, the filesystem, or any
    /// view-model banner state — the preview sheet owns its own loading /
    /// error UI. Used by `ClipboardPreviewSheet` to render full-resolution
    /// images and long-text overflow bodies on tap.
    ///
    /// Verifies the bytes against `entry.hash` per §4.4 so a corrupted
    /// download surfaces as `.hashMismatch` instead of a broken image or
    /// mojibake'd text. Live-latest (no hash, no `dataName`) falls through
    /// to §2.4 `GET /file/<dataName>` for the long-text inline path.
    func fetchPreviewBytes(for item: ClipboardHistoryItem) async throws -> Data {
        let entry = item.entry
        guard entry.hasData, let dataName = entry.dataName else {
            throw SyncError(kind: .notFound, underlying: "entry has no payload")
        }
        // Local cache first — works offline.
        if let hash = entry.hash, !hash.isEmpty,
           let cached = store.loadImageData(hash: hash) {
            return cached
        }
        guard let server = activeServer else {
            throw SyncError(kind: .invalidURL, underlying: "no active server")
        }
        let client = try SyncClipboardClient(server: server, trustInsecureCert: appSettings.trustInsecureCert)
        let bytes: Data
        if let hash = entry.hash, !hash.isEmpty {
            let profileId = HistoryRecord.profileId(type: entry.type, hash: hash)
            bytes = try await Self.fetchHistory(client: client, profileId: profileId)
        } else {
            bytes = try await client.getFile(name: dataName)
        }
        try Self.verify(bytes: bytes, against: entry)
        if let hash = entry.hash, !hash.isEmpty {
            store.saveImageData(hash: hash, data: bytes)
        }
        return bytes
    }

    /// Download a history row's payload bytes (§2.11) and write them to
    /// `Documents/<sanitized downloadRelativePath>/<dataName>`.
    ///
    /// Works for any image/file entry in `history`, not just the live
    /// latest — that's the whole point of §2.11. The hash → composite
    /// `profileId` form addresses the record regardless of whether the
    /// live `SyncClipboard.json` still points at it.
    ///
    /// Concurrency: shares the `isSaving` / `saveError` / `lastSavedFileURL`
    /// state with `saveServerAttachment` so the UI banner machinery
    /// doesn't need to know which path was taken. The first call wins;
    /// subsequent calls while a save is in flight return silently.
    func saveAttachment(for item: ClipboardHistoryItem) async {
        guard !isSaving else { return }
        let entry = item.entry
        guard entry.hasData,
              entry.type == .image || entry.type == .file,
              let dataName = entry.dataName,
              let server = activeServer
        else { return }
        // §2.11 addresses by `<type>-<hash>`. Without a hash there's no
        // record to fetch; the live-latest path (`saveServerAttachment`)
        // is the fallback for legacy publishers that omit hashes.
        guard let hash = entry.hash, !hash.isEmpty else { return }
        let profileId = HistoryRecord.profileId(type: entry.type, hash: hash)

        isSaving = true
        defer { isSaving = false }
        lastSavedFileURL = nil
        lastAppliedAttachmentName = nil
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: appSettings.trustInsecureCert)
            let bytes = try await Self.fetchHistory(client: client, profileId: profileId)
            try Self.verify(bytes: bytes, against: entry)
            let url = try Self.targetURL(for: dataName, relative: appSettings.downloadRelativePath)
            try bytes.write(to: url, options: .atomic)
            lastSavedFileURL = url
            saveError = nil
        } catch let e as SyncError {
            log.error("saveAttachment: \(String(describing: e.kind), privacy: .public): \(e.underlying ?? "", privacy: .private)")
            saveError = e
        } catch {
            log.error("saveAttachment: unexpected: \(String(describing: error), privacy: .public)")
            saveError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    /// Download the live-latest server entry's payload via §2.4 and
    /// write it to `Documents/<sanitized downloadRelativePath>/<dataName>`.
    /// Group entries are out of scope (§4.3 ZIP-traversal hash is its
    /// own slice). Overwrites on collision — matches Files-app behavior.
    func saveServerAttachment() async {
        guard !isSaving else { return }
        guard let entry = serverLatest,
              entry.hasData,
              entry.type == .image || entry.type == .file,
              let dataName = entry.dataName,
              let server = activeServer
        else { return }
        isSaving = true
        defer { isSaving = false }
        lastSavedFileURL = nil
        lastAppliedAttachmentName = nil
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: appSettings.trustInsecureCert)
            let bytes = try await Self.fetchLiveLatest(client: client, entry: entry, dataName: dataName)
            try Self.verify(bytes: bytes, against: entry)
            let url = try Self.targetURL(for: dataName, relative: appSettings.downloadRelativePath)
            try bytes.write(to: url, options: .atomic)
            lastSavedFileURL = url
            saveError = nil
        } catch let e as SyncError {
            log.error("saveAttachment: \(String(describing: e.kind), privacy: .public): \(e.underlying ?? "", privacy: .private)")
            saveError = e
        } catch {
            log.error("saveAttachment: unexpected: \(String(describing: error), privacy: .public)")
            saveError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    /// Reconcile the in-memory `history` with the on-disk log on foreground.
    /// Extensions (keyboard / share) append `.pushed` rows directly to the
    /// App Group store while this app is suspended; without this merge the
    /// app's next `history` mutation (e.g. a SyncEngine append) would persist
    /// its stale in-memory copy and clobber those rows. We union by `id`
    /// (disk wins on conflicts), re-sort newest-first, and cap — so nothing
    /// the user did in the keyboard is lost, and nothing they deleted here
    /// resurrects (a delete persisted to disk, so it's absent from both
    /// sides). Idempotent and cheap; safe to call on every `.active`.
    func reconcileSharedHistory() {
        let disk = store.loadHistory()
        var byId: [UUID: ClipboardHistoryItem] = [:]
        for item in history { byId[item.id] = item }
        for item in disk { byId[item.id] = item }   // disk wins on conflicts
        let merged = byId.values.sorted { $0.timestamp > $1.timestamp }
        let capped = merged.count > Self.maxHistoryCount ? Array(merged.prefix(Self.maxHistoryCount)) : Array(merged)
        // Only assign (triggering the persisting didSet) if something actually
        // changed, so a no-op foreground doesn't rewrite the blob.
        if capped != history {
            history = capped
        }
    }

    /// Trim `history` to `maxHistoryCount` and fire a best-effort cache
    /// delete for every evicted entry's `profileId`. Used by both
    /// `appendHistory` and `mergeHistoryRecord` after their respective
    /// inserts. Done in one shot (single didSet → single JSON encode)
    /// rather than per-overflow `removeLast`s — matters when SyncEngine
    /// catches up from a long background and floods the log.
    private func trimHistoryAndPruneCache() {
        guard history.count > Self.maxHistoryCount else { return }
        let evicted = history.dropFirst(Self.maxHistoryCount)
        let profileIds = evicted.compactMap { Self.profileIdIfAny($0.entry) }
        history = Array(history.prefix(Self.maxHistoryCount))
        Self.scheduleCacheDelete(profileIds)
    }

    /// Derive the `PayloadCache` key for an entry, or nil if no stable
    /// key exists (hash missing). Defensive `.uppercased()` so this
    /// matches the write-side key even if some upstream skipped
    /// `Clipboard`'s decode normalization.
    private static func profileIdIfAny(_ entry: Clipboard) -> String? {
        guard let hash = entry.hash, !hash.isEmpty else { return nil }
        return HistoryRecord.profileId(type: entry.type, hash: hash.uppercased())
    }

    /// Fire-and-forget delete of a batch of cache files. Spawned from a
    /// MainActor caller — the unstructured Task lets the history setter
    /// return immediately so the persisting `didSet` JSON encode isn't
    /// blocked by disk I/O. Errors are swallowed (cache delete is
    /// best-effort by design — leftover bytes just age out under LRU).
    private static func scheduleCacheDelete(_ profileIds: [String]) {
        guard !profileIds.isEmpty else { return }
        Task.detached {
            for id in profileIds {
                await PayloadCache.shared.delete(profileId: id)
            }
        }
    }

    /// Capture the device pasteboard's payload bytes into the local caches
    /// the moment a new locally-copied image is observed. The observer's
    /// `read()` deliberately drops payload bytes (its `current` is
    /// long-lived observable state), so this re-snapshots once per new
    /// image. Cheap: fires only on the tick that first sees a new hash,
    /// and re-reading content this process was already granted never
    /// re-prompts. The hash check guards the race where the pasteboard
    /// changed between the observer's read and this snapshot.
    ///
    /// This is what makes a local screenshot render its card cover
    /// instantly — the thumbnail loader must never need the network (or
    /// the upload to have happened) for content this device produced.
    func seedLocalPayloadCache(for entry: Clipboard) {
        guard entry.type == .image, entry.hasData,
              let hash = entry.hash, !hash.isEmpty,
              store.loadImageData(hash: hash) == nil,
              let snapshot = pasteboard.snapshot(),
              snapshot.clipboard.hash?.uppercased() == hash.uppercased()
        else { return }
        seedLocalPayloadCache(from: snapshot)
    }

    /// Snapshot-based variant for callers that already hold the bytes
    /// (consent push, where the system paste control handed them over).
    func seedLocalPayloadCache(from snapshot: DeviceClipboardSnapshot) {
        let entry = snapshot.clipboard
        guard entry.type == .image,
              let hash = entry.hash, !hash.isEmpty,
              let payload = snapshot.payload
        else { return }
        store.saveImageData(hash: hash, data: payload)
        let profileId = HistoryRecord.profileId(type: entry.type, hash: hash)
        Task { try? await PayloadCache.shared.write(profileId: profileId, bytes: payload) }
    }

    /// Fire-and-forget cache prefetch for an incoming server entry.
    /// No-op when prefetch is disabled, the path is cellular and the
    /// user hasn't opted in, or the entry isn't a hash-tracked
    /// attachment (image/text-long with a populated hash + dataName).
    ///
    /// Races safely with the device-apply read-through: `PayloadCache`'s
    /// per-`profileId` `pending` table dedups, so at most one network
    /// request goes out regardless of who wins the race.
    func prefetchAttachmentIfEligible(_ entry: Clipboard) {
        guard appSettings.prefetchAttachments else { return }
        if ssidProvider.isCellular, !appSettings.prefetchOnCellular { return }
        guard entry.hasData,
              entry.type == .image || entry.type == .text,
              let hash = entry.hash, !hash.isEmpty,
              let dataName = entry.dataName,
              let server = activeServer
        else { return }
        let trust = appSettings.trustInsecureCert
        let profileId = HistoryRecord.profileId(type: entry.type, hash: hash)
        Task.detached {
            // Building the client is cheap (no I/O) — doing it inside
            // the detached task keeps the MainActor caller off the
            // URLSession code path.
            guard let client = try? SyncClipboardClient(server: server, trustInsecureCert: trust) else { return }
            _ = try? await PayloadCache.shared.fetchAndStore(profileId: profileId) {
                try await client.getFile(name: dataName)
            }
        }
    }

    /// Read-through cache for the §2.4 live-latest route
    /// (`GET /file/<dataName>`). Goes through `PayloadCache.shared` when
    /// `entry.hash` is present, bypasses for the rare hash-less legacy
    /// path (no stable cache key exists to dedup against). Bytes are NOT
    /// re-verified here — verification happens at the call site after
    /// this returns, the same way the pre-cache code did.
    private static func fetchLiveLatest(
        client: SyncClipboardClient,
        entry: Clipboard,
        dataName: String
    ) async throws -> Data {
        if let hash = entry.hash, !hash.isEmpty {
            let profileId = HistoryRecord.profileId(type: entry.type, hash: hash)
            return try await PayloadCache.shared.fetchAndStore(profileId: profileId) {
                try await client.getFile(name: dataName)
            }
        }
        return try await client.getFile(name: dataName)
    }

    /// Read-through cache for the §2.11 history route
    /// (`GET /file/history/<profileId>`). The `profileId` already
    /// encodes the type + hash, so it doubles as the cache key.
    private static func fetchHistory(
        client: SyncClipboardClient,
        profileId: String
    ) async throws -> Data {
        try await PayloadCache.shared.fetchAndStore(profileId: profileId) {
            try await client.getHistoryPayload(profileId: profileId)
        }
    }

    /// §4.4 verify: SHA-256 over raw bytes for all types. Group is
    /// unimplemented and the caller gates it out before reaching here.
    /// Null/whitespace `entry.hash` short-circuits to a pass via
    /// `hashMatches` semantics.
    private static func verify(bytes: Data, against entry: Clipboard) throws {
        if entry.type == .group { return }
        let actual = Clipboard.computeBytesHash(bytes)
        guard Clipboard.hashMatches(expected: entry.hash, actual: actual) else {
            let expected = entry.hash ?? "<nil>"
            let name = entry.dataName ?? "<nil>"
            // §4.4 failure = corrupted transfer or a server-side bug —
            // content-free attributes only (no name/hash) toward Sentry.
            log.error("verify: hash mismatch type=\(entry.type.rawValue, privacy: .public) bytes=\(bytes.count, privacy: .public)")
            SentrySDK.logger.error(
                "payload hash verification failed",
                attributes: ["type": entry.type.rawValue, "bytes": bytes.count]
            )
            throw SyncError(
                kind: .hashMismatch,
                underlying: "expected=\(expected) actual=\(actual) name=\(name) bytes=\(bytes.count)"
            )
        }
    }

    /// Map a payload filename to the UTI used when writing the bytes back
    /// to UIPasteboard during apply-image. Mirror of the read-side UTI
    /// table on `DevicePasteboardObserver`.
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

    private static func targetURL(for dataName: String, relative: String) throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        // Sanitize against container escape and weird input. Drops `..`,
        // `.`, and empty segments; strips leading/trailing slashes by virtue
        // of the split. Trailing-slash and leading-slash users still get
        // their intended subdir.
        let sanitized = relative
            .split(separator: "/")
            .filter { $0 != "." && $0 != ".." && !$0.isEmpty }
            .map(String.init)
        var dir = docs
        for segment in sanitized {
            dir.appendPathComponent(segment, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(dataName, isDirectory: false)
    }
}

extension AppViewModel {
    /// Publish the device clipboard to the active server. Spec §2.2 +
    /// §2.3 + §3.4 + §3.5. Text and image; file/group are no-ops (file
    /// from UIPasteboard isn't meaningful on iOS, group needs §4.3).
    /// - Returns silently if no active server, no device clipboard, or
    ///   already pushing.
    /// - Reads the pasteboard fresh via `snapshot()` rather than the
    ///   cached `current`, so a copy-then-push race produces the
    ///   semantically-current clipboard not a stale one.
    /// - Payload-bearing entries go file-first per §3.5; failures in the
    ///   file PUT skip the metadata PUT so the server never sees a
    ///   metadata pointer to a missing file.
    /// - On success, optimistically updates `serverLatest` to the
    ///   metadata-only entry so the server card reflects reality without
    ///   a follow-up GET.
    func push() async {
        _ = try? await pushReturningEntry()
    }

    /// Throwing variant of `push()` used by `SyncEngine` so it doesn't
    /// have to second-guess the sticky `pushError` field. Returns the
    /// pushed entry on success, `nil` when there's nothing to push
    /// (no server, no snapshot, or unsupported type — all silent skips),
    /// and throws `SyncError` on a real failure. Updates the same
    /// observable surface (`pushError`, `lastPushedAt`, `serverLatest`)
    /// as `push()` so UI bindings stay live regardless of which entry
    /// point ran.
    @discardableResult
    func pushReturningEntry() async throws -> Clipboard? {
        // Guard server + in-flight BEFORE snapshotting — `pasteboard.snapshot()`
        // reads content and can fire the "Allow Paste" prompt, so we don't
        // want it firing when there's nothing to push to.
        guard !isPushing, activeServer != nil else { return nil }
        guard let snapshot = pasteboard.snapshot(),
              snapshot.clipboard.type == .text || snapshot.clipboard.type == .image
        else { return nil }
        return try await pushSnapshot(snapshot)
    }

    /// Push an already-materialized `DeviceClipboardSnapshot` — the network
    /// half of `pushReturningEntry()`, split out so the consent-push path
    /// (Home `PasteButton`) can push the bytes it got from the system paste
    /// control WITHOUT re-reading `UIPasteboard` (which would re-trigger the
    /// prompt the whole feature exists to avoid). Same observable surface
    /// (`pushError`/`lastPushedAt`/`serverLatest`) and silent-skip / throw
    /// contract as the snapshot-reading variant.
    @discardableResult
    func pushSnapshot(_ snapshot: DeviceClipboardSnapshot) async throws -> Clipboard? {
        guard !isPushing else { return nil }
        guard let server = activeServer else { return nil }
        guard snapshot.clipboard.type == .text || snapshot.clipboard.type == .image
        else { return nil }
        isPushing = true
        defer { isPushing = false }
        let trustInsecure = appSettings.trustInsecureCert
        let entry = snapshot.clipboard
        // Seed the local caches from the in-hand bytes BEFORE the network
        // round-trip: the history card for this entry already exists (the
        // tick's local-append / consentPush ran first), and its thumbnail
        // loader must not have to race the PUT — let alone re-download from
        // the server what this device just produced.
        if let payload = snapshot.payload, let hash = entry.hash, !hash.isEmpty {
            if entry.type == .image {
                store.saveImageData(hash: hash, data: payload)
            }
            let profileId = HistoryRecord.profileId(type: entry.type, hash: hash)
            try? await PayloadCache.shared.write(profileId: profileId, bytes: payload)
        }
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: trustInsecure)
            if let payload = snapshot.payload, let dataName = entry.dataName {
                try await client.putFile(name: dataName, body: payload)
            }
            try await client.putClipboard(entry)
            serverLatest = entry
            lastSyncedAt = .now
            lastPushedAt = .now
            pushError = nil
            refreshError = nil
            return entry
        } catch let e as SyncError {
            log.error("pushSnapshot: \(String(describing: e.kind), privacy: .public) type=\(entry.type.rawValue, privacy: .public): \(e.underlying ?? "", privacy: .private)")
            pushError = e
            throw e
        } catch {
            log.error("pushSnapshot: unexpected type=\(entry.type.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            let wrapped = SyncError(kind: .networkUnreachable, underlying: "\(error)")
            pushError = wrapped
            throw wrapped
        }
    }

    /// Pull the active server's latest clipboard. Spec §2.1.
    /// - 404 is the documented empty state — clears `serverLatest`,
    ///   updates `lastSyncedAt`, leaves `refreshError` nil.
    /// - Other errors keep the previous `serverLatest` (stale > blank)
    ///   and surface via `refreshError`.
    /// - No active config → spec §5.2 forbids the call; returns silently.
    func refresh() async {
        guard let server = activeServer else { return }
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // The transient feedback banners ("已保存到 …" / "已复制 … 到剪贴板")
        // are bound to the last user action, not the server-side state.
        // A refresh changes what's on screen, so they no longer match
        // what the user just saw — clear both.
        lastSavedFileURL = nil
        lastAppliedAttachmentName = nil
        let trustInsecure = appSettings.trustInsecureCert
        do {
            let client = try SyncClipboardClient(server: server, trustInsecureCert: trustInsecure)
            let clip = try await client.getClipboard()
            serverLatest = clip
            lastSyncedAt = .now
            refreshError = nil
        } catch let e as SyncError where e.kind == .notFound {
            serverLatest = nil
            lastSyncedAt = .now
            refreshError = nil
        } catch let e as SyncError {
            log.error("refresh: \(String(describing: e.kind), privacy: .public): \(e.underlying ?? "", privacy: .private)")
            refreshError = e
        } catch {
            log.error("refresh: unexpected: \(String(describing: error), privacy: .public)")
            refreshError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    /// Run a Home Screen quick-action. The router lives here (not on the
    /// `ShortcutInbox` or the delegate) because every branch needs the
    /// view-model's network/state machinery — `push()`, `refresh()`, and
    /// `applyServerToDevice()` already enforce their own in-flight guards
    /// and error surfaces, so the shortcut path inherits those for free.
    ///
    /// No active server → no-op. The root view is already showing the
    /// SetupFlow because `configs.isEmpty`, so cold-launching via a tile
    /// already lands the user in the configuration flow; we just discard
    /// the action rather than letting it replay after setup completes
    /// and surprise the user with an unexpected push/pull.
    ///
    /// The pull branch gates `applyServerToDevice()` on a successful
    /// `refresh()`: on failure `refreshError` is set and `serverLatest`
    /// keeps its prior value (stale > blank), and we don't want a
    /// shortcut tap to silently paste content from a prior session.
    func runShortcut(_ action: ShortcutAction) async {
        guard !servers.configs.isEmpty else { return }
        switch action {
        case .push:
            await push()
        case .pull:
            await refresh()
            if refreshError == nil, serverLatest != nil {
                await applyServerToDevice()
            }
        }
    }

    /// Builds a VM bound to an isolated `UserDefaults` suite — for use in
    /// `#Preview` blocks so previews don't read or write `.standard`.
    /// `deviceText: nil` keeps the device pasteboard empty in the preview;
    /// pass a string to seed `vm.deviceClipboard` without touching the
    /// real `UIPasteboard.general`.
    static func preview(
        servers: ServerConfigList? = nil,
        appSettings: AppSettings? = nil,
        deviceText: String? = nil
    ) -> AppViewModel {
        // MainActor-isolated defaults (Mock.servers, AppSettings.init) must be
        // resolved in the body — default-argument expressions are nonisolated.
        let servers = servers ?? Mock.servers
        let appSettings = appSettings ?? AppSettings(
            manualUploadDialogShown: true,
            downloadRelativePath: "SyncClipboard/Inbox",
            ignoredVersion: "0.3.2"
        )
        let suite = UserDefaults(suiteName: "AppViewModel.preview-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: suite)
        store.saveServers(servers)
        store.saveAppSettings(appSettings)
        let pasteboardEnv: [String: String] = ["UC_DEVICE_TEXT": deviceText ?? ""]
        let pasteboard = DevicePasteboardObserver(environment: pasteboardEnv)
        let vm = AppViewModel(store: store, forceFreshServers: false, pasteboard: pasteboard)
        // Previews want representative content — `history` defaults to
        // empty (SyncEngine fills it at runtime), so seed mock entries
        // here so design previews don't all look like empty states.
        vm.history = Mock.history
        return vm
    }
}
