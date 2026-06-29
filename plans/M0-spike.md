# M0 — SPIKE Plan: per-domain mTLS in the WebView + cert wipe (Ubuntu)

> Detailed plan for **Milestone M0** of `plans/roadmap.md`. **Planning only — no code yet.**
> Per the CLAUDE.md two-tier gate, this plan is reviewed and approved *before* any code is written.
> Sources: roadmap M0 · techstack §1–3 · brainstorm D1–D4 / F3. Commands verified 2026-06-24
> (host has `openssl 3.0.13`, `certutil`, `pk12util`; deletion semantics confirmed against NSS docs).

## Goal

In the smallest possible Electron program — **no UI beyond one window** — prove on Ubuntu the two
constraints that decide whether the whole PoC is viable: (1) the embedded WebView presents the
device client certificate to **only a designated** HTTPS domain and the server accepts the mTLS
handshake; and (2) the app-level wipe deletes that certificate **from the OS store (NSS)**, not just
Electron's data, so the WebView can no longer authenticate after a wipe. Branding, allow-list UI,
OIDC, and the management backend are explicitly **out of M0** — they are later milestones.

## Acceptance criteria (restated from roadmap M0)

1. Electron loads the protected page; the handler presents `CN=DTL-Ubuntu-Test-Device` **only** for
   the designated domain and the mTLS handshake succeeds (page renders, `verify=SUCCESS`).
2. A **non-designated** domain receives **no** cert (`callback()` empty) — proving "mTLS for *certain*
   websites," not all traffic.
3. The wipe deletes the cert **and** key from NSS
   (`certutil -F -n <nickname> -d sql:$HOME/.pki/nssdb` — removes the private key **and** its cert;
   `-D` would remove only the cert and orphan the key) **and** clears Electron session data;
   `certutil -L` and `certutil -K` confirm both are gone.
4. After wipe + reload the same page **fails** the handshake — proving the wipe truly locks the app
   out, not merely cleared cookies.
5. A manual out-of-band re-injection script (`pk12util -i`) restores the cert and access (the D4
   recovery path; the app never self-provisions).

## Prerequisites & key gotchas

- **Display:** Electron needs a display server. `dshell` is headless → run the GUI check on a **real
  Ubuntu desktop** or under **`xvfb-run -a`**. The TLS handshake itself is display-independent; only
  the render check needs a display.
- **NSS tooling:** `libnss3-tools` installed; the shared DB `sql:$HOME/.pki/nssdb` exists (it already
  does on the host).
- **nginx** available locally to bind `localhost:8443` / `:8444` (system package or a throwaway
  container — decide at implementation).
