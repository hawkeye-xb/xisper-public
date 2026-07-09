# Xisper macOS Native — Agent Handoff

**Date:** 2026-03-11
**Build status:** Compiles. Core functionality broken (auth → recording → inject pipeline untested end-to-end).
**User priority:** Fix core functionality first. UI improvements are secondary.

---

## How to Build & Run

```bash
cd apps/mac-desktop
bash dev.sh
```

`dev.sh` kills any existing Xisper instance, builds to `.build/Debug/Xisper.app`, opens it.

---

## Bundle ID → Backend Routing

| Env | Bundle ID | Backend | OAuth callback |
|-----|-----------|---------|----------------|
| Debug | `xyz.hawkeye-xb.xisper.mac` | `https://xisper-dev.hawkeye-xb.com` | `xisper-mac://` |
| Beta | `xyz.hawkeye-xb.xisper.beta` | `https://xisper-dev.hawkeye-xb.com` | `xisper://` |
| Release | `xyz.hawkeye-xb.xisper` | `https://xisper.hawkeye-xb.com` | `xisper://` |

Routing logic: `AuthManager.swift` — `serviceBaseURL` and `callbackScheme` computed from `Bundle.main.bundleIdentifier`.

---

## Known Broken Areas (Fix in this order)

### 1. OAuth Login

**What was recently fixed:**
- `Info.plist` was missing `CFBundleIdentifier = $(PRODUCT_BUNDLE_IDENTIFIER)` → bundle ID was `nil` at runtime — ALL bundle-ID-based routing was silently broken
- `exchangeToken()` was sending `{ code, codeVerifier }` → now sends `{ code, state, verifier }` (backend requires exact field names)
- `TokenResponse` fields made Optional to avoid JSON decode errors on error responses
- Backend `apps/services/src/routes/auth.ts` regex changed to `^xisper[-a-z]*:\/\/` to allow `xisper-mac://` — **DEV only (`xisper-dev.hawkeye-xb.com`), NOT deployed to production**
- Keychain service name fixed to `"xyz.hawkeye-xb.xisper"` (not bundle ID), added `kSecAttrAccessibleAfterFirstUnlock`
- Replaced `ASWebAuthenticationSession` (crashed on LSUIElement app) with `NSWorkspace.shared.open()` + `NSAppleEventManager` callback

**What to verify:**
1. Run app → click "Sign in with Browser" → browser opens → complete OAuth → browser redirects to `xisper-mac://auth/callback?code=...&state=...`
2. Check `AppDelegate.handleGetURL` fires — it calls `AuthManager.shared.handleAuthCallback(url:)`
3. Check `CheckedContinuation` in `login()` is resumed — if it hangs, login() never returns
4. Check `exchangeToken` HTTP response body — `TokenResponse.token` field name must match what backend returns
5. After login, `auth.userEmail` should be non-nil and `auth.isAuthenticated == true`

**Key files:** `Managers/AuthManager.swift`, `AppDelegate.swift`

---

### 2. Accessibility Permission Not Detected

**Symptoms:** User grants permission in System Settings, app stays stuck on PermissionsView.

**Root cause:** macOS ties accessibility trust to the app's **full disk path**. Different build paths = different trust entries.

**Fix:**
- Always use `bash dev.sh` — it always builds to `.build/Debug/Xisper.app` (consistent path)
- To reset: open System Preferences → Privacy & Security → Accessibility → remove ALL Xisper entries → run `dev.sh` → grant permission for the newly opened app

**Already implemented:**
- `PermissionsView` polls every 1s via `Timer.publish(every: 1, on: .main, in: .common).autoconnect()` — no manual refresh needed

**Key files:** `Managers/PermissionsManager.swift`, `Views/PermissionsView.swift`

---

### 3. FN/Globe Key Not Triggering Recording (depends on #2)

**Requires:** Accessibility permission granted first.

**Debug approach:**
1. Add `print("[KeyboardMonitor] event: \(type)")` in `KeyboardMonitor.handleEvent()`
2. Verify `HotkeySystem.shared.start()` is called (happens in `ContentView.onAppear`)
3. Verify `ConfigStore.shared.interceptSystemKey == true` (default should be true)
4. If CGEventTap fails to install without AX permission, `KeyboardMonitor.start()` returns silently

**Key files:** `Core/KeyboardMonitor.swift`, `Services/HotkeySystem.swift`

---

### 4. ASR WebSocket (depends on #1)

**URL:** `wss://xisper-dev.hawkeye-xb.com/api/v1/asr/proxy?token=<token>`

