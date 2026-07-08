# M2 — OIDC user authentication: system browser + PKCE + safeStorage tokens

> Detailed plan for **Milestone M2** of `plans/roadmap.md`. **Planning only — no code yet.**
> Per the CLAUDE.md two-tier gate, this plan is reviewed and approved *before* any code is written.
> Sources: roadmap M2 · brainstorm **E1–E4** (auth) / **F3** (wipe scope) · techstack §2 (token
> storage, wipe) / §3 (OIDC: `openid-client` + system browser + PKCE + loopback) / §5 (rebuild risks)
> · `plans/M1-kiosk.md` (session-partition / wipe caveat). Builds on **approved + verified M0 + M1**
> code in `src/main/` (cert handler, `wipe()`, `createShell()`, secure `webPreferences`).

## Goal

Add the **user-identity layer**: gate the kiosk shell behind a DTL login performed in the **system
browser** (never an embedded view), exchange the result for OIDC tokens via **Authorization Code +
PKCE**, hold those tokens **main-process only, OS-encrypted** (`safeStorage`), and refuse to load the
portal without a valid token. M2 proves the *user* is who they say they are; M0's mTLS already proves
the *device*. Per **E2 these are independent layers** — M2 does **not** touch the cert handler. The
mock backend + signed kill (M3) and OS packaging (M4) are explicitly **out of M2**.

## Acceptance criteria (restated from roadmap M2)

1. On launch the user is sent to **Zitadel in the system browser**; on success control returns via the
   **loopback redirect** and the shell loads the portal.
2. The login UI is **never** rendered inside the WebView (RFC 8252 / E3).
3. Tokens live **only in the main process** via `safeStorage`; the renderer cannot read them. Check
   `safeStorage.getSelectedStorageBackend()` — headless `dshell` likely falls back to `basic_text`
   (unencrypted), so also verify on a **real Ubuntu desktop** (the NoMachine VM).
4. Token expiry triggers **silent refresh**; refresh failure forces **re-auth**; **no valid token ⇒ no
   portal**.

## How M2 composes with M0/M1 (the explicit "do they interact?" answer)

