# DTL App PoC — Roadmap

> Planning phase, **roadmap step only** (2026-06-24). Milestones ordered **by risk** — hardest /
> most uncertain first — per brainstorm decision **A2** (feasibility vertical slice).
> Detailed per-milestone plans are written later, **one at a time, just before each milestone is
> built**; each is reviewed before any code is written (CLAUDE.md two-tier gate).
>
> Scope = the **5 core features only** (branding · home page · OIDC auth · device-bound mTLS ·
> app-level wipe) + a supporting **mock backend**. No DLP, no mobile, no real PKI, no production
> backend. Sources of truth: `docs/techstack.md` (tech decisions + gotchas) and `docs/brainstorm.md`
> (scope + decisions log).

## Risk order — why this sequence

The two constraints most likely to sink the PoC are proven **first**, before any UI exists:

1. **Per-domain client-cert mTLS inside the embedded WebView** — the feature that ruled out
   Tauri/Wails (WebKitGTK has no programmatic Linux client-cert path; techstack §1). Must prove on
   Electron/Ubuntu.
2. **A wipe that also deletes the client cert from the OS store** (NSS), not just Electron data.
   techstack §2 is blunt: "clearing only Electron's data leaves the OS-store cert intact → the wipe
   fails its purpose." Prove early.

Everything after is progressively lower-risk: locked UI (standard Electron) → OIDC (well-trodden,
system-browser flow) → management plane + signed kill (the wipe it triggers is already proven in
M0) → packaging (mechanical).

## Three rebuild-risks to design against from day one (techstack §5)

These are the "get it right now or pay later" items; they map directly onto the milestones:

1. **Wipe must delete the OS-store cert**, not just Electron APIs → proven in **M0**.
2. **OIDC login in the system browser, never inside the WebView** (insecure + audit rework) → **M2**.
3. **The desktop codebase will not port to iOS** (iOS forces WKWebView). Not a mobile build — just
   keep the security logic (allow-list, signed-kill verification, token handling, OIDC flow)
   **decoupled from the Electron UI** so it could be reused if a mobile track ever starts. Cheap
   structuring, not a new abstraction layer (KISS).

## Cross-cutting constraints (every milestone)

- **Process separation:** all OS / Node work (cert selection, NSS / Windows-store wipe, token
  storage) lives in the **Main process**; the portal renderer is isolated — `contextIsolation:true`,
  `sandbox:true`, `nodeIntegration:false`, `webviewTag:false`; expose only a **narrow preload API via
  `contextBridge`**; validate all IPC + navigation; **never disable `webSecurity`**.
- **Embedding:** `WebContentsView` on `BaseWindow`. For a single full-window kiosk a plain
  `BrowserWindow` is also acceptable (techstack §2) — `BaseWindow` vs `BrowserWindow` is a
  *reversible* call settled in the M1 plan. **Never** the `<webview>` tag or `BrowserView`.