**Protocol:**
1. `sendStart` → JSON: `{ "signal": "start", "config": { ... } }`
2. `sendAudio` → Binary: PCM 16kHz Int16 little-endian frames
3. `sendFinish` → JSON: `{ "signal": "end" }`
4. Wait for → JSON: `{ "type": "final", "text": "transcribed text" }`

**Debug approach:** Add `print` in `ASRClient.connect()`, `sendStart()`, and the message receive handler.

**Key file:** `Services/ASRClient.swift`

---

### 5. Text Injection (depends on #2)

**Mechanism:** Clipboard snapshot → write text to clipboard → Cmd+V CGEvent → async restore clipboard (120ms delay).
Requires accessibility permission for `CGEventPost`.

**Key file:** `Services/InputWriter.swift`

---

## File Map

```
apps/mac-desktop/
├── dev.sh                              ← Always use this to build+run
├── project.yml                         ← xcodegen spec (edit this, not .xcodeproj directly)
└── Xisper/
    ├── XisperApp.swift                 ← @main, Sparkle (DEBUG: startingUpdater=false)
    ├── AppDelegate.swift               ← URL scheme handler ⚠️ verify fires on callback
    ├── ContentView.swift               ← Router: Auth → Permissions → MainView+Sidebar
    ├── Info.plist                      ← CFBundleIdentifier=$(PRODUCT_BUNDLE_IDENTIFIER), URL schemes
    ├── Xisper.entitlements             ← AX + microphone entitlements
    ├── Managers/
    │   ├── AuthManager.swift           ← PKCE OAuth ⚠️ main suspect for login issues
    │   ├── PermissionsManager.swift    ← AXIsProcessTrusted + AVCaptureDevice
    │   ├── ConfigStore.swift           ← UserDefaults prefs (NO ASR credentials — removed)
    │   └── HotwordsStore.swift         ← JSON file at ~/Library/Application Support/XisperHotwords/
    ├── Core/
    │   ├── KeyboardMonitor.swift       ← CGEventTap ⚠️ needs AX permission
    │   └── ContextBridge.swift         ← AX API (focused app info, selected text)
    ├── Services/
    │   ├── RecordingCoordinator.swift  ← State machine: idle→recording→finalizing→committing
    │   ├── AudioEngine.swift           ← AVAudioEngine → 16kHz Int16 PCM
    │   ├── ASRClient.swift             ← WebSocket to ASR proxy ⚠️ verify protocol
    │   ├── HotkeySystem.swift          ← KeyboardMonitor → RecordingCoordinator bridge
    │   ├── AudioController.swift       ← CoreAudio system mute during recording
    │   ├── InputWriter.swift           ← Cmd+V text injection ⚠️ needs AX permission
    │   ├── LLMPostprocessClient.swift  ← POST /api/v1/llm/postprocess (uses auth token)
    │   └── WebhookClient.swift         ← Fire-and-forget with 3-attempt backoff
    ├── Models/
    │   ├── TranscribeRecord.swift      ← SwiftData @Model
    │   └── HotwordItem.swift           ← Codable struct
    └── Views/
        ├── AuthView.swift              ← Sign in button + loading state + cancel
        ├── PermissionsView.swift       ← 1s timer polling for AX grant detection
        ├── HomeView.swift
        ├── HistoryView.swift
        ├── HotwordsView.swift
        ├── AnalyticsView.swift
        ├── LiveTranscribePanel.swift   ← Floating NSPanel subtitle overlay
        └── Settings/
            ├── SettingsView.swift      ← 3 tabs: Recording / Post-process / Webhook
            ├── PostprocessView.swift   ← Enable toggle + custom prompt only
            └── WebhookView.swift
```

---

## Backend Changes (DEV only — NOT production)

`apps/services/src/routes/auth.ts` — `redirect_uri` validation regex changed from hardcoded `xisper://` + `xisper-dev://` to `^xisper[-a-z]*:\/\/` to allow `xisper-mac://` scheme.
**Deployed to `xisper-dev.hawkeye-xb.com` only.**

---

## xcodegen

After editing `project.yml`:
```bash
cd apps/mac-desktop && xcodegen generate
```

---

## Do NOT Touch

- `apps/desktop/` — Electron app (still running, untouched)
- `apps/web/` — Vue frontend
- `packages/keyboard-monitor/` — Swift dylib for Electron
- `packages/native-context/` — Swift dylib for Electron
- `apps/services/` — Cloudflare Workers (only `auth.ts` was touched, DEV only)
