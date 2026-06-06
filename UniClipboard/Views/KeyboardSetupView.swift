import SwiftUI
import UIKit

/// Onboarding + guidance for the UniClip keyboard and the per-app
/// "粘贴自其他 App" (Paste from Other Apps) authorization. Both are one-time,
/// user-granted *system* permissions — the app can explain them and deep-link
/// to Settings, but cannot flip them on the user's behalf (there is no
/// Info.plist key or in-app toggle for either).
///
/// The mechanism (iOS 16.1+): the **first** programmatic `UIPasteboard`
/// content read fires a one-time "允许粘贴" prompt; once the user taps 允许,
/// that bundle reads the system pasteboard *silently forever after*, and a
/// "粘贴自其他 App" switch appears under the app's 系统设置 page. That is the
/// whole basis of "open keyboard = auto-sync": the keyboard prompts once on
/// first use, the user allows, and from then on every keyboard-open silently
/// reads + pushes the clipboard.
///
/// Authorization is scoped **per bundle id**, so the keyboard extension earns
/// its own grant from inside the keyboard on first use; the "授权本机读取剪贴板"
/// button here primes the *main app's* grant (and makes the per-app switch
/// appear in Settings) so fully-automatic push (§ AppSettings.autoPushDeviceChanges)
/// can run without prompting later.
struct KeyboardSetupView: View {
    @Binding var appSettings: AppSettings
    @State private var pasteProbe: PasteProbeResult = .idle

    enum PasteProbeResult: Equatable {
        case idle
        case granted(hasContent: Bool)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("打开键盘即自动同步", systemImage: "keyboard.badge.ellipsis")
                        .font(.headline)
                    Text("在任意输入框切换到 UniClip 键盘时,会把本机刚复制的文本或图片自动发送到当前服务器,并把服务器最新的内容作为候选,点一下即可直接插入——全程不经过系统剪贴板,不会反复弹「允许粘贴」。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                stepRow(1,
                        title: String(localized: "添加 UniClip 键盘"),
                        detail: String(localized: "设置 › 通用 › 键盘 › 键盘 › 添加新键盘,选择 UniClip"))
                stepRow(2,
                        title: String(localized: "允许完全访问"),
                        detail: String(localized: "在键盘列表点按 UniClip,打开「允许完全访问」——联网同步与读取剪贴板都需要它"))
                stepRow(3,
                        title: String(localized: "了解「允许粘贴」提示"),
                        detail: String(localized: "复制新内容后首次读取时,iOS 会弹一次「允许粘贴」(对每条新内容逐条授权);重复打开键盘、未复制新内容时不会再弹"))

                Button {
                    openAppSettings()
                } label: {
                    Label("打开 UniClip 系统设置", systemImage: "gear")
                }
            } header: {
                Text("启用键盘")
            } footer: {
                Text("「允许完全访问」位于 设置 › 通用 › 键盘 › UniClip。系统未提供直达该页的链接,可从上方系统设置页逐级进入。")
                    .font(.caption)
            }

            Section {
                Toggle(isOn: $appSettings.keyboardSoundFeedback) {
                    Label("按键音", systemImage: "speaker.wave.2")
                }
                Toggle(isOn: $appSettings.keyboardHapticFeedback) {
                    Label("触感反馈", systemImage: "hand.tap")
                }
            } header: {
                Text("按键反馈")
            } footer: {
                Text("在 UniClip 键盘上点按时的声音与振动。按键音还受系统「设置 › 声音与触感」里「键盘点击音」总开关影响;触感反馈需要键盘「允许完全访问」。")
                    .font(.caption)
            }

            Section {
                Button {
                    probePaste()
                } label: {
                    Label("授权本机读取剪贴板", systemImage: "doc.on.clipboard")
                }
                switch pasteProbe {
                case .idle:
                    EmptyView()
                case .granted(let hasContent):
                    Label {
                        Text(hasContent
                             ? String(localized: "已获授权 — 可读取本机剪贴板")
                             : String(localized: "已获授权 — 当前剪贴板为空"))
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .font(.footnote)
                }
            } header: {
                Text("自动粘贴授权")
            } footer: {
                Text("iOS 默认对来自其他 App 的剪贴板逐条询问——这就是每复制一条新内容、首次读取时都会弹「允许粘贴」的原因。把 设置 › UniClip › 粘贴自其他 App 设为「允许」即可完全静默(该开关在首次弹窗后才出现)。授权按 App 独立:键盘扩展可能需要在键盘内单独授权,且部分系统版本不为键盘提供该开关。")
                    .font(.caption)
            }
        }
        .navigationTitle("键盘与自动同步")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Rows

    private func stepRow(_ n: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(Color(.systemBackground))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    /// Read `UIPasteboard.general` once to trigger iOS's per-app "允许粘贴"
    /// prompt. The read itself is the authorization gesture: after the user
    /// taps 允许, this bundle reads silently from then on and the system
    /// surfaces the "粘贴自其他 App" switch under the app's settings page.
    /// We only look at *presence* (`hasStrings`/`hasImages`) for the result
    /// label — we never display the user's clipboard content.
    private func probePaste() {
        let pb = UIPasteboard.general
        let hasContent = pb.hasStrings || pb.hasImages || pb.hasURLs
        // Touch actual content so the read counts as a content access (the
        // thing that arms the prompt + per-app entry), then discard it.
        _ = pb.string
        pasteProbe = .granted(hasContent: hasContent)
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

#Preview {
    @Previewable @State var settings = AppSettings.defaults
    return NavigationStack {
        KeyboardSetupView(appSettings: $settings)
    }
}