- **NEVER `app.importCertificate`** (broken on Linux — no SSL trust bit, segfaults; #32816/#32825/
  #25506). All provisioning **and** deletion go through `pk12util` / `certutil`. Electron only
  *selects* certs.
- **#28553 (full-chain risk):** a selected client cert may not send its full chain →
  `ERR_BAD_SSL_CLIENT_AUTH_CERT`. Ensure the CA is present in NSS; if it still fails, capture the
  handshake with **Wireshark** to confirm what actually left the client.
- **`preventDefault()` is mandatory:** without it Electron silently sends `certificateList[0]`,
  defeating per-domain scoping. Always call it in the handler.

## Architecture (M0 shape)

- **Main process owns all privilege:** the `select-client-certificate` handler and the wipe (which
  spawns `certutil`) live in Main. The renderer is a locked, isolated view that only loads a remote
  URL.
- **Window:** a plain `BrowserWindow` (acceptable for a single full-window case per techstack §2;
  `BaseWindow` + `WebContentsView` is an M1 decision) with `webPreferences`:
  `contextIsolation:true`, `sandbox:true`, `nodeIntegration:false`, `webviewTag:false`.
- **Two local endpoints prove "certain websites only":** `:8443` designated (`ssl_verify_client on`)
  and `:8444` non-designated (`ssl_verify_client optional`, so it reports `verify=NONE` when no cert
  is sent rather than hard-failing).
- **`wipe()` is a standalone, UI-agnostic module** so M3's signed kill switch calls the *exact same*
  function — only the trigger differs.

## Sub-steps (ordered: setup → retire risk #1 → retire risk #2 → recovery)

### Step 1 — Initialise the Electron project (electron-vite, vanilla)

- **Scaffold:** `npm create @quick-start/electron@latest <app> -- --template vanilla` (the alex8088
  `electron-vite`; **not** `npm create electron-vite`, a different project). Pin Electron **42.x**.
- **Files to create** (template output; trim to the load-bearing set):
  - `package.json` — Electron 42.x + electron-vite; `dev`/`build` scripts; `"main": "./out/main/index.js"`.
  - `electron.vite.config.mjs` — main/preload/renderer build config.
  - `src/main/index.js` — main entry (expanded in Steps 3–4).
  - `src/preload/index.js` — minimal `contextBridge` preload; **no privileged API in M0**.
  - `src/renderer/index.html` (+ `src/renderer/src/*`) — scaffolded but **unused in M0** (we load a
    remote URL); may be trimmed.
  - `.gitignore` — `node_modules/`, `out/`.
- **Verify:** `npm run dev` opens one window with no console errors; app boots and quits cleanly.

### Step 2 — Stand up the mTLS test lab (OS-level; no Electron yet)

- **Files to create** (under `lab/`):
  - `lab/certs/gen-certs.sh` — OpenSSL chain: root CA `CN=DTL-Test-Root-CA`; **server cert with
    `subjectAltName=DNS:localhost,IP:127.0.0.1`** (modern Chromium ignores CN, requires SAN);
    **client cert `CN=DTL-Ubuntu-Test-Device` with `extendedKeyUsage=clientAuth`** (+ `keyUsage=
    digitalSignature`); bundle client key+cert into `client.p12` with `-name "DTL-Ubuntu-Test-Device"`
    (this becomes the NSS nickname). Note: `x509 -req` does **not** copy CSR extensions — re-state
    SAN/EKU via `-extfile`.
  - `lab/certs/server.ext`, `lab/certs/client.ext` — the SAN / EKU extension files.
  - `lab/nginx/mtls.conf` — two server blocks: **`:8443` `ssl_verify_client on`** (designated) and
    **`:8444` `ssl_verify_client optional`** (non-designated). Both set `ssl_certificate`/`_key` =
    server cert, `ssl_client_certificate` = `ca.pem`; the `location /` echoes
    `verify=$ssl_client_verify subject=$ssl_client_s_dn` so the page proves whether a cert was accepted.
  - `lab/provision-nss.sh` — `certutil -A -n "DTL-Test-Root-CA" -t "CT,C,C" -a -i ca.pem
    -d sql:$HOME/.pki/nssdb`, then `pk12util -i client.p12 -d sql:$HOME/.pki/nssdb`. Idempotent;
    checks for `libnss3-tools`. (Trust string `CT,C,C` = SSL-position CA for both server- and
    client-cert issuance; one CA signs both here.)
  - `lab/README.md` — run order: gen-certs → start nginx → provision-nss.
- **Verify (independent of Electron — retires the lab risk first):**
  - `certutil -L -d sql:$HOME/.pki/nssdb` lists the CA + `DTL-Ubuntu-Test-Device`; `certutil -K` lists
    the key.
  - `curl -v --cacert ca.pem --cert client.crt --key client.key https://localhost:8443/` →
    `verify=SUCCESS subject=…CN=DTL-Ubuntu-Test-Device`.
  - `curl --cacert ca.pem https://localhost:8443/` (no client cert) → `400 No required SSL certificate`.
  - `curl --cacert ca.pem https://localhost:8444/` (no client cert) → `200 verify=NONE`.

### Step 3 — Electron main: load protected URL + per-domain cert selection (retires risk #1)

- **Files to create / expand:**
  - `src/main/config.js` — baked-in config (per G3): `PROTECTED_URL="https://localhost:8443"`,
    `MTLS_ALLOWLIST=["localhost:8443"]`, the cert match (subject `CN=DTL-Ubuntu-Test-Device`),
    `CERT_NICKNAME="DTL-Ubuntu-Test-Device"`. Target URL overridable (env/arg) so the same build can
    be pointed at `:8444` for criterion 2.
  - `src/main/cert-select.js` — exports the handler
    `(event, webContents, url, certificateList, callback)`: **always** `event.preventDefault()`; if
    `new URL(url).host` ∈ `MTLS_ALLOWLIST` → pick the matching entry from `certificateList` by
    `subjectName` → `callback(cert)`; else `callback()` (decline — no cert sent).
  - `src/main/index.js` — register `app.on('select-client-certificate', handler)` at startup
    **before** creating the window / `loadURL` (it's an app-level event); create the `BrowserWindow`
    with the secure `webPreferences` above; `loadURL(PROTECTED_URL)`.
- **Verify:**
  - Launch on a real desktop (or `xvfb-run -a npm run dev`): window renders
    `verify=SUCCESS … CN=DTL-Ubuntu-Test-Device` from `:8443` → **criterion 1**.
  - Point the target URL at `https://localhost:8444` → renders `verify=NONE` (handler declined for the
    non-allow-listed host) → **criterion 2**.
  - If `:8443` fails with `ERR_BAD_SSL_CLIENT_AUTH_CERT` → #28553: confirm the CA is in NSS
    (`certutil -L`); if still failing, capture with **Wireshark** to see what left the client.

### Step 4 — Reusable wipe module + M0 trigger (retires risk #2)

- **Files to create:**
  - `src/main/wipe.js` — exports `async wipe()`, **UI-agnostic** (no window/dialog deps), runs in
    **Main**: (a) Electron data — `session.defaultSession.clearStorageData()` + `clearCache()` +
    `clearAuthCache()`; (b) OS cert — spawn
    `certutil -F -n "DTL-Ubuntu-Test-Device" -d sql:$HOME/.pki/nssdb` (deletes key+cert in one shot;
    **not** `-D`, which orphans the key; **never** `app.importCertificate`). Returns a result / throws
    on failure.
  - `src/main/index.js` — if `process.argv` includes `--wipe`: run `wipe()`, log the outcome,
    `app.quit()`. **M0 trigger only**; M3 replaces this trigger with the signature-verified kill
    command, calling the *same* `wipe()`.
  - `package.json` — a `"wipe"` script (`electron . --wipe`) for convenience.
- **Verify:**
  - Pre: `certutil -L` / `-K` show cert+key; `:8443` renders `SUCCESS`.
  - Run wipe → `certutil -L` no longer lists `DTL-Ubuntu-Test-Device` **and** `certutil -K` no longer
    lists its key → **criterion 3** (both gone — proves `-F`, not `-D`).
  - Relaunch → `:8443` fails the handshake (no cert to present) → **criterion 4**.

### Step 5 — Out-of-band re-injection (recovery; proves D4)

- **Files to create:**
  - `lab/reprovision-cert.sh` — re-imports the client cert+key:
    `pk12util -i lab/certs/client.p12 -d sql:$HOME/.pki/nssdb`. (The wipe removes only the client
    nickname, so the CA survives — only the `.p12` needs re-injecting. DRY: same import step as
    `provision-nss.sh`.)
- **Verify:** after a wipe, run the script → `certutil -L` / `-K` show cert+key restored → relaunch
  Electron → `:8443` renders `SUCCESS` again → **criterion 5** (manual recovery works; app never
  self-provisions).

## Risk assessment

- **R1 (highest) — Electron doesn't surface the NSS cert / handshake fails** (#12069, #28553). The
  reason M0 exists. Mitigation: prove the lab with `curl` first (Step 2), confirm `certutil -L`,
  Wireshark if needed.
- **R2 — headless `dshell` can't render an Electron window.** Mitigation: `xvfb-run`, or run on a
  real Ubuntu desktop; the handshake is display-independent.
- **R3 — `-D` vs `-F` confusion** leaves an orphaned key (wipe *looks* done but key material remains).
  Mitigation: `-F` + verify with **both** `certutil -L` and `-K`.
- **R4 — nginx port/permission conflicts.** Mitigation: high ports `8443`/`8444`; run nginx
  unprivileged or in a container.

## Security considerations (PoC scope)

- All cert **selection and deletion** are Main-process only; renderer isolated
  (`contextIsolation`/`sandbox`/`nodeIntegration:false`/`webviewTag:false`); preload exposes no
  privileged API in M0.
- Self-signed test CA + mock device cert only — **no real PKI** (brainstorm D3). Keep the `.p12`
  password and `*.key` in `lab/` and **git-ignore them** (`lab/certs/*.key`, `*.p12`, `*.crt`,
  `*.pem`, serials).
- `wipe()` is destructive — guard the `--wipe` flag so it can't fire by accident; M3 gates it behind
  signature verification.

## Definition of Done (mirrors roadmap M0)

- [x] **DoD-1** — Electron loads `https://localhost:8443`; handler presents `CN=DTL-Ubuntu-Test-Device`
  **only** for the designated host; handshake succeeds (`verify=SUCCESS`).
- [x] **DoD-2** — Non-designated host (`:8444`) gets **no** cert (`callback()` empty) → `verify=NONE`.
- [x] **DoD-3** — `wipe()` deletes cert+key from NSS via
  `certutil -F -n DTL-Ubuntu-Test-Device -d sql:$HOME/.pki/nssdb` **and** clears Electron session
  data; `certutil -L` **and** `-K` confirm both gone.
- [x] **DoD-4** — After wipe + relaunch, `:8443` handshake **fails** (locked out) — proves the wipe is
  real, not just cleared cookies.
- [x] **DoD-5** — `lab/reprovision-cert.sh` restores cert+key (`pk12util -i`) and access returns —
  confirms the manual D4 recovery path.
- [x] `wipe()` is a single **reusable, UI-agnostic** module importable by M3.
- [x] **No `app.importCertificate` anywhere**; all cert ops via `certutil` / `pk12util` in Main.

## Next steps (after approval)

- Implement Steps 1 → 5 in order, verifying each before proceeding (Step 2's `curl` checks gate
  Step 3; Step 4 gates Step 5).
- On M0 sign-off, write the detailed **M1 (kiosk shell)** plan — gated, one milestone at a time.

## Setup decisions (resolved before implementation, 2026-06-24)

- **nginx host → podman container.** `dshell` provides **podman** (rootless, no daemon), not
  docker. The nginx mTLS test server runs as a throwaway `podman run -d ... nginx:alpine` container
  binding to `localhost:8443` and `:8444`. The `podman` CLI is largely docker-compatible. Recorded in
  `CLAUDE.md` under "Environment & gotchas."
- **GUI render check → dedicated Ubuntu desktop VM via NoMachine.** Originally planned for
  `xvfb-run`, but it does NOT work in `dshell`: Chromium 130+ makes a logind D-Bus check fatal
  (SIGTRAP) even with a virtual display. GUI/launch verification (Steps 1, 3–5) runs on a
  sysadmin-provided Ubuntu desktop VM via NoMachine — code is built/pushed from dshell and pulled
  onto the VM. curl-level TLS checks (Step 2) stay display-independent and run anywhere.

## Working assumptions

- **mTLS = client/app identity (decision D3) — confirmed 2026-06-29.** mTLS verifies the *client*
  (Electron app instance), not the user — the user is verified separately by OIDC (M2). The client
  cert is scoped to an app install and carries an expiry; whether that maps to a "device" or an
  "install" is a deployment detail the PoC does not need to settle. The purpose of M0 is to
  demonstrate that per-domain mTLS selection and cert wipe are mechanically achievable in Electron on
  Ubuntu. The device-vs-install semantic is not the crux.
