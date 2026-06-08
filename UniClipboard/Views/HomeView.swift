import SwiftUI
import UIKit

/// Home tab — recent clipboard entries grouped by date.
///
/// Earlier cycles showed a single focal card for the active clipboard.
/// Cycle 11 expands that to a Messages-style time-descending list so the
/// "what's on the server" view stops feeling lossy. The spec only keeps
/// one entry on the wire (§2.1), so the list is fed by `vm.history` —
/// today seeded from [`Mock.history`], future-wise to be appended by the
/// `SyncEngine` on each successful pull/push and (optionally) hydrated
/// from §2.7 `POST /api/history/query` on UniClipboard servers.
struct HomeView: View {
    @Bindable var vm: AppViewModel

    /// Injected by `ContentView` so the error-detail sheet's "去设置" CTA
    /// can flip the TabView selection without HomeView knowing about it.
    var onGoToSettings: () -> Void = {}

    @State private var showingErrorSheet: Bool =
        ProcessInfo.processInfo.environment["UC_OPEN_ISSUE_SHEET"] == "1"

    /// History row selected for the preview sheet. Item-driven sheet (not
    /// a boolean) so the sheet's content is bound to the chosen row even
    /// if the user taps a different row before the prior sheet finishes
    /// dismissing.
    @State private var previewItem: ClipboardHistoryItem?

    private var engineState: SyncEngine.State { vm.engine.state }