- **Certs:** provision via external **`pk12util` / `certutil`** only — **never**
  `app.importCertificate` (broken on Linux: no SSL trust bit, segfaults — #32816/#32825/#25506).
  Electron only *selects* certs (`select-client-certificate`), never *imports* them.
- **OIDC:** system browser + PKCE + loopback redirect (RFC 8252) — **never** embedded in the WebView.
- **Tooling:** Electron **42.x** (pin one major; Chromium 148 / Node 24 as of 2026-06-24);
  **`electron-vite`** (dev/build, secure defaults) + **`electron-builder`** (packaging).

---

## M0 — SPIKE: mTLS-per-domain + cert wipe on Ubuntu (highest risk · no UI)

- **Goal:** In a minimal Electron program, prove the two hardest constraints before building any UI.
- **Proves:** (a) a WebView presents the device client cert to a *designated* HTTPS domain via
  `app.on('select-client-certificate', (e, wc, url, list, cb) => …)` (scope by `url`,
  `e.preventDefault()` + `cb(cert)`) and the server accepts the handshake; (b) the wipe removes that
  cert from the OS store (NSS) so the WebView can no longer authenticate.
- **Stands up (kept as a permanent test fixture):** per techstack §3 — an OpenSSL self-signed CA +
  server cert (with `subjectAltName`) + client cert `CN=DTL-Ubuntu-Test-Device`
  (`extendedKeyUsage=clientAuth`); local **nginx** with `ssl_client_certificate` + `ssl_verify_client
  on`; CA imported into NSS via `certutil -A` (trust bits), client cert via `pk12util -i client.p12`
  (`~/.pki/nssdb`, needs `libnss3-tools`); a bare Electron main loading the URL into one WebView.
- **Depends on:** nothing — first milestone.
- **Done when:**
  1. Electron loads the protected page; the handler presents `CN=DTL-Ubuntu-Test-Device` **only**
     for the designated domain and the mTLS handshake succeeds (page renders). If it fails with
     `ERR_BAD_SSL_CLIENT_AUTH_CERT`, confirm the full chain is sent (#28553; verify with Wireshark).
  2. A non-designated domain receives **no** cert (`cb()` empty) — proving "mTLS for *certain*
     websites," not all traffic.
  3. The wipe deletes the cert from NSS (`pk12util -F` / `certutil -D`) **and** clears Electron data
     (`session.clearStorageData` + `clearCache` + `clearAuthCache`); `certutil -L` confirms it gone.
  4. After wipe + reload the same page **fails** the handshake — proving the wipe truly locks the app
     out, not merely cleared cookies.
  5. The manual `pk12util` re-injection script restores the cert and access (confirms the D4
     out-of-band recovery path).

## M1 — Kiosk shell: branding + home page + default-deny allow-list (lower risk)

- **Goal:** Turn the spike into the locked single-purpose shell the user sees.
- **Delivers:** the window structure (recommended `BaseWindow` + `WebContentsView`; plain
  `BrowserWindow` acceptable for single-window — decide in the M1 plan); in-app DTL branding (logo,
  product name, window title); home page = the internal portal URL; **default-deny allow-list** via
  `will-navigate` / `will-redirect` (block top-level nav outside the list) + `setWindowOpenHandler`
  (deny new windows/tabs) — same-window nav, no address bar / tabs / bookmarks / history. (OS-level
  branding — app icon, desktop entry — lands in M4.)
- **Depends on:** M0 (reuses the Electron harness; cert handler carried forward, not the focus here).
- **Done when:**
  1. App opens directly to the configured home URL in a locked window — no address bar, tabs,
     bookmarks, or history menu.
  2. DTL branding visible (logo + product name); app/window identity reads as DTL, not "Electron."
  3. Allow-listed navigation succeeds in the same window; any nav / redirect / pop-up to a
     non-allow-listed domain is **blocked** (default-deny) and observable.
  4. Renderer lockdown verified (`contextIsolation`/`sandbox`/`nodeIntegration:false`/`webviewTag:false`,
     narrow preload, `webSecurity` on); no Node reachable from the portal view.

## M2 — Custom OIDC authentication (system browser + PKCE)

- **Goal:** Gate app launch behind DTL identity via OIDC, with login in the system browser.
- **Delivers:** OIDC Authorization-Code + PKCE against a **local Zitadel test instance** (E1), using
  **`openid-client` in the main process** + `shell.openExternal` for login + a temporary **loopback
  listener** for the authorization code (RFC 8252); tokens held **main-process only**, OS-encrypted
  via `safeStorage`; silent refresh; re-auth on failure; portal unreachable until authenticated.
- **Depends on:** M1 (a shell to gate); local Zitadel in Docker. Independent of mTLS (E2 — layered).
- **Done when:**
  1. On launch the user is sent to Zitadel in the **system browser**; on success control returns via
     the loopback redirect and the shell loads the portal.
  2. The login UI is **never** rendered inside the WebView.
  3. Tokens live only in the main process via `safeStorage`; the renderer cannot read them. Check
     `safeStorage.getSelectedStorageBackend()` — the headless `dshell` likely falls back to
     `basic_text` (unencrypted), so also verify on a **real Ubuntu desktop** (techstack §2).
  4. Token expiry triggers silent refresh; refresh failure forces re-auth; no valid token ⇒ no portal.

## M3 — Management control plane (mock) + signed kill switch

- **Goal:** Stand up the local control plane and wire the M0-proven wipe to a signed remote kill.
- **Delivers:** a tiny local **mock backend** serving config + a kill flag (distinct from M0's mTLS
  *resource* server); the app **polls / heartbeats**; the kill command is **signed (Ed25519)** and
  verified against a **pinned public key baked into the app** — never accept an unsigned command
  (techstack §3); a valid kill runs the full M0 wipe (cert + tokens + cookies + cache + localStorage),
  demonstrated by lockout from the M0 mTLS fixture + portal.
- **Depends on:** M0 (wipe + cert handler + mTLS fixture), M1 (UI to observe), M2 (tokens to wipe).
- **Done when:**
  1. The app polls the mock backend; flipping the kill flag (manual / admin trigger, F5) is picked up
     within one poll interval.
  2. Only a **correctly signed** command triggers the wipe; an unsigned / tampered command is rejected
     with no wipe.
  3. On a valid kill the full wipe runs (incl. the OS-store cert per M0) and the app is locked out of
     the mTLS fixture and the portal.
  4. Build-time config (allow-list, home URL, mTLS domains, branding) is sourced as designed (baked-in
     acceptable per G3); the kill flag is the one live signal.

## M4 — Ubuntu packaging: AppImage (+ optional .deb), unsigned

- **Goal:** Produce a runnable Ubuntu build of the full vertical slice — the second half of the DoD.
- **Delivers:** `electron-builder` config → **AppImage** (primary) + optional **.deb**; OS-level
  branding (app icon, desktop entry); documented run + cert-provisioning steps; **unsigned** (no
  code-signing, per techstack §2 / I2).
- **Depends on:** M1–M3 (packages the integrated app).
- **Done when:**
  1. A clean build command emits an AppImage (and optionally a `.deb`).
  2. Launched from the AppImage on a clean-ish Ubuntu, all features work end-to-end: OIDC login →
     branded kiosk shell → mTLS to the test fixture → signed remote wipe (incl. the OS-store cert).
  3. README documents install, the out-of-band `pk12util` cert-provisioning step, and how to trigger
     the kill switch.

---

## Secondary target (not a gated milestone)

**Windows** is the secondary platform. Same Electron codebase; the only OS-specific deltas are the
**cert store** (Windows `CurrentUser\My` via `certutil -importpfx` / `Import-PfxCertificate`, plus a
Windows-store delete in the wipe) and **packaging** (NSIS). Per the DoD (B), the gated PoC target is
the **Ubuntu** test build; Windows is validated only after Ubuntu works end-to-end.

**Mobile / macOS** remain tabled. Reminder (techstack §4): iOS forces WKWebView — the Electron codebase
**will not port**, so mobile would be a separate track. The day it returns, the long pole is iOS
WKWebView mTLS (its own spike). The cross-cutting "decouple security logic from UI" note above is the
only concession made now.

## Explicitly out of scope (carried from brainstorm)

DLP (download / DevTools / copy-paste / screenshot blocking) · real PKI & in-app cert
re-provisioning (D4) · true device uninstall / MDM · production management backend · code-signing ·
auto-update · mobile & macOS.
