import Foundation
import Observation

/// Drives the auto-sync state machine. Cycle 9 product surface — replaces
/// the manual "推送" / "应用到本机" buttons with a 1Hz foreground tick that
/// converges both sides automatically.
///
/// State machine per `tick()`:
///
/// 1. `GET /SyncClipboard.json` (§2.1) for server metadata.
/// 2. If `server.hash != lastSyncedContentHash`, the server has new content:
///    - If we already fetched bytes for this hash and are waiting for the
///      user to flip the auto-apply toggle (`stagedServerHash == server.hash`),
///      no-op. Otherwise download, verify, and stage `vm.serverLatest`.
///    - If `appSettings.autoApplyServerChanges` is on, write to
///      `UIPasteboard.general` via `pasteboard.write`, advance
///      `lastSyncedContentHash` to the server hash, drop the staged hash.
///    - If off, set `state = .hasNewUnwritten`, keep the staged hash so
///      subsequent ticks don't re-download.
/// 3. Otherwise (server unchanged), check `vm.deviceClipboard.hash` against
///    `lastSyncedContentHash`. The observer is the source of truth — it
///    auto-reads on `UIPasteboard.changedNotification` and
///    `didBecomeActiveNotification`, so by the time the engine ticks, the
///    cached `current` reflects whatever the user just copied. If hashes
///    differ, the engine pushes via `vm.push()` (which itself does a
///    fresh `pasteboard.snapshot()` for bytes).
/// 4. On success, advance `lastSyncedContentHash` to the new content hash.
///
/// Conflict resolution is server-wins. When both sides changed inside the
/// same tick the server is processed first; on the next tick the device
/// pasteboard now matches the server (we just wrote it) and the hash dedup
/// short-circuits push, so we don't echo the server's content back to it.
///
/// Errors:
/// - `.authFailed` (401) → `state = .authFailed`, the loop pauses entirely.
///   Resume by calling `start()` again after the user fixes credentials.
/// - `.networkUnreachable` / `.timeout` / others → `state = .offlineRetrying`
///   and the next tick fires after `offlineBackoffSeconds` instead of the
///   normal cadence.
/// - `.notFound` (404) on server GET is the documented "empty server"
///   state and is treated as success — fall through to the push side.
@MainActor
@Observable
final class SyncEngine {
    enum State: Equatable {
        case idle
        case succeeded
        case hasNewUnwritten
        case offlineRetrying
        case authFailed
    }

    private(set) var state: State = .idle
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: SyncError?

    /// Server entry that was fetched but not written to UIPasteboard
    /// because `appSettings.autoApplyServerChanges == false`. UI can show
    /// it highlighted/expanded. `nil` when nothing is staged.
    private(set) var stagedEntry: Clipboard?

    /// True while a user-explicit tick (pull-to-refresh, toolbar refresh
    /// button) is in flight. Routine 1Hz ticks DO NOT flip this — the
    /// connector and toolbar reflect the last stable result state so users
    /// see "已同步" most of the time instead of a flickering "同步中…"
    /// every second.
    private(set) var isExplicitlyRefreshing: Bool = false

    @ObservationIgnored
    private weak var viewModel: AppViewModel?

    @ObservationIgnored
    private let store: SettingsStore

    @ObservationIgnored
    private var lastSyncedContentHash: String?

    /// Hash we already downloaded but didn't write. Used to dedup the bytes
    /// fetch when auto-apply is off and the server hash hasn't changed.
    @ObservationIgnored
    private var stagedServerHash: String?

    @ObservationIgnored
    private var loopTask: Task<Void, Never>?

    @ObservationIgnored
    private var isTicking: Bool = false

    /// Normal foreground cadence. Public for tests / debug overrides; not a
    /// user setting.
    @ObservationIgnored
    var normalCadenceSeconds: Double = 1.0

    /// Backoff applied when a tick errors out for network reasons.
    @ObservationIgnored
    var offlineBackoffSeconds: Double = 5.0

    init(viewModel: AppViewModel, store: SettingsStore) {
        self.viewModel = viewModel
        self.store = store
        self.lastSyncedContentHash = store.loadLastSyncedHash()
    }

