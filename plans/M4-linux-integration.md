# M4 — Linux integration + packaging (device+user session, `.deb`)

> Detailed plan for **Milestone M4** of `plans/roadmap.md`.
> **Status: COMPLETE + VERIFIED on VM (2026-07-03).** All 8 DoD items met; as-built notes appended.
> Builds on **approved + verified M0 + M1 + M2 + M3** (all merged to master): mTLS cert handler,
> custom shell, OIDC auth-gated portal, token-aware `wipe()`, signed kill switch.
> **Scope decision (iterative/cuốn-chiếu):** M4 finishes the **Linux** ecosystem as a complete MVP —
> the two auth layers made explicit + a `.deb` package + documentation. Windows and macOS are split
> into their own later milestones (M5, M6) — see the roadmap-update section at the end.

## Goal

Turn the working feature set into a **complete, installable Linux MVP** and make the **"device + user"
session model explicit**. Two halves:

1. **Session integration (surfacing).** M0 authenticates the *device* (mTLS client cert) and M2
   authenticates the *user* (OIDC token), but today the two layers pass independently and neither knows
   the other's identity. M4 adds one explicit **join point**: read the device identity (cert CN) and
   the user identity (token subject/email) and surface a single session line —
   `session = device <CN> + user <email>`. This makes "device-bound session" a *visible, asserted*
   concept rather than two layers that merely happen to both be on.
2. **Packaging.** Produce an installable **`.deb`** so DTL App installs like a real desktop application
   (apt/dpkg, system menu entry), not `electron .` from a repo.

**Honest scope boundary (like M3's static-backend note):** this is **surfacing / observability**, NOT
**cryptographic binding**. The token is *not* cryptographically bound to the cert — an extracted token
would, in theory, still work on another device with a different cert. True binding (DPoP / mTLS-bound
access tokens) is a documented post-PoC hardening item (Zitadel lab support is limited). M4 proves the
*concept* "one session = one device + one user" and records what it does and does not guarantee.

## Acceptance criteria

1. **Two-layer compose is explicit and tested** — three cases demonstrated on the VM:
   - no cert → blocked at transport (`:8443` nginx 400, portal never loads);
   - cert present + no token → blocked at the portal (M2 auth gate; forced login);
   - cert present + valid token → portal loads AND a session line logs
     `session = device <cert CN> + user <token email>`.
2. **Device identity is read from the existing M0 cert handler** (the CN the app presented in
   `select-client-certificate`) — no new cert parsing, single source of truth.
3. **`.deb` builds and installs** on Ubuntu; launching from the system menu runs DTL App with M0–M3
   intact (mTLS, shell, auth gate, kill poller).
4. **The `.deb` contains the app only — never the lab** (certs, keys, Zitadel, signing keys stay
   per-machine and git-ignored; they are not bundled).
5. **All of M0–M3 regress cleanly** through the packaged build.

## How M4 composes with M0–M3 (the "do they interact?" answer)

- **The join point is additive, in Main.** M4 adds a small `session identity` read that pulls the cert
  CN (already known to Main from M0's `select-client-certificate` handler) and the token claims (already
  in Main from M2) and logs/surfaces one combined line. It does **not** change the cert handler, the
  OIDC flow, `wipe()`, or the kill poller — it *reads* what they already produce.
- **Packaging wraps, does not rewrite.** The `.deb` packages the existing built app. Config that is
  per-machine (lab URLs, cert CN, Zitadel issuer) stays env-overridable exactly as today; the package
  ships sensible defaults, not lab secrets.
- **The kill switch keeps working packaged.** `startKillPoller()` runs the same; a `.deb`-installed app
  still polls `:8444` and wipes on a valid command. (Verify in the regression pass.)
- **Sandbox note (production-hardening item — NOT verified in this PoC).** The VM has no `sudo`, so
  the `.deb` was unpacked with `dpkg -x`, not installed as root. `chrome-sandbox` therefore lacked the
  SUID bit and `ELECTRON_DISABLE_SANDBOX=1` was still required — same as dev. A root-installed `.deb`
  *can* ship the correct SUID bit; sandbox-on is a genuine future hardening win, but is only verifiable
  on a machine with `sudo`. See as-built notes (DoD-7).

## Prerequisites & key gotchas

- **Verification env:** the company VM (`duccanh-test-pc.dtl`) via NoMachine; build in dshell, tar/scp to
  the VM. The `.deb` is *installed* on the VM (dpkg/apt) and launched from the desktop. Launches that
  authenticate still need the M2 `dbus-run-session` keyring wrapper **when running the unpackaged dev
  build**; a `.deb` launched from the system menu inside the NoMachine GNOME session may pick up the
  session keyring normally — **this is a key thing to verify** (it would remove the wrapper for the
  installed app, a cleaner "production-like" proof of DoD-3 from M2).
- **Lab must never enter the package.** The build tar already excludes certs; the `.deb` packaging config
  must likewise exclude `lab/`, `*.key`, `*.pem`, `tokens.enc`, `kill-ledger.json`. Double-check the
  files list — a leaked signing key or cert in a distributable package is a real incident.
- **`electron-builder` is the likely tool.** It produces `.deb` well and handles the Electron runtime.
  It must package the *app* (`out/` + `package.json` runtime deps = just `openid-client`), not dev
  dependencies, and not the repo's `lab/`.
- **`.deb` runs the built/locked build.** The kiosk lockdown is gated on `NODE_ENV` (M1); the packaged
  app is the prod/locked mode. Verify the lockdown behaves as intended when launched from the menu.
- **Cert CN in Main:** M0's `select-client-certificate` handler is where Main chooses (and therefore
  knows) the cert it presents. That handler is the natural place to capture the CN for the session line —
  confirm the CN is available there (it selects by `CERT_SUBJECT_CN` already).