    /// Show the paste-permission hint while fully-automatic push is on (the
    /// engine reads the pasteboard each tick → iOS「允许粘贴」friction) and the
    /// user hasn't dismissed it. Setting「从其他 App 粘贴」to「允许」silences it.
    private var showPasteHint: Bool {
        vm.appSettings.autoPushDeviceChanges && !vm.appSettings.pastePermissionHintDismissed
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    private var isExplicitlyRefreshing: Bool { vm.engine.isExplicitlyRefreshing }

    /// History rendered in the list, sorted newest-first. The mock data
    /// already lands in roughly that order but never trust the caller —
    /// SyncEngine will append in arrival order once wired.
    private var sortedHistory: [ClipboardHistoryItem] {
        vm.history.sorted { $0.timestamp > $1.timestamp }
    }

    private var latestId: UUID? { sortedHistory.first?.id }

    /// Bucket the sorted history into 今天 / 昨天 / 7 天内 / 更早 sections.
    /// The "past 7 days" bucket is a sliding-window count rather than the
    /// calendar's "this week" — `Calendar.isDate(_:equalTo:toGranularity:)`
    /// keys off `firstWeekday`, so on Sundays (firstWeekday=1, zh_CN) the
    /// week-of-year window collapses to today only and the bucket
    /// disappears. A 7-day window is what users actually mean.
    private var groupedHistory: [HistorySection] {
        HistorySection.bucket(sortedHistory)
    }

    var body: some View {
        listOrEmpty
            // Paste-permission hint sits above both the list and the empty
            // state (it's a body-level inset, not a List one), so it shows the
            // moment auto-push is on regardless of whether history exists yet.
            .safeAreaInset(edge: .top, spacing: 0) {
                if showPasteHint {
                    PastePermissionBanner(
                        onOpenSettings: { openAppSettings() },
                        onDismiss: { vm.appSettings.pastePermissionHintDismissed = true }
                    )
                }
            }
            .animation(.snappy, value: showPasteHint)
            .refreshable {
                await vm.engine.explicitRefresh()
            }
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("剪贴板")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ServerChip(
                        activeServer: vm.activeServer,
                        isAutoSwitched: vm.activeServer?.id != vm.servers.activeConfig?.id,
                        allServers: vm.servers.configs,
                        onSelect: { id in vm.setActiveServer(id) }
                    )
                }
                if let issue = currentIssue {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingErrorSheet = true
                        } label: {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(issue.tint)
                        }
                        .accessibilityLabel(Text(issue.title))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        vm.engine.forceTickNow()
                    } label: {
                        if isExplicitlyRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isExplicitlyRefreshing)
                }
            }
            .sheet(item: $previewItem) { item in
                ClipboardPreviewSheet(item: item, vm: vm)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingErrorSheet) {
                if let issue = currentIssue {
                    IssueDetailSheet(
                        issue: issue,
                        onPrimaryAction: {
                            showingErrorSheet = false
                            switch issue.primaryAction {
                            case .goToSettings:    onGoToSettings()
                            case .retry:           vm.engine.forceTickNow()
                            case .acknowledgeLoop: vm.engine.acknowledgeLoopDetection()
                            case .dismiss:         break
                            }
                        }
                    )
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                }
            }
    }

    @ViewBuilder
    private var listOrEmpty: some View {
        if sortedHistory.isEmpty {
            ContentUnavailableView {
                Label {
                    Text("还没有同步过剪贴板")
                } icon: {
                    Image(systemName: "doc.on.clipboard")
                }
            } description: {
                Text("服务器的新内容会自动出现在这里；本机内容点下方按钮推送")
            } actions: {
                PasteButton(supportedContentTypes: PastedItemExtractor.supportedContentTypes) { providers in
                    Task { await vm.pushPastedProviders(providers) }
                }
                .tint(.accentColor)
                .accessibilityLabel(Text("推送本机剪贴板到服务器"))
            }
        } else {
            List {
                ForEach(groupedHistory) { section in
                    Section {
                        ForEach(section.items) { item in
                            Button {
                                previewItem = item
                            } label: {
                                ClipboardRow(
                                    item: item,
                                    isLatest: item.id == latestId
                                )
                                .padding(.vertical, 14)
                                .padding(.horizontal, 14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if item.entry.type == .text {
                                    Button {
                                        vm.reapplyText(item.entry.text)
                                    } label: {
                                        Label("复制", systemImage: "doc.on.clipboard")
                                    }
                                    .tint(.blue)
                                } else if item.entry.type == .image, item.entry.hasData {
                                    Button {
                                        Task { await vm.applyAttachment(for: item) }
                                    } label: {
                                        Label("复制", systemImage: "doc.on.clipboard")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    vm.removeHistoryItem(id: item.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                                .tint(.red)
                                if item.entry.hasData,
                                   item.entry.type == .image || item.entry.type == .file {
                                    Button {
                                        Task { await vm.saveAttachment(for: item) }
                                    } label: {
                                        Label("保存", systemImage: "square.and.arrow.down")
                                    }
                                }
                            }
                            .contextMenu {
                                rowMenu(for: item)
                            }
                        }
                    } header: {
                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .textCase(nil)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                    }
                }
            }
            .listStyle(.plain)
            .listRowSpacing(8)
            .environment(\.defaultMinListHeaderHeight, 0)
            .safeAreaInset(edge: .top, spacing: 0) {
                // Incoming (server→device) and outgoing (device→server)
                // nudges share one rounded container so they read as a
                // matched pair, not two near-identical stacked cards. Either
                // row may be absent; a hairline divides them only when both
                // show. The outgoing row's read goes through the system
                // `PasteButton` (no "Allow Paste" prompt); it's suppressed
                // when the user opted into fully-automatic push — the engine
                // pushes on its own then (see `autoPushDeviceChanges`).
                SyncNudgeStack(
                    showPending: engineState == .hasNewUnwritten,
                    onApply: {
                        Task {
                            await vm.applyServerToDevice()
                            // `applyError == nil` covers the text-no-data (sync
                            // path, applyError is set to nil before return) and
                            // text/image-with-data success cases. On a network
                            // failure applyError is set, the row stays so the
                            // user can retry.
                            if vm.applyError == nil {
                                vm.engine.markStagedApplied()
                            }
                        }
                    },
                    detection: vm.appSettings.autoPushDeviceChanges ? nil : vm.pasteboardDetection,
                    onPaste: { providers in
                        Task { await vm.pushPastedProviders(providers) }
                    }
                )
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // `lastSavedFileURL` and `lastAppliedAttachmentName` are
                // mutually cleared on each attempt (see AppViewModel),
                // but if both ever co-exist save wins — it's the more
                // expensive action so its feedback is more meaningful.
                //
                // Auto-dismiss after 3s: the engine's 1Hz tick bypasses
                // `vm.refresh()` (which is the only clear path besides a
                // new save/apply attempt), so without this the banner
                // would stay pinned to the bottom indefinitely.
                if let url = vm.lastSavedFileURL {
                    SavedBanner(filePath: displayPath(for: url))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: url) {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            if vm.lastSavedFileURL == url {
                                vm.lastSavedFileURL = nil
                            }
                        }
                } else if let name = vm.lastAppliedAttachmentName {
                    AppliedBanner(name: name)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: name) {
                            try? await Task.sleep(for: .seconds(3))
                            guard !Task.isCancelled else { return }
                            if vm.lastAppliedAttachmentName == name {
                                vm.lastAppliedAttachmentName = nil
                            }
                        }
                }
            }
            .animation(.snappy, value: engineState)
            .animation(.snappy, value: vm.lastSavedFileURL)
            .animation(.snappy, value: vm.lastAppliedAttachmentName)
            .animation(.snappy, value: vm.pasteboardDetection)
        }
    }

    @ViewBuilder
    private func rowMenu(for item: ClipboardHistoryItem) -> some View {
        if item.entry.type == .text {
            Button {
                vm.reapplyText(item.entry.text)
            } label: {
                Label("复制到本机", systemImage: "doc.on.clipboard")
            }
            Button {
                UIPasteboard.general.string = item.entry.text
            } label: {
                Label("仅复制文本", systemImage: "text.alignleft")
            }
        } else if item.entry.type == .image, item.entry.hasData {
            Button {
                Task { await vm.applyAttachment(for: item) }
            } label: {
                Label("复制到本机", systemImage: "doc.on.clipboard")
            }
        }
        if item.entry.hasData,
           item.entry.type == .image || item.entry.type == .file {
            Button {
                Task { await vm.saveAttachment(for: item) }
            } label: {
                Label("保存到 Documents", systemImage: "square.and.arrow.down")
            }
        }
        Divider()
        Button(role: .destructive) {
            vm.removeHistoryItem(id: item.id)
        } label: {
            Label("从历史中删除", systemImage: "trash")
        }
    }

    /// Active error worth surfacing as the toolbar's red bang. `nil` keeps
    /// the chrome clean. Priority: save-failure (user-initiated, sticky
    /// until next attempt) > engine state (auth fail > offline). The
    /// `.hasNewUnwritten` state is intentionally NOT an issue — it owns
    /// its own banner above the list.
    private var currentIssue: HomeIssue? {
        if let err = vm.saveError {
            return .saveFailed(message: errorMessage(err), detail: err.underlying)
        }
        switch engineState {
        case .authFailed:
            return .authFailed(detail: vm.engine.lastError?.underlying)
        case .offlineRetrying:
            if let err = vm.engine.lastError {
                return .offline(message: errorMessage(err), detail: err.underlying)
            }
            return .offline(message: String(localized: "离线 · 重试中"), detail: nil)
        case .loopDetected:
            return .loopDetected(detail: vm.engine.lastError?.underlying)
        case .idle, .succeeded, .hasNewUnwritten:
            return nil
        }
    }

    private func displayPath(for url: URL) -> String {
        url.pathComponents.suffix(2).joined(separator: "/")
    }

    private func errorMessage(_ err: SyncError) -> String {
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

// MARK: - Date bucketing

/// Time-bucketed list section. Title is computed once during bucketing
/// and stored so the view doesn't re-evaluate the calendar on every
/// redraw. `id` is the bucket case so SwiftUI's diffing stays stable
/// even when the items inside change.
private struct HistorySection: Identifiable {
    enum Bucket: Int, CaseIterable {
        case today, yesterday, pastWeek, earlier

        var title: String {
            switch self {
            case .today:     String(localized: "今天")
            case .yesterday: String(localized: "昨天")
            case .pastWeek:  String(localized: "7 天内")
            case .earlier:   String(localized: "更早")
            }
        }
    }

    let id: Bucket
    let title: String
    let items: [ClipboardHistoryItem]

    static func bucket(
        _ items: [ClipboardHistoryItem],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [HistorySection] {
        var buckets: [Bucket: [ClipboardHistoryItem]] = [:]
        for item in items {
            buckets[Self.bucket(for: item.timestamp, now: now, calendar: calendar), default: []]
                .append(item)
        }
        return Bucket.allCases.compactMap { b in
            guard let items = buckets[b], !items.isEmpty else { return nil }
            return HistorySection(id: b, title: b.title, items: items)
        }
    }

    private static func bucket(for date: Date, now: Date, calendar: Calendar) -> Bucket {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        // Sliding 7-day window from `now`. Yesterday is carved out above,
        // so this catches 2–7 days ago regardless of `firstWeekday`.
        if let sevenAgo = calendar.date(byAdding: .day, value: -7, to: now),
           date >= sevenAgo {
            return .pastWeek
        }
        return .earlier
    }
}

// MARK: - Row

private struct ClipboardRow: View {
    let item: ClipboardHistoryItem
    let isLatest: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ClipboardKindBadge(kind: item.entry.type, size: .medium, showsLabel: false)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                preview
                metadataRow
            }

            Spacer(minLength: 0)

            if isLatest {
                latestPill
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.entry.type {
        case .text:
            Text(item.entry.text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        case .image, .file, .group:
            VStack(alignment: .leading, spacing: 2) {
                Text(item.entry.text)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let dataName = item.entry.dataName, dataName != item.entry.text {
                    Text(dataName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 6) {
            Image(systemName: item.direction == .pulled ? "arrow.down" : "arrow.up")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(item.direction == .pulled ? Color.blue : Color.accentColor)
            Text(item.timestamp.relativeShort)
            if let size = item.entry.size {
                Text("·").foregroundStyle(.tertiary)
                Text(formatSize(size, kind: item.entry.type))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var latestPill: some View {
        Text("当前")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(.systemBackground))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor, in: Capsule())
            .accessibilityLabel(Text("当前剪贴板"))
    }
}

// MARK: - Inline banners

/// Inset rounded card pinned above the list when the engine has unwritten
/// server content. Tapping "应用" pushes it into UIPasteboard. Sits inside
/// the same scroll surface (safeAreaInset) so it scrolls with the list
/// instead of orphaning at the top of the screen.
/// Top-pinned nudge pair. The incoming row (server has new content → 应用)
/// and the outgoing row (device has new content → 粘贴, via the prompt-free
/// system `PasteButton`) share one rounded container with a hairline
/// between, so the two read as a deliberate matched pair instead of two
/// stacked look-alike cards. Either row may be absent. Neither row carries
/// a dismiss control: both simply wait until the user acts or the
/// underlying content changes (strict symmetry — and the free detection
/// behind the outgoing row never reads content until the `PasteButton` is
/// tapped, so a lingering row costs nothing and leaks nothing).
private struct SyncNudgeStack: View {
    let showPending: Bool
    let onApply: () -> Void
    /// Non-nil ⇒ render the outgoing row. Caller passes `nil` under
    /// auto-push, when the engine pushes on its own.
    let detection: PasteboardDetection?
    let onPaste: ([NSItemProvider]) -> Void

    var body: some View {
        if showPending || detection != nil {
            VStack(spacing: 0) {
                if showPending {
                    PendingRow(onApply: onApply)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if showPending, detection != nil {
                    Divider()
                }
                if let detection {
                    PushRow(kind: detection.kind, onPaste: onPaste)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(
                Color.accentColor.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Incoming nudge: the server staged content the device hasn't written
/// yet. Single-line so it height-matches `PushRow` in the shared container.
private struct PendingRow: View {
    let onApply: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("服务器有新内容")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onApply) {
                Text("应用")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(.systemBackground))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Outgoing nudge: the FREE pasteboard detection (changeCount +
/// hasStrings/hasImages, no content read) spotted new local content. The
/// kind is folded into the title so the row stays single-line and
/// symmetric with `PendingRow`. The actual read happens only when the user
/// taps the embedded system `PasteButton`, which grants access without the
/// "Allow Paste" prompt — the whole reason this is a `PasteButton` and not
/// a plain button.
private struct PushRow: View {
    let kind: PasteboardDetection.Kind
    let onPaste: ([NSItemProvider]) -> Void

    private var title: LocalizedStringKey {
        switch kind {
        case .text:  "本机有新文本"
        case .url:   "本机有新链接"
        case .image: "本机有新图片"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            PasteButton(supportedContentTypes: PastedItemExtractor.supportedContentTypes, payloadAction: onPaste)
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.accentColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// Transient positive feedback after `applyAttachment(for:)`. Mirrors
/// the SavedBanner layout but tints blue and points at the clipboard
/// glyph — same visual vocabulary as the swipe-leading "复制" action.
private struct AppliedBanner: View {
    let name: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.blue)
            Text("已复制 \(name) 到剪贴板")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.4)
        }
    }
}

/// Transient positive feedback after `saveServerAttachment()`. Cleared
/// implicitly on the next refresh — same lifecycle as the old card's
/// bottom bar, just rehomed to a banner.
private struct SavedBanner: View {
    let filePath: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
            Text("已保存到 \(filePath)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.4)
        }
    }
}

/// Home hint nudging the user to set「从其他 App 粘贴」to「允许」once they've turned
/// on fully-automatic push — otherwise iOS prompts「允许粘贴」on every engine
/// read. Dismissible; the choice persists via `pastePermissionHintDismissed`.
private struct PastePermissionBanner: View {
    var onOpenSettings: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text("已开启自动推送")
                    .font(.footnote.weight(.semibold))
                Text("把「从其他 App 粘贴」设为「允许」可避免反复弹窗,让同步静默进行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开设置", action: onOpenSettings)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
            }
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }
}

// MARK: - Toolbar issue model + detail sheet

/// An error that's worth a red bang in the toolbar. Carries enough copy
/// to render both the icon's accessibility label and the detail sheet
/// without HomeView needing to re-derive strings.
private enum HomeIssue: Equatable {
    case authFailed(detail: String?)
    case offline(message: String, detail: String?)
    case saveFailed(message: String, detail: String?)
    /// Cycle-detector tripped: the engine paused itself because the same
    /// clipboard hash was being applied and pushed in alternation. Primary
    /// action calls `engine.acknowledgeLoopDetection()` to reset the
    /// breaker and restart the loop.
    case loopDetected(detail: String?)

    enum PrimaryAction {
        case goToSettings
        case retry
        case acknowledgeLoop
        case dismiss
    }

    var tint: Color {
        switch self {
        case .authFailed, .saveFailed:    .red
        case .offline, .loopDetected:     .orange
        }
    }

    var symbolName: String {
        switch self {
        case .authFailed:    "lock.fill"
        case .offline:       "wifi.exclamationmark"
        case .saveFailed:    "exclamationmark.triangle.fill"
        case .loopDetected:  "arrow.triangle.2.circlepath"
        }
    }

    var title: String {
        switch self {
        case .authFailed:    String(localized: "认证失败")
        case .offline:       String(localized: "无法连接服务器")
        case .saveFailed:    String(localized: "保存失败")
        case .loopDetected:  String(localized: "自动同步已暂停")
        }
    }

    var message: String {
        switch self {
        case .authFailed:
            String(localized: "请检查用户名和密码是否正确。修改后会自动重新同步。")
        case .offline(let message, _):
            message
        case .saveFailed(let message, _):
            message
        case .loopDetected:
            String(localized: "检测到同一份剪贴板内容在本机和服务器之间反复同步。点「重新启用」继续，或检查另一端的客户端是否也在自动同步同一份内容。")
        }
    }

    var detail: String? {
        switch self {
        case .authFailed(let d), .offline(_, let d), .saveFailed(_, let d), .loopDetected(let d):
            d
        }
    }

    var primaryAction: PrimaryAction {
        switch self {
        case .authFailed:    .goToSettings
        case .offline:       .retry
        case .saveFailed:    .dismiss
        case .loopDetected:  .acknowledgeLoop
        }
    }

    var primaryActionLabel: LocalizedStringKey {
        switch self {
        case .authFailed:    "去设置"
        case .offline:       "立即重试"
        case .saveFailed:    "好"
        case .loopDetected:  "重新启用"
        }
    }
}

private struct IssueDetailSheet: View {
    let issue: HomeIssue
    let onPrimaryAction: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: issue.symbolName)
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(issue.tint)
                .padding(.top, 24)

            VStack(spacing: 8) {
                Text(issue.title)
                    .font(.title3.weight(.semibold))
                Text(issue.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if let detail = issue.detail, !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .frame(maxHeight: 80)
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 20)
            }

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button(action: onPrimaryAction) {
                    Text(issue.primaryActionLabel)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(issue.tint)

                Button("关闭") { dismiss() }
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Top toolbar server chip

private struct ServerChip: View {
    /// The server in use right now — the §5.3 effective server (manual
    /// baseline + Wi-Fi overlay). Picking a different one here writes the
    /// baseline `activeConfigId` via `onSelect`.
    let activeServer: ServerConfig?
    /// True when `activeServer` is the result of a Wi-Fi auto-switch rule
    /// overriding the manual baseline — drives the small "自动" badge so the
    /// user understands why the shown server differs from their last pick.
    let isAutoSwitched: Bool
    let allServers: [ServerConfig]
    let onSelect: (String) -> Void

    @State private var showingSwitcher: Bool =
        ProcessInfo.processInfo.environment["UC_OPEN_SWITCHER"] == "1"

    var body: some View {
        // `.fixedSize(horizontal: true, ...)` is load-bearing — without it
        // SwiftUI's navigation bar squeezes the leading toolbar item to
        // ~30pt and truncates the alias Text to zero width.
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            Text(verbatim: activeServer?.displayLabel ?? String(localized: "未配置"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if isAutoSwitched {
                Text("自动")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            Image(systemName: "chevron.down")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.thinMaterial, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Capsule())
        .onTapGesture { showingSwitcher = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text("切换服务器"))
        .accessibilityValue(Text(activeServer?.displayLabel ?? String(localized: "未配置")))
        .sheet(isPresented: $showingSwitcher) {
            ServerSwitcherSheet(
                activeId: activeServer?.id,
                servers: allServers,
                onSelect: { id in
                    onSelect(id)
                    showingSwitcher = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct ServerSwitcherSheet: View {
    let activeId: String?
    let servers: [ServerConfig]
    let onSelect: (String) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(servers) { server in
                        Button {
                            onSelect(server.id)
                        } label: {
                            ServerSwitcherRow(
                                server: server,
                                isActive: server.id == activeId
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            server.id == activeId
                                ? Color.green.opacity(0.08)
                                : Color.clear
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("切换服务器")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ServerSwitcherRow: View {
    let server: ServerConfig
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isActive ? Color.green : Color.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(server.displayLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(server.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                AutoSwitchConditionBadge(
                    strategy: server.autoSwitchStrategy,
                    wifiNames: server.autoSwitchWifiNames
                )
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Helpers

private extension Date {
    /// "刚刚" inside ±5s, otherwise the system relative formatter. Without
    /// the floor `RelativeDateTimeFormatter` happily returns "0 秒后" for
    /// `lastSyncedAt == .now`, which reads as a bug.
    var relativeShort: String {
        let dt = timeIntervalSinceNow
        if abs(dt) < 5 { return String(localized: "刚刚") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: self, relativeTo: .now)
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

private func previewVM(history: [ClipboardHistoryItem]? = nil) -> AppViewModel {
    let vm = AppViewModel.preview()
    if let history { vm.history = history }
    return vm
}

#Preview("Home — 列表") {
    NavigationStack {
        HomeView(vm: previewVM())
    }
}

#Preview("Home — 空状态") {
    NavigationStack {
        HomeView(vm: previewVM(history: []))
    }
}
