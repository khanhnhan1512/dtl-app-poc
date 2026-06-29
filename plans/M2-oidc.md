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

- **Sequencing — login GATES the portal (recommended).** Roadmap criterion 4 ("no valid token ⇒ no
  portal") settles this: `createShell()` must not navigate `portalView` to `HOME_URL` until a valid
  access token exists. Recommendation: on `whenReady`, run an **auth gate** *before* loading the portal;
  show a minimal local "Sign in / Signing in…" state in the **existing M1 chrome renderer** (reuse, no
  new window) while the browser flow runs. *(Whether to auto-open the browser immediately vs. show a
  "Sign in with DTL" button first is a UX/product call — see Open Questions.)*
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
  desktop with a keyring. *(Open question: does the NoMachine VM have an unlocked keyring?)*
- **Loopback must bind IPv4 `127.0.0.1` explicitly**, and `redirect_uri` must use the literal
  `127.0.0.1` host (not `localhost`). This sidesteps the `localhost`→`::1` (IPv6) resolution mismatch
  we hit under WSL: if the listener binds IPv4 but the browser resolves `localhost` to `::1`, the
  redirect never arrives. RFC 8252 §7.3 explicitly prefers loopback IP literals for this reason.
- **Issuer consistency (Zitadel gotcha):** Zitadel's `ExternalDomain`/issuer must match the URL the app
  uses for discovery, or token `iss` validation fails. Pin one issuer URL and use it everywhere
  (discovery, auth, token, validation).
- **`openid-client` is ESM and would be the project's first runtime dependency.** electron-vite
  externalizes node deps from the main bundle by default; confirm it resolves at runtime (not inlined).
  This is a genuine departure from the minimal-deps stance — see the library decision below.
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
would force `wipe()` to target it. Recommendation: **no partition in M2**; M0's `wipe()` session
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

- **Files:** `src/main/index.js` *(modify — `ensureAuthenticated()` before `createShell()`)*,
  `src/main/window.js` *(modify — load portal only when authenticated; surface a status string to the
  chrome renderer)*, `src/renderer/*` *(modify — minimal "Sign in / Signing in… / Signed in" gate
  state; reuses the M1 chrome renderer, no tokens cross IPC)*.
- **What it does:** wires the pieces: valid token ⇒ portal loads; no token ⇒ browser login then portal;
  refresh-failure ⇒ forced re-auth; **no valid token ⇒ no portal** (criterion 4). Login gates launch.
- **Verify (VM):** cold start with no tokens → login → portal renders `verify=SUCCESS …
  CN=DTL-Ubuntu-Test-Device` (M0 mTLS **still fires** through the authenticated shell — **regression
  gate**); M1 shell (branding, default-deny nav, kiosk lock) intact; restart → no re-login (token
  reused); delete/expire tokens → re-auth forced; never any portal without a token.

### Step 5 — Extend `wipe()` to clear tokens (completes F3 scope)

- **Files:** `src/main/wipe.js` *(modify — add clause (c) `token-store.clearTokens()`; extend the
  result object; document the partition conditional)*.
- **What it does:** the wipe now clears **session data + NSS cert + tokens** — the full F3 scope —
  while staying a single reusable, UI-agnostic function M3 can call behind the signed kill.
- **Verify:** authenticate, confirm `tokens.enc` exists → `electron . --wipe` → `tokens.enc` gone,
  NSS cert gone (`certutil -L`/`-K`), session cleared; relaunch → **forced re-login AND** `:8443`
  handshake fails (locked out of both user + device layers). Re-inject the cert
  (`lab/reprovision-cert.sh`) + re-login → access restored (manual recovery path intact).

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
  a post-exchange **claim check** in Main (defense in depth). Exact claim TBD (Open Questions).
- **Independent layers (E2):** M2 does **not** modify the M0 cert handler or weaken any M1 lockdown;
  both views keep `contextIsolation`/`sandbox`/`nodeIntegration:false`/`webviewTag:false`; `webSecurity`
  never disabled.
- **Out of scope (unchanged):** no token injection into portal requests (E3); no real keyring hardening;
  refresh-token-at-rest theft on a compromised box is an accepted limitation (F4); no DLP (H2).

## Definition of Done (mirrors roadmap M2)

- [ ] **DoD-1** — On launch the user is sent to **Zitadel in the system browser**; on success the
  loopback redirect returns control and the shell loads the portal.
- [ ] **DoD-2** — The login UI is **never** rendered inside the WebView.
- [ ] **DoD-3** — Tokens live **only** in Main via `safeStorage`; the renderer cannot read them;
  `getSelectedStorageBackend()` is logged and **real encryption verified on a desktop** (with the
  `basic_text` fallback documented for headless).
- [ ] **DoD-4** — Token expiry ⇒ **silent refresh**; refresh failure ⇒ **re-auth**; **no valid token ⇒
  no portal**.
- [ ] **DoD-5** — Company-account restriction enforced (Zitadel org scoping + Main-process claim check).
- [ ] **DoD-6 (wipe)** — `wipe()` now clears **session + NSS cert + tokens** (full F3 scope), stays a
  single reusable UI-agnostic function; post-wipe relaunch forces **re-login and** mTLS lockout.
- [ ] **DoD-7 (regression)** — M0 mTLS (`verify=SUCCESS`) and the M1 shell (branding, default-deny nav,
  kiosk lock) still pass through the authenticated shell.
- [ ] Auth logic isolated in `src/main/auth/` (decoupled from UI per rebuild-risk #3); minimal new deps.

## Next steps (after approval)

- Implement Steps 1 → 5 in order, verifying each on the VM before proceeding (Step 1 gates Step 2;
  Step 4 is the M0/M1 regression gate).
- On M2 sign-off, write the detailed **M3 (mock backend + signed Ed25519 kill switch)** plan — gated,
  one milestone at a time. M3 reuses this `wipe()` (now token-aware) behind the signed kill.

## Open questions (genuinely unresolved — to resolve before implementation)

1. **Redirect mechanism.** Loopback `127.0.0.1` listener (recommended; RFC 8252; sidesteps WSL IPv6) vs
   a custom URL scheme (`dtlapp://`). Confirm loopback for M2; custom scheme is a reversible later add
   (needs OS registration, awkward before M4 packaging).
2. **Library vs hand-roll.** `openid-client` (recommended — handles discovery, PKCE, JWKS, refresh,
   validation; would be the **first runtime dep**) vs hand-rolling PKCE against the project's
   minimal-deps stance. Recommendation: take the dep — hand-rolling token validation is the *inverse*
   over-engineering trap for security-critical code. Needs explicit sign-off.
3. **Does login gate the portal in the PoC?** Recommended **yes** ("no token ⇒ no portal"). Confirm.
4. **Pre-auth UI surface.** Auto-open the browser on start vs a local "Sign in with DTL" gate screen in
   the chrome renderer; and **whether any persistent auth/identity indicator belongs in M2 or is
   deferred to M3** (alongside the "managed by DTL" / kill-switch status).
5. **Exact Zitadel client config (per-machine).** Public/native PKCE app (no secret), redirect URIs,
   scopes (incl. `offline_access` for refresh), org/project, test user(s) — and **who provisions it on
   each dev box**.
6. **Company-account restriction claim.** Which claim/value enforces it — email domain
   (`@dytechlab.com`?), Zitadel **org id**, or a **role** claim? Depends on the Step-1 Zitadel setup.
7. **Token refresh strategy.** Lazy on-demand + on-launch (recommended, KISS) vs a proactive pre-expiry
   timer. Acceptable for the PoC?
8. **`safeStorage` on the NoMachine VM.** Is a secret service / keyring available **and unlocked** there,
   or will it also fall back to `basic_text`? Determines whether DoD-3's *encryption* can be truly
   verified on the VM or needs a different desktop.
9. **Session partition.** Recommendation is to keep the portal on `defaultSession` (so `wipe()` stays
   simple). Confirm — it changes the wipe targeting if reversed.
10. **Token "use" in the PoC.** The access token gates launch and is stored/wiped but, per E3, is **not**
    presented to the `:8443` fixture. Confirm that demonstrating login + secure storage + wipe is the
    intended M2 value (not token-authorized resource access).
