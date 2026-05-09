# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Product

UniClipboard is a SwiftUI iOS client for self-hosted clipboard sync. It is **wire-compatible with [SyncClipboard](https://github.com/Jeric-X/SyncClipboard)** — any SyncClipboard-protocol server works as a backend. UI copy treats `UniClipboard` as the primary brand and demotes `SyncClipboard` to a compatibility footnote (e.g. Settings → About reads "兼容 SyncClipboard v1"). Keep this distinction when writing new strings.

The wire protocol and persistence formats are normative: **`docs/SYNC_PROTOCOL.md` is the source of truth.** When code disagrees with the spec, update the spec to match reality (it says so itself). Round-trip JSON fixtures live under `docs/examples/` and are referenced by name in tests.

## Dual-build layout

The repository builds two ways and shares source between them:

- **Xcode app target** (`UniClipboard.xcodeproj`) compiles everything under `UniClipboard/` via `PBXFileSystemSynchronizedRootGroup`. Drop a new `.swift`/`.xcstrings` file anywhere under `UniClipboard/` and Xcode picks it up — no pbxproj edit needed.
- **SwiftPM library + tests** (`Package.swift` at the repo root) re-uses `UniClipboard/Models/` as a target source path so the model layer can be unit-tested via `swift test` without provisioning an in-Xcode test target. Tests live in `Tests/UniClipboardModelsTests/` and load fixtures from `docs/examples/` via `#filePath` — no resource copy or symlink.

Don't try to add SwiftPM `.copy("Fixtures")` with a directory symlink — SwiftPM doesn't follow it. The `#filePath` approach was chosen specifically because it survives without any sync step.

## Commands

Run from the repo root.

```bash
# Run model round-trip tests (23 cases, ~50ms)
swift test

# Build the iOS app for the simulator
xcodebuild -scheme UniClipboard -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build

# Run a single test by name
swift test --filter FixturesTests/test_clipboardNoHash_optionalKeysAreOmittedNotNullified
```

Bundle id: `app.uniclipboard.UniClipboard`. Deployment target iOS 26.2. Swift 5 mode; `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is on for the app target (so newly-written types in `UniClipboard/` are MainActor-isolated by default; the SwiftPM `Models` target is unisolated).

## Screenshots / debug runs

Useful for evaluating UI without manual taps. After installing the built `.app`:

```bash
APP="$(xcodebuild -scheme UniClipboard -sdk iphonesimulator -showBuildSettings 2>/dev/null \
  | awk -F'= ' '/BUILT_PRODUCTS_DIR/{print $2; exit}')/UniClipboard.app"
xcrun simctl install "iPhone 17 Pro" "$APP"
xcrun simctl launch "iPhone 17 Pro" app.uniclipboard.UniClipboard \
  -AppleLanguages '(zh-Hans)' -AppleLocale zh_CN
xcrun simctl io "iPhone 17 Pro" screenshot /tmp/shot.png
```

Pass per-launch env via `SIMCTL_CHILD_<NAME>=value`. Locale via `-AppleLanguages '(en)'` etc. (the app supports `en` and `zh-Hans`; `zh-Hans` is the source language of the catalog).

### Launch-time env hooks (DEBUG-style)

| Env | Effect |
|---|---|
| `UC_INIT_TAB=0\|1\|2` | Start on Clipboard / History / Settings tab |
| `UC_FRESH=1` | Boot with empty `ServerConfigList` → forces SetupFlow |
| `UC_SETUP_STEP=form\|autoswitch` | Bootstrap Setup `NavigationStack` path directly to that step |
| `UC_PREFILL=1` | Prefill ServerForm fields with mock defaults |
| `UC_PREFILL_TEST=success\|authFailed\|unreachable\|missingFields` | Seed ServerForm test-connection result on appear |

These hooks are only present so the design can be inspected without an interactive simulator (simctl has no synthetic-tap API). Not feature flags; remove on the day this becomes a real product.

## Architecture

```
UniClipboard/
├── Models/         # Pure-Foundation Codable types — also the SwiftPM target
├── Mock/           # In-memory fake state (servers / clipboard / history)
├── Views/
│   ├── Setup/      # First-run flow (Welcome → ServerForm → AutoSwitch)
│   └── *.swift     # HomeView, HistoryView, SettingsView, components
├── Localizable.xcstrings  # zh-Hans source, en translation
└── ContentView.swift      # Root: SetupFlow when configs.isEmpty, else TabView
```

`ContentView` is the routing root: it switches between `SetupFlowView` and the three-tab `TabView` based on whether `servers.configs.isEmpty`. There is **no global app state container yet** — `ContentView` owns `@State` for `servers` and `appSettings` and threads bindings down. When wiring real persistence, replace these with a single observable view-model bound to `UserDefaults` keys defined in `AppSettings.PersistenceKey` (see §5.5 of the protocol spec).

Key model invariants (failures here will be caught by `FixturesTests`):

- `Clipboard.hash` / `dataName` / `size` use **omit-nil-on-encode** discipline. Re-encoding `clipboard_no_hash.json` must NOT introduce any `"…": null` keys — only `type`, `text`, `hasData` survive.
- `hash` is uppercase 64-char hex SHA-256. Whitespace-only strings are normalized to `nil` on decode (so the encoder omits the key, not write `""`).
- `ServerConfigList.activeConfig` falls back to `configs[0]` when `activeConfigId` doesn't resolve, and to `nil` when `configs` is empty (network code MUST refuse to make calls in the latter case).
- `LegacyServerConfig.migrated()` is the exact one-shot path for users coming from the pre-multi-server format. The new key (`server_config_list`) replaces the old key (`server_config`) — see §5.5.

## i18n

`UniClipboard/Localizable.xcstrings` has `sourceLanguage: "zh-Hans"`. All Swift literals like `Text("剪贴板")` are catalog keys; the `en` translation is provided alongside. Adding a new locale is a catalog-only change (no Swift edits).

When you encounter a SwiftUI initializer that takes a Swift `String` value (not `LocalizedStringKey`) — e.g., `LabeledContent(_, value: String)`, `Text(stringVar)` — wrap the literal with `String(localized: "…")` or restructure to use a `Text` literal in a closure. The codebase already does this (see `formatSize` in `HomeView.swift` and the `(未命名)` fallback in `SettingsView.swift`). Don't hardcode `Locale(identifier: …)` in formatters — let `RelativeDateTimeFormatter` and `ByteCountFormatter` follow the system locale.

If two distinct Chinese strings collide on a single English translation (e.g., the app uses 服务器 in two roles), split them in the Swift code with different keys before adding to the catalog. The current split: `服务器列表` → "Servers" (the list page), `服务器` → "Server" (the badge on the home card).

## Mock data, briefly

`Mock.swift` is a single namespace `enum Mock` with `servers`, `serverLatest`, `deviceClipboard`, and `history`. The latter is `[ClipboardHistoryItem]` (provenance-tagged Clipboards with timestamps and direction). `ClipboardHistoryItem` is a UI-only type — it's not persisted by the protocol. Replace `Mock.*` references with real state when you wire the network layer; nothing else should need to change.
