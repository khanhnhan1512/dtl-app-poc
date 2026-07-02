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
  3. The wipe deletes the cert+key from NSS (`certutil -F -n <nickname> -d sql:$HOME/.pki/nssdb` —
     removes the private key **and** its cert; `certutil -D` would remove only the cert) **and** clears
     Electron data (`session.clearStorageData` + `clearCache` + `clearAuthCache`); `certutil -L`
     and `certutil -K` confirm both are gone.
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

## M4 — Linux MVP: device+user session surfacing + .deb packaging

- **Goal:** Complete the Linux PoC as a shippable MVP — both identity layers observable in one place,
  and a distributable `.deb` package.
- **Delivers:** a `[session]` log line fired on the portal's `did-finish-load` event that surfaces
  `device=<CN>` (from the mTLS cert) and `user=<email>` (from the OIDC token) together — observability
  of the layered identity, not cryptographic binding (that is a post-PoC hardening item);
  `electron-builder` config → **.deb**; OS-level branding (app icon, `.desktop` entry); documented
  install + cert-provisioning steps; **unsigned** (no code-signing per I2).
- **Depends on:** M1–M3 (packages the fully integrated app).
- **Done when:**
  1. Portal load emits `[session] device=DTL-Ubuntu-Test-Device user=testuser@dtl.local` — both
     identity layers visible in a single log line (D-M4-4: log-line surfacing, not UI rendering).
  2. A clean build command emits a `.deb`.
  3. Launched from the `.deb` on a clean Ubuntu, all features work end-to-end: OIDC login → branded
     kiosk shell → mTLS to the test fixture → signed remote wipe (incl. OS-store cert).
  4. README documents install, out-of-band `pk12util` cert-provisioning, and how to trigger the kill.

---

## Desktop platform track — M5 + M6 (one Electron codebase, two OS seams)

The desktop app is **one Electron codebase**. Only two seams vary per OS: the cert store adapter and
the packaging target. All app logic — OIDC flow, kiosk shell, allow-list, kill switch, `contracts/`
wire formats — is **shared unchanged** across Linux, Windows, and macOS.

M5 is the natural point to formalize a small **`CertStore` interface** (three methods: `present(url)`,
`select(cert)`, `delete(nickname)`) with the NSS/`certutil` impl (Linux, already exists) and a Windows
impl. M6 adds the third impl (macOS Keychain). Deferring this abstraction until a second real platform
exists is correct YAGNI discipline.

## M5 — Windows integration + .exe packaging

- **Goal:** Port the Linux PoC to Windows — same Electron codebase, Windows cert-store adapter and
  NSIS installer.
- **Cert store seam:** mTLS client cert lives in the **Windows Certificate Store** (`CurrentUser\My`);
  provision via `certutil -importpfx` / `Import-PfxCertificate`; wipe path deletes from the Windows
  store (the Windows analogue of Linux `certutil -F -n ... -d sql:~/.pki/nssdb`).
- **Packaging seam:** `electron-builder` NSIS target → **`.exe` installer**, unsigned.
- **Formalize `CertStore` interface:** introduce a small adapter (present / select / delete) with an
  NSS impl (wraps existing Linux code) and a Windows impl. No other layer changes.
- **Depends on:** M4 (Linux MVP verified end-to-end).
- **Done when:**
  1. The Windows cert-store adapter provisions, presents (mTLS handshake succeeds), and deletes
     (wipe locks out) the device cert — matching the M0 Linux acceptance criteria on Windows.
  2. `.exe` installer produced; all M1–M4 features work end-to-end on Windows.
  3. `CertStore` interface is clean: swapping the adapter does not touch app logic.

## M6 — macOS integration + .dmg packaging

- **Goal:** Add macOS as the third desktop target — Keychain adapter and `.dmg`.
- **Note:** macOS is on the **desktop/Electron track**, not the mobile track. A common misgrouping
  lumps macOS with iOS; they are separate: iOS prohibits Chromium entirely (WKWebView only) — a
  different codebase. macOS runs Electron normally.
- **Cert store seam:** client cert/identity stored in the **macOS Keychain**; wipe path deletes from
  Keychain — the third `CertStore` implementation.
- **Packaging seam:** `.dmg`, unsigned (notarization / code-signing deferred as a hardening item).
- **Depends on:** M5 (`CertStore` interface already formalized).
- **Done when:**
  1. macOS Keychain adapter provisions, presents (mTLS handshake succeeds), and deletes (wipe locks
     out) the device cert.
  2. `.dmg` produced; all M1–M4 features work end-to-end on macOS.

---

## Mobile track (separate codebase — not a desktop extension)

iOS prohibits Chromium → the Electron codebase **will not port to iOS**. Mobile is a **separate
codebase** if it ever begins. Flutter is a candidate unifier (pending an iOS WKWebView mTLS spike —
that is the long pole: iOS mTLS client-cert selection via `WKURLSchemeHandler` / `URLSession` is
largely untrodden).

The true shared artifact across desktop and mobile is the **`contracts/` layer** (language-neutral wire
formats — `kill-command.md` is the first). *Not* shared TypeScript; the contracts describe what any
platform must implement, not how.

## Explicitly out of scope (carried from brainstorm)

DLP (download / DevTools / copy-paste / screenshot blocking) · real PKI & in-app cert
re-provisioning (D4) · true device uninstall / MDM · production management backend · code-signing ·
auto-update · iOS / Android.