    /// Begin the polling loop. Idempotent — calling while already running
    /// is a no-op. Call from `scenePhase == .active`. Resets `.authFailed`
    /// on the assumption that the caller is retrying after a credential fix.
    func start() {
        guard loopTask == nil else { return }
        if state == .authFailed { state = .idle }
        loopTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                let interval = self.cadenceSeconds()
                if interval.isInfinite { break }
                let nanos = UInt64(max(0.05, interval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    /// Cancel the polling loop. Call from `scenePhase == .background` and
    /// before tearing down the engine.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Run a tick now, ignoring the normal cadence and any offline backoff.
    /// Marked as an explicit refresh — UI shows a spinner until it
    /// completes. Used by the toolbar refresh button.
    func forceTickNow() {
        Task { @MainActor in await self.tick(explicit: true) }
    }

    /// Awaitable explicit tick — use from `.refreshable` so the SwiftUI
    /// pull-to-refresh control keeps its native spinner up until the
    /// tick actually finishes (rather than flashing for a frame).
    func explicitRefresh() async {
        await tick(explicit: true)
    }

    /// Clear runtime state without touching persisted hash. Useful when the
    /// user switches active server — the new server has its own content
    /// timeline.
    func resetRuntimeState() {
        stagedServerHash = nil
        stagedEntry = nil
        lastError = nil
        state = .idle
    }

    /// Called by `AppViewModel.servers.didSet`. Decides whether to clear
    /// per-server state and / or restart a paused (.authFailed) loop.
    /// Compares effective (SSID-resolved) configs because an SSID-list
    /// edit on a non-active server can flip the effective active without
    /// touching `activeConfigId`.
    func handleServersChange(from old: ServerConfigList, to new: ServerConfigList) {
        let ssid = viewModel?.ssidProvider.currentSSID
        let oldEffectiveId = old.resolveActiveConfig(currentSsid: ssid)?.id
        let newEffectiveId = new.resolveActiveConfig(currentSsid: ssid)?.id
        if oldEffectiveId != newEffectiveId {
            // Different server entirely — content timeline differs, drop hash.
            resetRuntimeState()
            lastSyncedContentHash = nil
            store.saveLastSyncedHash(nil)
        }
        if state == .authFailed {
            // The user almost certainly just edited credentials. Restart and
            // see whether the new ones work; if not we'll land back in
            // .authFailed within one tick.
            start()
        }
    }

    /// Called when the effective active server changed due to a Wi-Fi
    /// flip (not a config edit). Drops per-server runtime state and
    /// forces an immediate tick so the new server's clipboard surfaces
    /// without waiting for the 1Hz cadence.
    func handleEffectiveActiveChange() {
        // §5.3: switching servers is a content-timeline change. Drop the
        // staged + last-synced hashes so the new server's first entry
        // isn't mistaken for a duplicate.
        resetRuntimeState()
        lastSyncedContentHash = nil
        store.saveLastSyncedHash(nil)
        if state == .authFailed {
            start()
        } else {
            forceTickNow()
        }
    }

    private func cadenceSeconds() -> Double {
        switch state {
        case .authFailed:       return .infinity
        case .offlineRetrying:  return offlineBackoffSeconds
        default:                return normalCadenceSeconds
        }
    }

    private func tick(explicit: Bool = false) async {
        guard !isTicking else { return }
        isTicking = true
        if explicit { isExplicitlyRefreshing = true }
        defer {
            isTicking = false
            if explicit { isExplicitlyRefreshing = false }
        }
        guard let vm = viewModel,
              let server = vm.effectiveActiveConfig else {
            state = .idle
            return
        }
        if state == .authFailed { return }
        // Note: routine 1Hz ticks don't transition to a "syncing"
        // intermediate state — the visible `state` stays at its last
        // stable value, so the connector strip doesn't flicker every
        // second between "同步中…" and "已同步". Explicit refreshes
        // surface their progress via `isExplicitlyRefreshing` instead.
        do {
            let client = try SyncClipboardClient(
                server: server,
                trustInsecureCert: vm.appSettings.trustInsecureCert
            )
            // Pull side first (server-wins).
            let serverEntryOrNil: Clipboard?
            do {
                serverEntryOrNil = try await client.getClipboard()
            } catch let e as SyncError where e.kind == .notFound {
                // Empty server — leave serverLatest as-is, fall through.
                serverEntryOrNil = nil
            }
            if let serverEntry = serverEntryOrNil,
               !hashesEqual(serverEntry.hash, lastSyncedContentHash) {
                try await processServerNew(serverEntry, client: client, vm: vm)
                return
            }
            // Push side.
            try await maybePush(client: client, vm: vm, server: server)
        } catch let e as SyncError where e.kind == .authFailed {
            state = .authFailed
            lastError = e
            stop()
        } catch let e as SyncError {
            state = .offlineRetrying
            lastError = e
        } catch {
            state = .offlineRetrying
            lastError = SyncError(kind: .networkUnreachable, underlying: "\(error)")
        }
    }

    private func processServerNew(
        _ entry: Clipboard,
        client: SyncClipboardClient,
        vm: AppViewModel
    ) async throws {
        // Dedup: if we already fetched this hash and the user just hasn't
        // flipped auto-apply yet, skip the bytes round-trip.
        let alreadyStaged = stagedServerHash.map { hashesEqual($0, entry.hash) } ?? false
        if !alreadyStaged {
            vm.serverLatest = entry
        }
        if vm.appSettings.autoApplyServerChanges {
            // Reuse vm.applyServerToDevice — it handles text-short / text-long /
            // image branches and pasteboard.write. It reads vm.serverLatest, so
            // make sure the latest is set above.
            await vm.applyServerToDevice()
            if let err = vm.applyError {
                throw err
            }
            advanceSynced(to: entry.hash)
            stagedServerHash = nil
            stagedEntry = nil
            state = .succeeded
            lastSyncedAt = .now
            lastError = nil
        } else {
            // Stage but don't write. Update stagedServerHash to dedup next
            // tick. lastSyncedContentHash stays where it was — until the
            // user toggles auto-apply on or copies something new locally,
            // we're "stuck" on hasNewUnwritten by design.
            stagedServerHash = entry.hash
            stagedEntry = entry
            state = .hasNewUnwritten
            lastSyncedAt = .now
            lastError = nil
        }
    }

    private func maybePush(
        client: SyncClipboardClient,
        vm: AppViewModel,
        server: ServerConfig
    ) async throws {
        guard let device = vm.deviceClipboard else {
            // Observer hasn't surfaced anything yet (cold start, env-hook
            // returned nil, etc). Nothing to push.
            state = .succeeded
            lastSyncedAt = .now
            lastError = nil
            return
        }
        if hashesEqual(device.hash, lastSyncedContentHash) {
            // Already synced.
            state = .succeeded
            lastSyncedAt = .now
            lastError = nil
            return
        }
        await vm.push()
        if let err = vm.pushError {
            throw err
        }
        if let pushed = vm.serverLatest {
            advanceSynced(to: pushed.hash)
            // Mirror the Share Extension's donation so iOS Sharing
            // Suggestions ranks this server higher even when the user
            // never explicitly invokes the share sheet — auto-sync
            // counts as "sent to this server" too. Fire-and-forget so
            // the next tick isn't blocked on IPC.
            Task { await ShareIntentDonation.donateSend(to: server, clipboard: pushed) }
        }
        // No serverLatest after push = silent skip (no active config / no
        // pushable snapshot / type unsupported). Don't advance hash, but
        // succeeded state lets the loop continue.
        state = .succeeded
        lastSyncedAt = .now
        lastError = nil
    }

    private func advanceSynced(to hash: String?) {
        // A nil/empty hash means the entry is unverifiable (hashMatches treats
        // it as a pass per §4.4). We can still mark it "synced for the moment"
        // but can't dedup future ticks — leave lastSyncedContentHash alone so
        // the next tick re-evaluates. Rare in practice (well-formed servers
        // always emit hash).
        guard let hash, !hash.isEmpty else { return }
        let normalized = hash.uppercased()
        lastSyncedContentHash = normalized
        store.saveLastSyncedHash(normalized)
    }

    private func hashesEqual(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let l?, let r?): return l.uppercased() == r.uppercased()
        default: return false
        }
    }
}
