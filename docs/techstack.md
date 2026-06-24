# Tech Stack — DTL App PoC

> Single source of truth for technology choices and their rationale.
> Referenced by `CLAUDE.md` and `docs/brainstorm.md` (which no longer duplicate this).
> Validated via research on 2026-06-24. This is a decision / reference record — detailed
> architecture and implementation belong to the **Plan phase (not yet started, gated)**.

## Bottom line

- **Electron is the right desktop framework** for Ubuntu + Windows. Re-checked against the
  2026 alternatives; it remains the lowest-risk choice for the project's hardest requirement
  (per-domain client-certificate mTLS working identically on both OSes).
- **One mandatory correction:** do **NOT** provision client certificates via Electron's
  `app.importCertificate()` — it is broken on Linux (does not set the NSS SSL trust bit; can
  segfault). Provision via external OS tools (`pk12util` / `certutil`).
- **The biggest "rebuild" risk is mobile, not desktop:** iOS forces WKWebView, so an Electron
  desktop codebase will not port to iOS / Android. With the current desktop-first scope this
  is fine, but it must be a conscious architectural expectation, not a surprise later.

## 1. Framework choice

**Decision: Electron.** Reasons: one bundled Chromium on both Ubuntu and Windows (identical
TLS / rendering behaviour — critical for a security app), a mature programmatic per-domain
client-cert API, and a JS/TS ecosystem matching the team's skills (Next.js / Django background).

Comparison (re-opened with 2026 data):

| Framework | Engine (Linux / Windows) | Programmatic per-domain client-cert mTLS | Verdict |
|---|---|---|---|
| **Electron** ✅ | Chromium / Chromium (bundled, identical) | Yes — `app.on('select-client-certificate')`, scope by `url` | **Chosen** — engine parity + JS/TS fit |
| Qt / QtWebEngine | Chromium / Chromium | Yes — `QWebEnginePage::selectClientCertificate` (+ programmatic cert store) | Strongest runner-up, but C++/Python ≠ team skills; licensing |
| Tauri v2 | WebKitGTK / WebView2 (divergent) | No programmatic client-cert in the Linux webview | Rejected — Linux mTLS gap; Rust backend |
| Wails v2/v3 | WebKitGTK / WebView2 (divergent) | Same Linux gap | Rejected — v3 still alpha |
| .NET MAUI / Avalonia | weak / none on Linux | No reliable cross-OS webview mTLS | Rejected |
| Flutter desktop | non-core webview; immature | unproven on desktop backends | Rejected for desktop |

The earlier "Tauri / Wails on Linux WebKitGTK lack a programmatic client-cert path" reasoning
**still holds in 2026**. Qt is the only real technical runner-up (it can even delete certs
programmatically), but switching off JS/TS is not worth it for a PoC.

## 2. Electron specifics

**Version / support.** Latest stable as of 2026-06-24 is Electron 42.5.0 (Chromium 148,
Node 24). Electron supports the latest 3 majors, with a new major roughly every 8 weeks. Pin
one major (e.g. 42.x) and plan periodic upgrades — a fixed maintenance cost, not a rebuild risk.

**mTLS (the linchpin).** Use `app.on('select-client-certificate', (event, webContents, url, list, callback) => …)`.
The `url` argument identifies the requesting server, so use it to **scope per-domain** (present
a cert only for the mTLS allow-list). Call `event.preventDefault()` then `callback(cert)`. The
OS holds the private key and signs (NSS `~/.pki/nssdb` on Ubuntu, the Windows cert store on
Windows), so the key can be non-exportable (device-bound).
- Known bugs to watch: **#28553** (a self-selected cert may not send the full chain →
  `ERR_BAD_SSL_CLIENT_AUTH_CERT`; ensure the chain is in NSS, verify with Wireshark);
  **#32816 / #32825 / #25506** (`app.importCertificate` broken / segfaults on Linux).
- Best practice: **never `app.importCertificate`; provision via `pk12util` / `certutil`** (see §3).
  Electron should only *select* certs, never *import* them.

**Web embedding.** Use `WebContentsView` (with `BaseWindow`) — official since Electron 30.
`BrowserView` is deprecated; the `<webview>` tag is discouraged. For a single full-window
kiosk, a plain `BrowserWindow` is also acceptable. Lock navigation with `will-navigate` (block
top-level navigations outside the allow-list) and `setWindowOpenHandler` (deny new windows /
tabs) — default-deny.

**Remote wipe (with the critical gotcha).** Clear Electron data (`session.clearStorageData`,
`clearCache`, `clearAuthCache`), clear stored tokens (safeStorage), **and** delete the client
cert from the OS store. On Ubuntu (NSS) use **`certutil -F -n <nickname> -d sql:$HOME/.pki/nssdb`**
to remove the private key *and* its certificate (`certutil -D` removes only the cert; note that
`pk12util` only imports / exports and **cannot delete**). On Windows, use `certutil -delstore` /
PowerShell `Remove-Item Cert:\CurrentUser\My\<thumbprint>`. **Clearing only Electron's data leaves
the OS-store cert intact → the wipe fails its purpose.** This is a must-prove constraint; prove it early.