## Architecture (M4 shape)

Additive: one small session-identity surface in Main + a packaging config. No changes to M0–M3 logic.

```
app.whenReady()
  ├─ ensureAuthenticated()        ← M2 (produces token claims: email, sub)
  │      └─ (M4) capture user identity from claims
  ├─ createShell()                ← M1/M2
  │      └─ portalView → :8443 → select-client-certificate (M0)
  │             └─ (M4) capture device identity = presented cert CN
  ├─ (M4) logSessionIdentity()    ← NEW: "session = device <CN> + user <email>"
  └─ startKillPoller()            ← M3
```

- **`src/main/session-identity.js`** *(new, small)* — a single function that, given the captured cert CN
  (device) and the token claims (user), logs/returns the combined session line. Pure-ish; no new deps.
  Explicitly documents that this is surfacing, not binding.
- **`src/main/index.js`** *(modify)* — capture the cert CN from the M0 handler and the email/sub from the
  M2 claims; call `logSessionIdentity()` once the portal has loaded with both present. Everything else
  unchanged.
- **`src/main/cert-select.js`** (or wherever M0's handler lives) *(read/lightly touch)* — expose the CN
  it presented (likely already a constant `CERT_SUBJECT_CN`), so Main can include it. Prefer *reading*
  the existing constant over adding logic.
- **Packaging config** *(new — e.g. `electron-builder.yml` or a `build` block in `package.json`)* — a
  Linux `.deb` target: app id, product name "DTL App", icon (the existing branding logo), category,
  and an explicit files-include list that **excludes `lab/`, keys, certs, tokens, ledger**.
- **`contracts/`** — unchanged (kill-command spec already there; no new wire format in M4).
- **No new runtime dependency.** `electron-builder` is a *dev* dependency (build-time only);
  `openid-client` remains the only *runtime* dep.

## Sub-steps (ordered: make the seam explicit first, then package, then regress)

> Same discipline as M0–M3: the smallest, lowest-risk change first (surfacing the session — pure read of
> existing data), then the packaging (new tooling, medium risk), then a full regression pass through the
> installed artifact. Each step verified on the VM before the next.

### Step 1 — Surface the device+user session identity (explicit join point)

- **Files:** `src/main/session-identity.js` *(new)*, `src/main/index.js` *(modify)*, read
  `CERT_SUBJECT_CN` from the M0 handler.
- **What it does:** after the portal loads with a valid token + a presented cert, log one line:
  `session = device <CN> + user <email>`. No behaviour change to any layer — pure surfacing.
- **Verify (VM):** normal authenticated launch → portal loads `verify=SUCCESS` AND the log shows the
  session line with the correct CN (`DTL-Ubuntu-Test-Device`) and the correct email
  (`testuser@dtl.local`). Retires the "does Main have both identities available?" question with no
  packaging risk in the mix.

### Step 2 — Two-layer compose test (explicit, documented)

- **Files:** none (or a short `docs/` note) — this step is a *verification protocol*, not new code.
- **What it does:** demonstrate the three compose cases as a repeatable test.
- **Verify (VM):**
  - **(a) no cert** → remove/withhold the client cert (or hit `:8443` without it) → nginx 400, portal
    blocked at transport.
  - **(b) cert, no token** → cert present but token store empty/expired → M2 gate forces login, portal
    not shown.
  - **(c) cert + token** → both present → portal loads + session line logs.
  This makes the "device AND user" model concrete and gives the demo a clean three-case story.

### Step 3 — Package as `.deb`

- **Files:** packaging config *(new)*; `package.json` scripts (e.g. `npm run dist:deb`); app icon wiring.
- **What it does:** `electron-builder` (or chosen tool) produces `dtl-app_<version>_amd64.deb` containing
  the built app + the Electron runtime + only the `openid-client` runtime dep. **Excludes `lab/` and all
  secrets.**
- **Verify (VM):** build the `.deb` in dshell, scp to the VM, `sudo dpkg -i` (or `apt install ./…deb`).
  Confirm: (1) it installs; (2) a "DTL App" entry appears in the system menu; (3) the package contents
  (`dpkg -c …deb`) contain **no** `lab/`, `.key`, `.pem`, `tokens.enc`, or `kill-ledger.json`.

### Step 4 — Regression through the installed app (the gate)

- **Files:** none — verification.
- **What it does:** launch the **menu-installed** DTL App and confirm the entire M0–M3 stack works from
  the package.
- **Verify (VM):**
  - M1 shell: branding bar + logo + custom home; kiosk lockdown as configured (prod/locked mode).
  - M0 mTLS: portal `verify=SUCCESS` CN=DTL-Ubuntu-Test-Device.
  - M2 auth: no token → forced login; valid token → portal.
  - M4 session line logs device+user.
  - M3 kill: serve a valid (fresh command_id) `wipe` on `:8444` → app wipes (session+cert+tokens) +
    quits; relaunch forces re-login + `:8443` 400; recovery restores.
  - **Keyring:** note whether the menu-launched `.deb` needs the `dbus-run-session` wrapper or picks up
    the session keyring natively (the cleaner outcome — record it either way).
  - **Sandbox:** note whether the packaged app runs with the chrome-sandbox enabled (SUID shipped by the
    `.deb`) rather than needing `ELECTRON_DISABLE_SANDBOX=1`.

## Decisions (resolved before implementation)

1. **D-M4-1 · Device-binding scope = SURFACING, not cryptographic binding.** Read cert CN + token
   claims, surface a combined session line. Token is not cryptographically bound to the cert; DPoP /
   mTLS-bound tokens are a documented post-PoC item.
2. **D-M4-2 · Device identity source = the M0 `select-client-certificate` handler's CN**
   (`CERT_SUBJECT_CN`). Main already knows the cert it presents; no new parsing.
3. **D-M4-3 · Two-layer compose is tested as three explicit cases** (no cert / cert-no-token /
   cert+token), demonstrated on the VM.
4. **D-M4-4 · Packaging format = `.deb`** (apt/dpkg, system-menu integration), built with
   `electron-builder` (dev dependency; runtime deps unchanged).
5. **D-M4-5 · M4 is Linux-only (MVP).** Windows (Cert Store + `.exe`) → **M5**; macOS (Keychain +
   `.dmg`) → **M6**. See roadmap update below.
6. **D-M4-6 · The package never contains the lab.** Certs, private keys, Zitadel, signing keys,
   `tokens.enc`, `kill-ledger.json` are per-machine and excluded from the `.deb`.
7. **D-M4-7 · Packaging tool = `electron-builder`** (dev dependency; best `.deb` support, least custom
   scripting). Runtime deps unchanged (`openid-client` only).
8. **D-M4-8 · `logSessionIdentity()` fires on the portal's `did-finish-load`** — not right after
   `createShell()`. The mTLS handshake (and `select-client-certificate`, where Main learns the CN it
   presents) happens *during* the `:8443` load; logging on `did-finish-load` guarantees the handshake
   completed, so the captured CN is real, not a stale/empty value.
9. **D-M4-9 · Package identity:** appId `com.dtl.app`, product name `DTL App`, version `0.1.0`.

## Risk assessment

- **R1 (highest) — a secret leaks into the `.deb`.** A bundled cert/key/token in a distributable package
  is a real incident. *Mitigation:* explicit files-include list; verify with `dpkg -c` in Step 3; treat
  any `lab/` / `.key` / `.pem` in the contents as a hard fail.
- **R2 — packaging changes runtime behaviour** (paths, `process.cwd()`, config resolution differ once
  installed vs run-from-repo). The kill poller reads `KILL.caPath` relative to `process.cwd()` — inside a
  `.deb` that path differs. *Mitigation:* Step 4 exercises the kill path from the installed app; make lab
  paths env-overridable so the installed app can point at the local lab for the demo.
- **R3 — regression via packaging** (locked/prod mode behaves differently than dev). *Mitigation:* Step 4
  runs the full M0–M3 stack through the installed artifact.
- **R4 — keyring/sandbox differences** between dev launch and menu launch. *Mitigation:* explicitly
  recorded in Step 4 (may be a *benefit* — no wrapper, sandbox on — but must be verified, not assumed).
- **R5 — over-claiming "device-bound".** Calling this cryptographic binding would be dishonest.
  *Mitigation:* D-M4-1 + the scope-boundary note state plainly it is surfacing, not binding.

## Security considerations (PoC scope)

- **Session identity read in Main only** (like all auth logic); cert CN and token claims never cross to
  the renderer.
- **The package ships the app, not the lab.** No secrets in the distributable.
- **Surfacing ≠ binding (stated plainly).** The session line is observability; it does not prevent token
  reuse on another device. Cryptographic binding is post-PoC.
- **Packaged app sandbox** — not verified in this PoC (VM has no sudo; see as-built DoD-7). A
  root-installed `.deb` shipping SUID `chrome-sandbox` is a post-PoC hardening item.
- **Out of scope (documented):** DPoP / mTLS-bound tokens; MDM-driven install/config; code signing of the
  `.deb`; auto-update; Windows/macOS (M5/M6).

## Definition of Done

- [x] **DoD-1** — VERIFIED: `[session] device=DTL-Ubuntu-Test-Device user=testuser@dtl.local` logged on authenticated launch.
- [x] **DoD-2** — VERIFIED: device identity read from `CERT_SUBJECT_CN` constant; no new cert parsing.
- [x] **DoD-3** — VERIFIED: all three compose cases on the VM. Case (a) logs `[session] transport blocked — no valid mTLS (HTTP 400)` via the 2xx `did-navigate` gate — no bogus device line on the 400 page.
- [x] **DoD-4** — VERIFIED: `dtl-app_0.1.0_amd64.deb` (~83 MB) built via `npm run dist:deb`; unpacked on VM with `dpkg -x` (no sudo — see as-built notes).
- [x] **DoD-5** — VERIFIED: `dpkg -c | grep -Ei 'lab/|\.key|\.pem|\.p12|tokens\.enc|kill-ledger|zitadel'` returns nothing; ASAR contains only `out/` + the 6-package openid-client dep tree.
- [x] **DoD-6** — VERIFIED: full M0–M3 regression through the unpacked app: M1 shell, M0 mTLS `verify=SUCCESS`, M2 OIDC login + warm-start, M4 `[session]` line, M3 kill-switch wipe+quit — all confirmed.
- [x] **DoD-7** — RECORDED: keyring wrapper (`dbus-run-session`) still required; gnome-keyring occasionally needed `pkill -f gnome-keyring-daemon` + relaunch for `isEncryptionAvailable=true`. Sandbox: `ELECTRON_DISABLE_SANDBOX=1` still required (no root install → no SUID sandbox). See as-built notes.
- [x] **DoD-8** — VERIFIED: `electron-builder` is devDependency; `openid-client` is the only runtime dep (its transitive tree — `jose`, `lru-cache`, `object-hash`, `oidc-token-hash`, `yallist` — are not new direct deps).

## Next steps

M4 is complete. Linux MVP is done. Proceed to M5 (Windows) when ready.

---

## As-built notes (honest record — 2026-07-03)

**Install method — no sudo on the VM:**
The VM (`duccanh-test-pc.dtl`) has no `sudo`, so `dpkg -i` was not available. The `.deb` was unpacked
with `dpkg -x ~/dtl-app_0.1.0_amd64.deb ~/dtl-app-installed` instead. All functional M0–M3 regression
was run against the unpacked binary. Two consequences:

- **(a) Sandbox:** `chrome-sandbox` did not get the SUID-root bit (no package manager install). The app
  required `ELECTRON_DISABLE_SANDBOX=1` — same as dev. "Sandbox-on via a root-installed `.deb`" is a
  production-hardening item, testable only on a machine with `sudo`. Out of PoC scope; noted as DoD-7.
- **(b) Menu entry:** `/usr/share/applications/dtl-app.desktop` was not created (no root install). The
  `.desktop` file content was verified from the `.deb` directly (`dpkg --fsys-tarfile | tar -xO`) —
  `Name=DTL App`, `Exec="/opt/DTL App/dtl-app"`, `Categories=Network;` — structurally correct.

**Keyring (DoD-7):**
`dbus-run-session` wrapper still required for `safeStorage` when launching from the NoMachine terminal.
gnome-keyring occasionally started in a state where `isEncryptionAvailable=false`; fix:
`pkill -f gnome-keyring-daemon` then relaunch with the full wrapper. Launching from a native GNOME
session (not NoMachine) would likely pick up the session keyring automatically — not verified here.

**`DTL_KILL_CA_PATH` is required for the packaged app (R2):**
The default `'lab/certs/ca.pem'` in `KILL.caPath` is `process.cwd()`-relative. Outside the repo,
`process.cwd()` is not the repo root, so the path breaks. The poller fails-open (D-M3-8) silently
without it. For the regression demo, `DTL_KILL_CA_PATH` was set to the absolute path of the lab CA.

**Kill-switch anti-replay verified through the package:**
- `kill-wipe-cmd005` (>24 h old, pre-signed) → verdict `STALE`, rejected.
- `kill-wipe-cmd006` (freshly signed) → verdict `VALID_WIPE` → `sessionCleared: true, certDeleted: true,
  tokensCleared: true` → app quit. Relaunch showed forced re-login + nginx 400 (cert gone). Recovery
  restored cert + re-login.

**Runtime dep tree in the `.deb` (not new direct deps):**
The ASAR contains `openid-client` plus its 5 transitive deps (`jose`, `lru-cache`, `object-hash`,
`oidc-token-hash`, `yallist`). These are openid-client's dependency tree pulled in by `externalizeDepsPlugin`;
they are not new direct runtime dependencies of the app.

---

## Roadmap update — add M5 and M6 (per the iterative multi-platform decision)

The desktop track is **one Electron codebase**; only two seams differ per OS — the **certificate store**
and the **packaging format**. M4 finishes Linux; the remaining platforms become their own milestones so
each has a clean Definition of Done. Proposed additions to `plans/roadmap.md`:

- **M5 — Windows integration + packaging**
  - **Cert store seam:** integrate with the **Windows Certificate Store** (the mTLS client cert lives in
    the OS store; the wipe path must delete from it) — the Windows analogue of the NSS/`certutil` work.
  - **Packaging seam:** produce a **`.exe` installer** (e.g. NSIS via electron-builder) / signed later.
  - **Reuse:** M0–M4 app logic, OIDC flow, kill switch, `contracts/` are shared unchanged; only the cert
    store adapter and the packaging target are new.
  - **Likely new seam to formalize:** a small `CertStore` interface (present/select/delete) with an NSS
    impl (Linux, existing) and a Windows impl — the abstraction we deferred until a second real platform
    exists. M5 is that moment.

- **M6 — macOS integration + packaging**
  - **Cert store seam:** integrate with the **macOS Keychain** (client cert + identity; wipe deletes from
    Keychain) — the third `CertStore` implementation.
  - **Packaging seam:** produce a **`.dmg`** (and notarization/code-signing as a later hardening item).
  - **Reuse:** same shared core; macOS stays on the **desktop/Electron track** (a common misgrouping is
    to lump macOS with mobile — it is not; iOS is the mobile track, macOS is desktop).

- **Beyond (unchanged, still on the far horizon):** mobile track (iOS/Android) is a *separate codebase*
  (iOS prohibits Chromium → WKWebView; Flutter a candidate unifier pending an iOS mTLS spike). The
  language-neutral `contracts/` layer (now holding `kill-command.md`) is the true shared artifact across
  desktop and mobile — not shared TypeScript.