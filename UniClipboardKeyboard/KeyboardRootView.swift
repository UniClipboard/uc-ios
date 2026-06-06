import SwiftUI
import UIKit

/// The UniClip keyboard — a Paste-style hybrid: a top bar (🔍 + current
/// server), a horizontally-scrolling row of Liquid-Glass clipboard cards, and
/// a real key row (space / ⌫ / return) so light editing never forces a trip
/// back to the system keyboard. Tapping a card inserts its text inline
/// (downlink) or fetches + copies an image; a background pass auto-pushes
/// newly-copied device content (uplink). The 🌐 strip returns to a typing
/// keyboard.
struct KeyboardRootView: View {
    let model: KeyboardModel

    /// Search mode swaps the server-name bar for a type-scope filter strip
    /// (a custom keyboard has no QWERTY, so 🔍 filters rather than queries).
    @State private var searching = false
    @State private var filter: Filter = .all

    @State private var switchingServer = false
    @State private var serverChoices: [ServerConfig] = []
    @State private var activeServerId: String?

    enum Filter: Int, CaseIterable, Identifiable {
        case all, text, link, image
        var id: Int { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all:   "全部"
            case .text:  "文本"
            case .link:  "链接"
            case .image: "图片"
            }
        }
        func matches(_ card: KeyboardModel.Card) -> Bool {
            switch self {
            case .all:   true
            case .text:  card.kind == .text
            case .link:  card.kind == .link
            case .image: card.kind == .image
            }
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 12)
                    // Symmetric, snug vertical insets so the bar hugs the card
                    // row beneath it — the 36pt bar already frames the ~30pt
                    // capsule / 34pt circle buttons, so anything larger reads as
                    // a loose, empty band between the three stacked sections.
                    .padding(.vertical, 4)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                keyRow
                bottomStrip
            }

            // Server switcher rides above the whole keyboard so its scrim
            // catches taps anywhere — top bar, cards, keys — not just the
            // card area.
            if switchingServer {
                serverSwitcherOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Deliberately NO opaque background: the system already draws the
        // keyboard tray (flat gray pre-iOS 26, Liquid Glass on iOS 26+) and it
        // auto-adapts to appearance + OS version. We keep the surface clear and
        // let that backdrop show through (the controller clears
        // UIHostingController's default opaque background). We also don't force
        // an appearance override — the UIKit tray follows the *system* scheme
        // and ignores preferredColorScheme, so following the system keeps our
        // content and the tray consistent.
        .tint(.accentColor)
    }

    // MARK: - Top bar

    @ViewBuilder
    private var topBar: some View {
        if searching {
            filterBar
        } else {
            serverBar
        }
    }

    private var serverBar: some View {
        ZStack {
            // Centered server name (tap → inline switcher).
            if model.gate == .ok {
                Button { openSwitcher() } label: {
                    HStack(spacing: 4) {
                        Text(verbatim: serverTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(switchingServer ? 180 : 0))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .liquidGlassCapsule()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("切换服务器"))
            } else {
                Text(verbatim: "UniClip")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 0) {
                if model.gate == .ok, !model.cards.isEmpty {
                    circleButton(system: "magnifyingglass") {
                        withAnimation(.snappy(duration: 0.22)) { searching = true }
                    }
                    .accessibilityLabel(Text("筛选"))
                }
                Spacer(minLength: 0)
                if model.gate == .ok {
                    syncButton
                        .animation(.snappy(duration: 0.28), value: model.isSyncing)
                        .animation(.snappy(duration: 0.28), value: model.syncFlash)
                }
            }
        }
        .frame(height: 36)
    }

    /// Top-right control: spinner while syncing, a brief green ✓ / amber !
    /// right after a pass that moved data or failed, otherwise the refresh
    /// glyph. The outcome badge is the elegant replacement for the old
    /// "已发送本机内容…" text chip.
    @ViewBuilder
    private var syncButton: some View {
        if model.isSyncing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 34, height: 34)
                .liquidGlassCircle()
                .transition(.opacity)
        } else if let flash = model.syncFlash {
            Image(systemName: flash == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(flash == .success ? Color.green : Color.orange)
                .frame(width: 34, height: 34)
                .liquidGlassCircle()
                .contentShape(Circle())
                .onTapGesture {
                    model.keyFeedback()
                    model.refresh(force: true)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
                .accessibilityLabel(Text(flash == .success ? "同步成功" : "同步失败"))
        } else {
            circleButton(system: "arrow.clockwise") {
                model.refresh(force: true)
            }
            .accessibilityLabel(Text("刷新"))
            .transition(.opacity)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            circleButton(system: "xmark") {
                withAnimation(.snappy(duration: 0.22)) {
                    searching = false
                    filter = .all
                }
            }
            .accessibilityLabel(Text("关闭筛选"))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Filter.allCases) { f in
                        let isOn = f == filter
                        Button {
                            model.keyFeedback()
                            withAnimation(.snappy(duration: 0.2)) { filter = f }
                        } label: {
                            Text(f.title)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(isOn ? Color(.systemBackground) : Color.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background {
                                    if isOn {
                                        Capsule().fill(Color.accentColor)
                                    } else {
                                        Capsule().fill(.regularMaterial)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 12)
            }
        }
        .frame(height: 36)
    }

    private var serverTitle: String {
        model.serverLabel.isEmpty ? String(localized: "UniClip") : model.serverLabel
    }

    // MARK: - Middle (cards / states + switcher overlay)

    private var displayedCards: [KeyboardModel.Card] {
        searching ? model.cards.filter(filter.matches) : model.cards
    }

    @ViewBuilder
    private var content: some View {
        switch model.gate {
        case .needsFullAccess:
            fullAccessHint
        case .noServer:
            centered {
                infoBlock(
                    system: "server.rack",
                    title: String(localized: "尚未配置服务器"),
                    message: String(localized: "请先打开 UniClipboard 主程序添加服务器")
                )
            }
        case .ok:
            cardArea
        }
    }

    @ViewBuilder
    private var cardArea: some View {
        let cards = displayedCards
        if !cards.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                // Lazy so off-screen image cards don't all fire their
                // thumbnail fetch at once — bounds concurrent network + decode
                // work to what's near the viewport (keyboard memory).
                LazyHStack(spacing: 12) {
                    ForEach(cards) { card in
                        CardView(model: model, card: card)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
        } else if model.isSyncing {
            centered {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在同步…").font(.callout).foregroundStyle(.secondary)
                }
            }
        } else if let err = model.lastError {
            centered {
                VStack(spacing: 10) {
                    infoBlock(system: "exclamationmark.triangle", title: String(localized: "同步失败"), message: err)
                    Button {
                        model.keyFeedback()
                        model.refresh(force: true)
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        } else {
            centered {
                infoBlock(
                    system: searching ? emptyFilterIcon : "tray",
                    title: searching ? emptyFilterTitle : String(localized: "暂无剪贴板记录"),
                    message: String(localized: "复制文本或图片后回到这里即可发送")
                )
            }
        }
    }

    private var emptyFilterIcon: String {
        switch filter {
        case .all:   "tray"
        case .text:  "doc.text"
        case .link:  "link"
        case .image: "photo.on.rectangle"
        }
    }

    private var emptyFilterTitle: String {
        switch filter {
        case .all:   String(localized: "暂无剪贴板记录")
        case .text:  String(localized: "暂无文本记录")
        case .link:  String(localized: "暂无链接记录")
        case .image: String(localized: "暂无图片记录")
        }
    }

    // MARK: - Server switcher overlay

    private func openSwitcher() {
        let choices = model.serverChoices()
        serverChoices = choices.servers
        activeServerId = choices.activeId
        withAnimation(.snappy(duration: 0.22)) { switchingServer = true }
    }

    private func closeSwitcher() {
        withAnimation(.snappy(duration: 0.2)) { switchingServer = false }
    }

    private var serverSwitcherOverlay: some View {
        ZStack(alignment: .top) {
            // Full-surface tap-to-dismiss scrim: covers the top bar, cards and
            // key row, so a tap anywhere outside the panel closes the switcher.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { closeSwitcher() }

            VStack(spacing: 2) {
                ForEach(serverChoices) { server in
                    Button {
                        model.keyFeedback()
                        if server.id != activeServerId { model.setActiveServer(server.id) }
                        closeSwitcher()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: server.id == activeServerId ? "checkmark.circle.fill" : "circle")
                                .font(.body)
                                .foregroundStyle(server.id == activeServerId ? Color.green : Color.secondary)
                            Text(verbatim: server.displayLabel)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: 260)
            .liquidGlassCard()
            // Drop below the top bar so it reads as a dropdown from the
            // server-name capsule rather than overlapping it.
            .padding(.top, 50)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Key row

    private var keyRow: some View {
        HStack(spacing: 7) {
            spaceKey.frame(maxWidth: .infinity)
            HStack(spacing: 7) {
                BackspaceKey(model: model).frame(maxWidth: .infinity)
                returnKey.frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 46)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var spaceKey: some View {
        Button {
            model.keyFeedback()
            model.insertText(" ")
        } label: {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .flatKey()
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("空格"))
    }

    private var returnKey: some View {
        Button {
            model.keyFeedback()
            model.insertText("\n")
        } label: {
            Group {
                if let title = model.returnKeyTitle {
                    Text(title).font(.callout.weight(.semibold))
                } else {
                    Image(systemName: "return").font(.system(size: 18, weight: .medium))
                }
            }
            // AccentColor's dark-mode variant is ivory, so the default white
            // label vanishes against the tint — paint the label in
            // systemBackground, which flips with appearance. (CLAUDE.md theme
            // gotcha for anything on top of Color.accentColor.)
            .foregroundStyle(Color(.systemBackground))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("回车"))
    }

    // MARK: - Bottom strip (globe / dismiss)

    @ViewBuilder
    private var bottomStrip: some View {
        // Only the globe lives down here. When iOS doesn't need a keyboard
        // switch key (e.g. UniClip is the only third-party keyboard) the
        // whole strip collapses so the keyboard ends right under the key row
        // instead of leaving a tall empty band above the home indicator.
        if model.needsInputModeSwitchKey {
            HStack(spacing: 0) {
                glyphButton(system: "globe", size: 28) { model.advanceInputMode() }
                    .accessibilityLabel(Text("切换键盘"))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            // Keep a little breathing room above the home indicator — flush
            // against the bottom edge reads as cramped.
            .padding(.bottom, 8)
            .frame(height: 30)
        }
    }

    // MARK: - Full-access hint

    private var fullAccessHint: some View {
        centered {
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                Text("需要「完全访问权限」")
                    .font(.headline)
                Text("在 设置 › 通用 › 键盘 › UniClip 中开启「允许完全访问」,即可在打开键盘时自动同步剪贴板。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Small building blocks

    private func infoBlock(system: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: system)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    private func glyphButton(system: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            model.keyFeedback()
            action()
        } label: {
            Image(systemName: system)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Glass circular button for the top bar — shares the Liquid Glass
    /// language of the centered server capsule so 🔍 / ⟳ / ✕ sit as a
    /// balanced set instead of bare floating glyphs.
    private func circleButton(system: String, action: @escaping () -> Void) -> some View {
        Button {
            model.keyFeedback()
            action()
        } label: {
            Image(systemName: system)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .liquidGlassCircle()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Backspace key (hold-to-repeat)

/// Backspace with press-and-hold auto-repeat: one delete on touch-down, then
/// after a short hold it repeats on an accelerating interval (like the system
/// keyboard). Uses `onLongPressGesture`'s `onPressingChanged` to bracket the
/// press; the repeat loop is a cancellable `Task` torn down on release /
/// disappear, with an iteration cap as a runaway backstop.
private struct BackspaceKey: View {
    let model: KeyboardModel

    @State private var pressing = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .flatKey()
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(pressing ? 0.55 : 1)
            .animation(.easeOut(duration: 0.08), value: pressing)
            // minimumDuration 0 ⇒ onPressingChanged(true) on touch-down; the
            // large maximumDistance keeps a slight finger slide from cancelling.
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 1000) {
                // perform — no-op; the press lifecycle is handled below.
            } onPressingChanged: { isPressing in
                pressing = isPressing
                if isPressing { startRepeating() } else { stopRepeating() }
            }
            .onDisappear { stopRepeating() }
            .accessibilityLabel(Text("删除"))
            .accessibilityAddTraits(.isButton)
    }

    private func startRepeating() {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            model.keyFeedback()                           // tactile confirm on touch-down
            model.deleteBackward()                        // immediate first delete
            try? await Task.sleep(for: .seconds(0.45))    // hold before auto-repeat kicks in
            var interval: Double = 0.11
            var count = 0
            while !Task.isCancelled, count < 600 {        // cap: runaway backstop
                model.keyFeedback(haptic: false)          // click on each repeat, no buzz
                model.deleteBackward()
                count += 1
                try? await Task.sleep(for: .seconds(interval))
                interval = max(0.035, interval * 0.90)    // accelerate toward ~28/s
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

// MARK: - Card

private struct CardView: View {
    let model: KeyboardModel
    let card: KeyboardModel.Card

    private var isActing: Bool { model.actingCardID == card.id }
    private var didAct: Bool { model.actedCardID == card.id }

    var body: some View {
        Button {
            model.activate(card)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                header
                content
            }
            .padding(12)
            .frame(width: 152, height: 150, alignment: .topLeading)
            .liquidGlassCard()
            .overlay(alignment: .center) {
                if didAct { actedOverlay }
            }
            // The card IS the button: without an explicit content shape, a
            // .plain button only hit-tests its rendered subviews (the text
            // glyphs), so the empty area below short text and the image
            // padding felt dead. Pin the hit target to the whole card.
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(model.actingCardID != nil)
        .animation(.easeInOut(duration: 0.2), value: didAct)
    }

    // "Text  3m" left, activity spinner right — mirrors Paste's card header.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kindIcon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(kindTint)
            Text(kindLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(kindTint)
            Text(card.time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            if isActing { ProgressView().controlSize(.mini) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch card.kind {
        case .text:
            Text(card.title)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(5)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                Text(card.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if let host = card.subtitle {
                    HStack(spacing: 4) {
                        Image(systemName: "link").font(.system(size: 10, weight: .semibold))
                        Text(host).font(.caption2).lineLimit(1).truncationMode(.middle)
                    }
                    .foregroundStyle(.tint)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image:
            CardThumbnail(model: model, card: card)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var actedOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
            Label(actedLabel, systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        }
        .transition(.opacity)
    }

    private var kindIcon: String {
        switch card.kind {
        case .text:  "text.alignleft"
        case .link:  "link"
        case .image: "photo"
        }
    }

    private var kindLabel: LocalizedStringKey {
        switch card.kind {
        case .text:  "文本"
        case .link:  "链接"
        case .image: "图片"
        }
    }

    private var kindTint: Color {
        switch card.kind {
        case .text:  .secondary
        case .link:  .accentColor
        case .image: .orange
        }
    }

    private var actedLabel: LocalizedStringKey {
        card.kind == .image ? "已复制" : "已插入"
    }
}

// MARK: - Lazy image thumbnail

/// Image card body: a rounded placeholder that fills in with a downsampled
/// thumbnail once `KeyboardModel.thumbnail(for:)` resolves. Keyed on the card
/// id so reused slots reload; failures / oversize originals leave the
/// placeholder in place.
private struct CardThumbnail: View {
    let model: KeyboardModel
    let card: KeyboardModel.Card

    @State private var image: UIImage?
    @State private var didLoad = false

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        // The gradient fill is the PRIMARY view, so it alone defines the
        // layout size (a Shape fills exactly the proposed slot). The thumbnail
        // rides as an `.overlay`: overlays never resize their primary, so
        // `scaledToFill`'s deliberately-oversized measurement can't grow the
        // card the way it did inside a ZStack (a flexible `.frame` won't clamp
        // it either — `max:.infinity` lets the oversize through). `clipShape`
        // then trims the overflow to a centered crop.
        shape
            .fill(
                LinearGradient(
                    colors: [Color.orange.opacity(0.18), Color.pink.opacity(0.12)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: didLoad ? "photo" : "photo.badge.arrow.down")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse, isActive: !didLoad)
                }
            }
            .clipShape(shape)
            .task(id: card.id) {
                didLoad = false
                image = await model.thumbnail(for: card)
                didLoad = true
            }
            .animation(.easeInOut(duration: 0.2), value: image)
    }
}

// MARK: - Liquid Glass helpers

private extension View {
    /// Card surface: real Liquid Glass on iOS 26+, a material+hairline fallback
    /// below it (deployment target is iOS 17, so the glass API is gated).
    @ViewBuilder
    func liquidGlassCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.06)))
        }
    }

    @ViewBuilder
    func liquidGlassCapsule() -> some View {
        let shape = Capsule(style: .continuous)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.06)))
        }
    }

    @ViewBuilder
    func liquidGlassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    /// Flat, opaque key cap for the space / ⌫ keys. Deliberately NOT Liquid
    /// Glass — the reflective glass read oddly on tappable keys. A solid fill
    /// that sits a shade lighter than the keyboard tray in both schemes
    /// (white on light, mid-gray on dark), with a hairline edge so it still
    /// reads as a raised key.
    @ViewBuilder
    func flatKey() -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        self
            .background(
                Color(uiColor: UIColor { trait in
                    trait.userInterfaceStyle == .dark
                        ? UIColor(white: 0.34, alpha: 1.0)
                        : UIColor.white
                }),
                in: shape
            )
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Keyboard — 卡片流") {
    KeyboardRootView(model: .previewReady())
        .frame(height: 310)
        .background(Color(.systemGray5))
}

#Preview("Keyboard — 空状态") {
    KeyboardRootView(model: .previewEmpty())
        .frame(height: 310)
        .background(Color(.systemGray5))
}
#endif