**Token storage.** `safeStorage.encryptString` / `decryptString`, main-process only,
OS-encrypted. Caveat: on headless Linux without a secret store it falls back to a `basic_text`
backend (effectively unencrypted) — check `safeStorage.getSelectedStorageBackend()`. The
`dshell` dev container likely hits this; also test token storage on a real Ubuntu desktop.

**Build / packaging.** `electron-vite` (build / dev, HMR, secure defaults) + `electron-builder`
(packaging + auto-update). Linux: AppImage + `.deb`; Windows: NSIS. Code-signing not needed for
the PoC.

**Security defaults (from day one).** `contextIsolation: true`, `nodeIntegration: false`,
`sandbox: true`; expose only a narrow preload API via `contextBridge`; validate all IPC and
navigation; never disable `webSecurity`.

## 3. Libraries for the Plan phase (recommendations — not yet built)

**OIDC (Zitadel for the PoC → Google Workspace later).** Follow RFC 8252 (OAuth 2.0 for Native
Apps): use the **system browser + PKCE + loopback redirect**, not an embedded IdP login inside
a webview. Recommended: `openid-client` in the main process + `shell.openExternal` for login +
a temporary loopback listener for the authorization code. Because login happens in the system
browser, it sits outside the kiosk and does not break the allow-list. Swapping Zitadel → Google
later is just configuration (reversible).

**Local mTLS test server.** DTL's internal apps are currently plain HTTP behind one nginx
reverse proxy; for the PoC, stand up an HTTPS + mTLS branch locally: an OpenSSL self-signed CA
+ a server cert (with `subjectAltName`) + a client cert `CN=DTL-Ubuntu-Test-Device`
(`extendedKeyUsage=clientAuth`); nginx `ssl_client_certificate` + `ssl_verify_client on`. Import
into NSS: `certutil -A` for the CA (with trust bits) and `pk12util -i client.p12` for the client
cert / key (needs `libnss3-tools`).

**Mock backend + kill switch.** A small local endpoint serving config + a kill flag; the app
polls / heartbeats. The kill command must be **signed** (e.g. Ed25519) and verified against a
**pinned public key** baked into the app — never accept an unsigned kill command. A valid kill
flag triggers the wipe sequence in §2 (including OS-store cert deletion).

## 4. Mobile forward-look (tabled)

- **iOS forces WKWebView (WebKit)** — you cannot ship Chromium / Electron. (The EU DMA
  alternative-engine carve-out is EU-only and effectively unused — irrelevant for a Singapore
  deployment.) So the Electron desktop codebase **will not port to iOS / Android**; expect a
  separate mobile track.
- **mTLS in mobile WebViews:** iOS via `WKNavigationDelegate` `didReceive challenge` + a
  client-cert `URLCredential` (cert imported into the app keychain; historically buggy pre-iOS
  12, fine since). Android via `WebViewClient.onReceivedClientCertRequest` + `KeyChain` — well
  supported and easier than iOS.
- **Cross-platform options:** `flutter_inappwebview` is the only one with a first-party
  cross-platform client-cert API, strongest on Android, less proven on iOS / desktop.
  `react-native-webview` does **not** support mTLS; Capacitor / Ionic need a custom native plugin.
- **Recommendation:** accept **two tracks** (Electron desktop + a separate mobile build later);
  do **not** switch desktop to an all-five-platforms framework now — it would weaken desktop
  mTLS. If mobile later becomes co-priority, the most plausible unifier is Flutter +
  `flutter_inappwebview`, contingent on its own iOS mTLS spike. To avoid a corner: keep security
  logic (allow-list, signed kill-switch verification, token handling, OIDC flow) decoupled from
  the Electron UI so the *logic* can be reused even if the *UI* is rewritten.

## 5. Rebuild risks vs reversible details

**Real rebuild risks (get these right now):**
- Designing the wipe around only Electron APIs and forgetting the OS cert store.
- Embedding IdP login inside the webview instead of the system browser (insecure + audit rework).
- Treating the desktop codebase as portable to iOS.

**Reversible (safe to decide later / change cheaply):** `BaseWindow` vs `BrowserWindow`;
`openid-client` vs `AppAuth-JS`; the Zitadel → Google issuer swap; the specific Electron major.

## Validation log

- **2026-06-24** — Stack validated via research. Electron confirmed correct for desktop;
  Electron 42.5.0 (Chromium 148, Node 24). Key correction recorded: provision certs via
  `pk12util` / `certutil`, not `app.importCertificate`. Embedding primitive confirmed:
  `WebContentsView` (+ `BaseWindow`), not the `<webview>` tag / `BrowserView`.