# Changelog

## 1.0 (8) — 2026-06-08

### New Features

- **Custom keyboard extension** — UniClip keyboard lets you paste synced clipboard
  content directly into any app without the "Allow Paste" prompt.
- **Key sound & haptic feedback** for the custom keyboard.
- **Per-server auto-switch strategy** — each server can now be assigned a Wi-Fi,
  cellular, or Tailscale trigger so the active server switches automatically based
  on network conditions.
- **Parameterized send/receive shortcuts** — Shortcuts actions now include a server
  picker, so you can target a specific server instead of always using the active one.

### Bug Fixes

- Fixed keyboard return-key glyph not visible in dark mode.
- Fixed AddServerSheet reappearing as a blank form after dismiss.

## 1.0 (7) — 2026-06-01

### New Features

- Unified "current server" concept (default server + home pin merged).
- Consent-based clipboard push (PasteButton) to eliminate the "Allow Paste" prompt.

### Bug Fixes

- Fixed text/URL extraction from PasteButton providers.
- Symmetric push/pull nudge stack refactor.

## 1.0 (6) — 2026-05-25

### New Features

- Pin server via home-screen chip, override SSID auto-switch.
- Light / dark / system theme preference.

### Bug Fixes

- Persisted last-synced hash to file to defeat cfprefsd cross-process lag.
- Detect cross-app pasteboard changes via changeCount polling.
- Allow HTTP to Tailscale CGNAT range via NSAllowsArbitraryLoads.
- Restored cross-line selection of wrapped URLs in clipboard preview.
- Faster long-text clipboard preview rendering.