- **Sequencing — login GATES the portal (confirmed — Decision 3).** Roadmap criterion 4 ("no valid
  token ⇒ no portal") settles this: `createShell()` must not navigate `portalView` to `HOME_URL` until a
  valid access token exists. On `whenReady`, run an **auth gate** *before* loading the portal; show a
  minimal **"Sign in with DTL" gate screen** in the **existing M1 chrome renderer** (reuse, no new
  window). The user clicks it to start the flow — the app does **not** auto-open the browser on launch
  (Decision 4). A persistent auth/identity indicator is **deferred to M3** (with the managed-by-DTL /
  kill-switch status).
- **Technically independent (brutal-honesty flag).** OIDC runs entirely in the **system browser +
  loopback**, touching **no Electron session**. The mTLS cert is selected at the TLS layer by the M0
  `select-client-certificate` handler whenever `portalView` connects to `:8443` — **regardless** of
  OIDC. Per **E3 the PoC does NOT inject the OIDC token into portal requests** (internal apps keep
  their own auth). So in the PoC the access token **gates launch and is stored/wiped** — it is *not*
  presented to the `:8443` fixture (which only checks the client cert). The value M2 demonstrates is
  **the login flow + secure token handling + wipe integration**, not token-authorized resource access.
  This is correct for the PoC; stating it avoids a false "the portal validates our token" impression.

## Prerequisites & key gotchas

- **Verification env (carried from M0/M1):** GUI + system-browser login run on the **Ubuntu desktop VM**
  (`duccanh-test-pc.dtl`) via NoMachine (primary) or **WSL** (secondary). `dshell` is headless and also
  hits the `safeStorage` `basic_text` fallback, so the *encryption* criterion can only be truly
  confirmed on the desktop. Code is built/pushed from `dshell`, pulled onto the VM.
- **Zitadel is new, per-machine lab infra.** Like the nginx mTLS lab and the NSS certs, the local
  Zitadel instance is **rebuilt on each dev box** (a container) and is **not** committed/shared. Same
  discipline as `lab/certs/*` (git-ignored). The issuer/client config is environment-local.
- **`safeStorage` backend caveat (techstack §2):** `getSelectedStorageBackend()` returns `gnome-libsecret`
  / `kwallet` on a desktop with an **unlocked keyring**, but `basic_text` (effectively plaintext) when
  no secret service is available (headless, or a VM with no/locked keyring). The PoC accepts `basic_text`
  as a *documented limitation* but must **log the backend loudly** and verify real encryption on a
  desktop with a keyring. *(Whether the NoMachine VM has an unlocked keyring is a **verify-on-machine**
  item — Decision 8 — not a design choice.)*
- **Loopback must bind IPv4 `127.0.0.1` explicitly**, and `redirect_uri` must use the literal
  `127.0.0.1` host (not `localhost`). This sidesteps the `localhost`→`::1` (IPv6) resolution mismatch
  we hit under WSL: if the listener binds IPv4 but the browser resolves `localhost` to `::1`, the
  redirect never arrives. RFC 8252 §7.3 explicitly prefers loopback IP literals for this reason.
- **Issuer consistency (Zitadel gotcha):** Zitadel's `ExternalDomain`/issuer must match the URL the app
  uses for discovery, or token `iss` validation fails. Pin one issuer URL and use it everywhere
  (discovery, auth, token, validation).
- **`openid-client` is ESM and is the project's first runtime dependency (approved — Decision 2).**
  electron-vite externalizes node deps from the main bundle by default; confirm it resolves at runtime
  (not inlined) and **pin a version** (R4). A deliberate, signed-off departure from the minimal-deps
  stance — hand-rolling token validation would be the inverse over-engineering trap for security code.
- **No new renderer privilege.** The preload stays empty; tokens never cross IPC to the renderer. The
  auth gate UI only needs *status* (a string/enum), never the tokens themselves.

## Architecture (M2 shape)

**Keep all auth in Main, decoupled from the UI** (roadmap rebuild-risk #3: security logic reusable even
if the UI is rewritten). New `src/main/auth/` module group:

```
app.whenReady()
  └─ ensureAuthenticated()                         ← NEW gate, runs before portal load
       ├─ token-store.getValidAccessToken()        ← decrypt from disk; refresh if expired
       │     └─ (valid)  → createShell() loads portal   ← M1 shell, unchanged structure
       └─ (none/refresh-failed) → oidc.login()
             ├─ shell.openExternal(authUrl)         ← system browser (E3 / RFC 8252)
             ├─ loopback 127.0.0.1:<ephemeral>      ← captures ?code&state, validates state
             ├─ oidc.exchangeCode()  (PKCE verifier)
             ├─ claim check (company-account restriction)
             └─ token-store.save()  (safeStorage, encrypted, userData)
```

- **`src/main/auth/oidc.js`** — discovery (`Issuer.discover`), PKCE (S256) auth-URL builder, code
  exchange, refresh-grant. Wraps `openid-client`. Pure logic, no Electron UI deps.
- **`src/main/auth/loopback.js`** — ephemeral `http` server on `127.0.0.1`, fixed-or-ephemeral port,
  resolves a promise with `{code,state}`, validates `state`, serves a "you can close this tab" page,
  then closes. (May be folded into `oidc.js` for KISS — decide at implementation.)
- **`src/main/auth/token-store.js`** — `safeStorage.encryptString`/`decryptString` of
  `{access, refresh, id, expiresAt}` to `app.getPath('userData')/tokens.enc`; `getValidAccessToken()`
  (lazy refresh when expired), `clearTokens()`, and a startup `getSelectedStorageBackend()` log.
- **`src/main/config.js`** *(modify)* — add `OIDC` block: `ISSUER_URL` (local Zitadel), `CLIENT_ID`,
  `SCOPES` (`openid profile email offline_access`), `REDIRECT_HOST='127.0.0.1'`, and the
  **allowed-account** rule (org id or email domain). Env-overridable, per-machine.
- **`src/main/index.js`** *(modify)* — call `ensureAuthenticated()` before `createShell()`; keep the
  cert handler registration, the `--wipe` branch, and the menu gate exactly as-is.
- **`src/main/window.js`** *(modify)* — accept an "authenticated" signal so the portal loads only post-
  auth; surface a status string to the chrome renderer for the gate UI. M1 lockdown/branding unchanged.
- **`src/main/wipe.js`** *(modify)* — see cross-cutting below.

**Session-partition decision (resolves the M1 caveat for M2):** **keep the portal on the
`defaultSession`** (no `partition:`). OIDC tokens live in **`safeStorage` files**, not in any Electron
session, and the system-browser flow touches no session — so introducing a partition buys nothing and
would force `wipe()` to target it. **Decision 9 — no partition in M2**; M0's `wipe()` session
targeting stays correct. *(If a partition is ever added, `wipe()` must clear
`session.fromPartition(...)` too — the M1 caveat.)*

## Cross-cutting: extend `wipe()` (M2 is when tokens first exist)

M0/M1 deliberately deferred token clearing (no tokens existed). M2 introduces them, so `wipe()` **must**
grow a third clause, keeping it **UI-agnostic and reusable** (M3 calls the same function):

- **(c) Clear the safeStorage tokens** — `token-store.clearTokens()` deletes `tokens.enc` from
  `userData`. Add to the existing `wipe()` after (a) session data and (b) the NSS cert.
- **Session targeting** — unchanged: portal stays on `defaultSession`, which `wipe()` already clears.
  Document the conditional (partition ⇒ target that session) inline so M3 doesn't regress it.
- **Result object** — extend to `{ sessionCleared, certDeleted, tokensCleared }` so M3's signed-kill
  path can assert all three. F3 scope (cert + tokens + cookies + cache + localStorage) is then fully met.

## Sub-steps (ordered: stand up infra → retire the round-trip risk → persistence → gate → wipe)

> Mirrors M0/M1 discipline: prove the new infra **outside Electron first**, then retire the highest-
> uncertainty Electron integration, then layer persistence, gating, and wipe. Each step is independently
> verifiable on the VM before the next.

### Step 1 — Stand up local Zitadel + register the test client (lab infra; no Electron yet)

- **Files (under `lab/zitadel/`):**
  - `lab/zitadel/compose.yml` — podman/Docker Compose for Zitadel + its datastore, pinned issuer
    (fixed `ExternalDomain`/port). Mirrors the nginx-lab pattern; **per-machine, git-ignored** secrets.
  - `lab/zitadel/README.md` — run order + **manual client registration** steps: create org/project,
    register a **public (PKCE, no secret)** native app, set redirect `http://127.0.0.1:<port>/callback`,
    scopes `openid profile email offline_access`, create a **test user** in the org.
  - `.gitignore` *(modify)* — ignore any generated Zitadel secrets/state.
- **What it does:** retires "can we even run Zitadel locally and reach its OIDC endpoints" before any
  app code — the same lab-first risk reduction M0 used with `curl` before Electron.
- **Verify (VM):** `curl <ISSUER>/.well-known/openid-configuration` returns the discovery doc;
  the Zitadel login page loads in a browser; a manual auth-code flow (paste the auth URL into the
  browser, log in as the test user, observe the `?code=` redirect to `127.0.0.1`) round-trips.
  **Gate:** do not start Step 2 until discovery + login + redirect work by hand.

### Step 2 — OIDC core in Main: system browser + PKCE + loopback capture + exchange (retires the core risk)

- **Files:** `src/main/auth/oidc.js` *(new)*, `src/main/auth/loopback.js` *(new)*, `src/main/config.js`
  *(modify — `OIDC` block)*. Temporary: a dev-only entry (e.g. `--login` arg, like `--wipe`) that runs
  the flow and **logs the tokens to the terminal** — **not** yet persisted, **not** yet gating the shell.
- **What it does:** proves the full Authorization Code + PKCE round-trip against local Zitadel: build
  the auth URL (S256 PKCE + `state` + `nonce`), `shell.openExternal`, capture the code on
  `127.0.0.1`, validate `state`, exchange for tokens, validate `iss`/`nonce`. Includes the
  **company-account claim check** (reject a token whose email-domain/org claim isn't allowed).
- **Verify (VM):** `electron . --login` → system browser opens Zitadel → log in → redirect captured →
  terminal logs decoded `id_token` claims + that the login UI was **never** in the WebView (criterion 2).
  A non-company test user (if available) is **rejected**. Confirm `127.0.0.1` binding works on the VM
  (and, if tested, under WSL).

### Step 3 — Token persistence + silent refresh via `safeStorage` (retires the storage risk)

- **Files:** `src/main/auth/token-store.js` *(new)*; `oidc.js` *(modify — add `refresh()`)*.
- **What it does:** persist `{access, refresh, id, expiresAt}` encrypted to `userData/tokens.enc`;
  `getValidAccessToken()` decrypts on launch and, if expired, performs a **silent refresh** (no browser)
  via the refresh grant, **persisting any rotated refresh token**; logs
  `getSelectedStorageBackend()` at startup.
- **Verify:** run the flow, restart the app → tokens load from disk without re-login; force expiry →
  silent refresh succeeds; revoke/expire the refresh token → refresh fails cleanly (sets up Step 4
  re-auth). On the **desktop with a keyring** the backend is `gnome-libsecret`/`kwallet`; on `dshell`
  confirm it logs `basic_text` (criterion 3 caveat). Inspect `tokens.enc` — not human-readable on a
  real backend.

### Step 4 — Gate the shell on auth (delivers criteria 1 & 4; M0/M1 regression gate)

**Approach used: AUTH-FIRST, WINDOW-SECOND** (Decision 4 revised — gate screen deferred).
`ensureAuthenticated()` runs entirely in Main before `createShell()`; `window.js` is **untouched**;
tokens **never cross IPC**; no renderer gate screen. The gate-screen / identity indicator is deferred
to M3 or later. The app auto-opens the system browser when no valid token exists (no click required).

- **Files:** `src/main/index.js` *(modify — add `ensureAuthenticated()` before `createShell()`; refactor
  `--login` branch to use shared `runLoginFlow()` helper)*, `src/main/auth/login-flow.js` *(new —
  `runLoginFlow()` shared helper: browser-open + loopback + exchange + domain-check; removes duplication
  between `--login` branch and normal launch)*.
  **NOT modified:** `src/main/window.js`, `src/renderer/*` (no renderer changes needed).
- **What it does:** wires the pieces: valid token ⇒ portal loads; no token ⇒ browser login then portal;
  refresh-failure ⇒ forced re-auth; **no valid token ⇒ no portal** (criterion 4). Login gates launch.
- **Verify (VM — VERIFIED):** cold start with no tokens → login → portal renders `verify=SUCCESS …
  CN=DTL-Ubuntu-Test-Device` (M0 mTLS **still fires** through the authenticated shell — **regression
  gate**); M1 shell (branding, default-deny nav, kiosk lock) intact; restart → no re-login (token
  reused); delete tokens → re-auth forced; cancel login → portal does NOT load, app quits.

### Step 5 — Extend `wipe()` to clear tokens (completes F3 scope) — VERIFIED

- **Files:** `src/main/wipe.js` *(modify — add clause (c) `token-store.clearTokens()`; extend the
  result object; document the partition conditional)*.
- **What it does:** the wipe now clears **session data + NSS cert + tokens** — the full F3 scope —
  while staying a single reusable, UI-agnostic function M3 can call behind the signed kill.
- **Verify (VM — VERIFIED):** authenticate → `tokens.enc` present → `electron . --wipe` logs
  `[wipe] SUCCESS { sessionCleared: true, certDeleted: true, tokensCleared: true }`;
  `tokens.enc` gone; `certutil -L` shows DTL-Ubuntu-Test-Device gone; relaunch → forced re-login
  AND `:8443` returns nginx 400 "No required SSL certificate" (locked out of both user + device layers).
  `lab/reprovision-cert.sh` + re-login → portal back to `verify=SUCCESS` (recovery path intact).

## Risk assessment

- **R1 (highest) — local Zitadel setup / issuer mismatch.** Wrong `ExternalDomain` ⇒ `iss` validation
  fails, discovery breaks. *Mitigation:* Step 1 stands Zitadel up and proves discovery+login by hand
  before any app code; pin one issuer URL everywhere.
- **R2 — `safeStorage` `basic_text` fallback** on headless/keyring-less hosts ⇒ tokens effectively
  plaintext. *Mitigation:* log the backend loudly; verify real encryption on a desktop with an unlocked
  keyring; accept `basic_text` only as a documented PoC limitation (F4 tamper is already accepted).
- **R3 — loopback redirect unreachable** (IPv6 `localhost`→`::1`, WSL networking). *Mitigation:* bind
  IPv4 `127.0.0.1` explicitly and use the IP literal in `redirect_uri`; VM (browser+app same host) is
  the primary, low-risk env.
- **R4 — `openid-client` integration** (first runtime dep; ESM/CJS interop; electron-vite bundling).
  *Mitigation:* confirm externalization in the main build; pin a version; the alternative (`AppAuth-JS`)
  is reversible (techstack §5).
- **R5 — gating regresses M0/M1** (portal loads pre-auth, or auth interferes with cert selection).
  *Mitigation:* Step 4 is an explicit regression gate on `verify=SUCCESS` + the M1 shell behaviours.
- **R6 — refresh-token rotation not persisted** ⇒ next refresh fails. *Mitigation:* persist tokens after
  every refresh; test the revoke path in Step 3.
- **R7 — PKCE/state/nonce validation bugs** ⇒ CSRF/code-injection. *Mitigation:* rely on
  `openid-client`'s built-in checks; never accept a code with a mismatched `state`.

## Security considerations (PoC scope)

- **System browser only; never embed the IdP login** (E3, RFC 8252) — the single biggest rebuild-risk
  to get right now (techstack §5).
- **PKCE (S256) + `state` + `nonce`** all generated and validated; public client, **no client secret**
  shipped.
- **Tokens are Main-process-only**, encrypted at rest via `safeStorage`; **no IPC path returns a token**
  to the renderer; the gate UI receives only a status enum.
- **Loopback** binds `127.0.0.1`, ephemeral, **closes after one capture**, and rejects any callback whose
  `state` doesn't match.
- **Company-account restriction** enforced in **two places:** Zitadel org/project scoping (primary) +
  a post-exchange **email-domain claim check** in Main (defense in depth): `email_verified === true`
  AND `email` ends with `@dtl.local` (env-overridable; prod = `@dytechlab.com`). No special Zitadel
  scope required — `email` and `email_verified` are present in standard userinfo (Decision 6).
- **Independent layers (E2):** M2 does **not** modify the M0 cert handler or weaken any M1 lockdown;
  both views keep `contextIsolation`/`sandbox`/`nodeIntegration:false`/`webviewTag:false`; `webSecurity`
  never disabled.
- **Out of scope (unchanged):** no token injection into portal requests (E3); no real keyring hardening;
  refresh-token-at-rest theft on a compromised box is an accepted limitation (F4); no DLP (H2).

## Definition of Done (mirrors roadmap M2)

- [x] **DoD-1** — On launch the user is sent to **Zitadel in the system browser**; on success the
  loopback redirect returns control and the shell loads the portal. *(VERIFIED on VM)*
- [x] **DoD-2** — The login UI is **never** rendered inside the WebView. *(system browser only — RFC 8252)*
- [x] **DoD-3** — Tokens live **only** in Main via `safeStorage`; the renderer cannot read them;
  backend `gnome_libsecret`, `isEncryptionAvailable()=true`, `tokens.enc` is real OSCrypt binary.
  `basic_text` fallback documented + rejected. *(VERIFIED on VM — see Decision 8)*
- [x] **DoD-4** — Token expiry ⇒ **silent refresh**; refresh failure ⇒ **re-auth**; **no valid token ⇒
  no portal**. *(VERIFIED: cancel login → app quits, portal never loads)*
- [x] **DoD-5** — Company-account restriction enforced: `email_verified === true` AND `email` ends with
  `@dtl.local`. *(VERIFIED: testuser@dtl.local passes; domain mismatch quits)*
- [x] **DoD-6 (wipe)** — `wipe()` clears **session + NSS cert + tokens** (full F3 scope), single
  reusable UI-agnostic function; returns `{ sessionCleared, certDeleted, tokensCleared }`;
  post-wipe: nginx 400 "No required SSL certificate" + forced re-login. *(VERIFIED on VM)*
- [x] **DoD-7 (regression)** — M0 mTLS (`verify=SUCCESS … CN=DTL-Ubuntu-Test-Device`) and M1 shell
  (branding, default-deny nav, kiosk lock) pass through the authenticated shell. *(VERIFIED)*
- [x] Auth logic isolated in `src/main/auth/` (decoupled from UI per rebuild-risk #3); minimal new deps
  (`openid-client` v5.7.1 CJS — pinned).

## Next steps (after approval)

- Implement Steps 1 → 5 in order, verifying each on the VM before proceeding (Step 1 gates Step 2;
  Step 4 is the M0/M1 regression gate).
- On M2 sign-off, write the detailed **M3 (mock backend + signed Ed25519 kill switch)** plan — gated,
  one milestone at a time. M3 reuses this `wipe()` (now token-aware) behind the signed kill.

## Decisions (resolved before implementation, 2026-06-29)

> The pre-implementation open questions are now **resolved**. Recorded here so implementation does not
> re-litigate them; each maps to the architecture / steps above.

1. **Redirect mechanism — loopback `127.0.0.1` listener.** RFC 8252; sidesteps the WSL `localhost`→`::1`
   IPv6 mismatch. A custom URL scheme (`dtlapp://`) is **deferred to post-M4** (needs OS registration,
   awkward before packaging) and stays a reversible later add.
2. **Library — use `openid-client` (approved as the first runtime dependency; no dependency
   restriction).** It handles discovery, PKCE, JWKS validation, and refresh. Hand-rolling token
   validation is **rejected** as the inverse over-engineering trap for security-critical code. **R4
   still applies:** externalize it correctly in the electron-vite **Main** build and **pin a version**.
3. **Login GATES the portal.** `createShell()` must **not** load `HOME_URL` until a valid token exists —
   **no token ⇒ no portal** (roadmap criterion 4).
4. **Pre-auth UI — REVISED: no gate screen (auth-first, window-second).** `ensureAuthenticated()` runs
   fully in Main before `createShell()`; app auto-opens the system browser when no token exists (no
   click required); `window.js` and the renderer are untouched. The "Sign in with DTL" gate screen and
   persistent identity indicator are **deferred to M3** (with the managed-by-DTL / kill-switch status).
5. **Zitadel client (per-machine; user provisions manually; documented in `lab/zitadel/README.md`).**
   A **public/native PKCE app (no secret)**, redirect `http://127.0.0.1:<port>/callback`, scopes
   `openid profile email offline_access`, one org/project + one test user.
6. **Company-account restriction — Zitadel org/project scoping (primary) + a Main-process email-domain
   claim check (defense in depth).** Implemented check: `email_verified === true` AND `email` ends with
   `@dtl.local` (env-overridable via `DTL_OIDC_ALLOWED_EMAIL_DOMAIN`; prod path = `@dytechlab.com`).
   Org-id claim (`urn:zitadel:iam:user:resourceowner:id`) was NOT used — it is absent for normal
   (non-admin) users, and the scope that surfaces it (`urn:zitadel:iam:user:resourceowner`) causes
   the Zitadel v2 login page to hang. Email-domain check is the "prod path" from the original
   Decision 6; the org-id path is superseded.
7. **Token refresh — lazy** (on launch + on expiry); **no** proactive pre-expiry timer. KISS.
8. **`safeStorage` backend — RESOLVED (VM-specific; Decision 8).** Root cause on this VM: NoMachine
   sessions don't run `pam_gnome_keyring.so`, so the systemd-started gnome-keyring daemon runs headless
   (no DISPLAY) and exposes only `InternalUnsupportedGuiltRiddenInterface` — NOT the full
   `org.freedesktop.secrets.Service`. Electron selects `gnome_libsecret` backend but
   `isEncryptionAvailable()` returns `false`.

   **WORKING SOLUTION (verified):** wrap the app in `dbus-run-session` from the NoMachine terminal:
   ```
   dbus-run-session -- bash -c '
     eval $(echo -n "" | gnome-keyring-daemon --unlock --components=secrets,pkcs11,ssh)
     python3 lab/ensure-keyring.py
     GNOME_DESKTOP_SESSION_ID=this-is-deprecated ELECTRON_DISABLE_SANDBOX=1 \
       ./node_modules/.bin/electron . [args]
   '
   ```
   *(Updated post-M4/handoff-spike: `--unlock` (empty password) replaces `--start` so no "Unlock
   Keyring" dialog appears; `ensure-keyring.py` additionally uses the very
   `InternalUnsupportedGuiltRiddenInterface` referenced above (its `CreateWithMasterPassword` method)
   to create the default collection with an empty password when none exists — otherwise `--unlock`
   alone leaves a "Choose password for NEW keyring" dialog on a fresh machine. See `lab/run-app.sh`.
   NOT `--password-store=basic`, which would downgrade encryption.)*
   Result: `gnome_libsecret` backend, `isEncryptionAvailable()=true`, `tokens.enc` is real
   Chromium OSCrypt binary (v11 header, not human-readable).

   **REJECTED alternatives (do not retry):**
   - `--password-store=basic` → forces `basic_text`; in Electron 42 `encryptString()` throws for
     `basic_text` (it is "truly no encryption"; `IsEncryptionAvailable()` returns false).
   - Plaintext PLN1 fallback → contradicts DoD-3 (tokens must be OS-encrypted).
   - Self-rolled AES-256-GCM with a `.keyfile` beside `tokens.enc` → violates Decision 2
     (no hand-rolled crypto); storing the key beside the ciphertext is encryption in name only.

   **token-store is safeStorage-only, FAIL-LOUD:** if `isEncryptionAvailable()` is false at `save()`,
   it throws a clear error and writes nothing. On a native desktop / WSLg with an unlocked keyring,
   no wrapping is needed — `safeStorage` auto-picks `gnome_libsecret`.
9. **Session partition — keep the portal on `defaultSession` (no partition).** Tokens live in
   `safeStorage` files, not an Electron session, so a partition buys nothing and would complicate
   `wipe()`. *(If ever added, `wipe()` must target that session — the M1 caveat.)*
10. **Token "use" in the PoC — token gates launch + is stored + is wiped, but is NOT presented to the
    `:8443` fixture** (per E3). M2's demonstrated value is **login + secure storage + wipe**, not
    token-authorized resource access — aligned with "show we can customize; the actual feature does not
    matter."
