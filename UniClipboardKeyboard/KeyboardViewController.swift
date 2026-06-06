import UIKit
import SwiftUI

/// Principal class for the UniClip custom keyboard. iOS instantiates this
/// (`NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).KeyboardViewController`)
/// when the user switches to the UniClip keyboard. It subclasses
/// `UIInputViewController` — the keyboard analog of a view controller — and
/// hosts a SwiftUI sheet via `UIHostingController`, mirroring the Share
/// Extension's `ShareViewController` approach.
///
/// The keyboard's job is clipboard *sync*, not text entry. On appear it:
///   1. reads the device pasteboard and pushes anything new to the active
///      server (**uplink** — "open keyboard = auto-sync"); and
///   2. pulls the server's latest clipboard and offers it as a one-tap
///      insert candidate (**downlink** — `insertText`, no pasteboard hop).
///
/// Both halves need **Full Access** (`RequestsOpenAccess=YES` + the user's
/// "允许完全访问" toggle): without it, `UIPasteboard` and `URLSession` are
/// both unavailable to a keyboard, so we render a "needs Full Access" hint
/// instead. The first content read after Full Access is granted fires iOS's
/// per-app "允许粘贴" prompt once; after the user allows, reads are silent —
/// which is exactly what makes the auto-sync feel automatic.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var host: UIHostingController<KeyboardRootView>?

    /// Custom keyboard height. Priority 999 (not required) so it can never
    /// conflict with the system-imposed constraints on the input view.
    private lazy var heightConstraint: NSLayoutConstraint = {
        // Taller than a stock keyboard: the Paste-style layout stacks a
        // branded/search top bar, a row of 150pt clipboard cards, the
        // space/⌫/return key row, and a globe/dismiss strip. Priority 999
        // (not required) so it can never conflict with the system-imposed
        // constraints on the input view.
        let c = view.heightAnchor.constraint(equalToConstant: 310)
        c.priority = UILayoutPriority(999)
        return c
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Wire the model's UI callbacks to the input controller. `unowned`
        // is safe: the model is owned by (and outlived by) this controller.
        model.insertText = { [unowned self] text in
            self.textDocumentProxy.insertText(text)
        }
        model.deleteBackward = { [unowned self] in
            self.textDocumentProxy.deleteBackward()
        }
        model.advanceInputMode = { [unowned self] in
            self.advanceToNextInputMode()
        }
        model.dismiss = { [unowned self] in
            self.dismissKeyboard()
        }

        // Keep every layer transparent so the system-drawn keyboard tray
        // (flat gray pre-iOS 26, Liquid Glass on iOS 26+) shows through. The
        // controller's own view defaults opaque, and UIHostingController adds
        // an opaque background of its own — both would hide the system tray
        // and force us to fake a color that can't match Liquid Glass.
        view.backgroundColor = .clear

        let root = KeyboardRootView(model: model)
        let host = UIHostingController(rootView: root)
        self.host = host
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        heightConstraint.isActive = true
        // `hasFullAccess` / `needsInputModeSwitchKey` are only reliable once
        // the input view is on screen — read them here, then drive the sync.
        model.needsInputModeSwitchKey = needsInputModeSwitchKey
        model.hasFullAccess = hasFullAccess
        model.setReturnKeyType(textDocumentProxy.returnKeyType)
        model.onAppear()
    }

    /// The host field can change (e.g. tapping from a search box to a body
    /// field) while our keyboard stays up. Re-read the Return-key intent so
    /// the key relabels itself (发送 / 搜索 / …) to match.
    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        model.setReturnKeyType(textDocumentProxy.returnKeyType)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop polling the pasteboard when the keyboard leaves the screen
        // (globe to another keyboard, dismissed, host app closed) so we don't
        // run a background timer the user can't see.
        model.stopMonitoring()
    }
}
