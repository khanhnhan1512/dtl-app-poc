# M1 — Kiosk shell: branding + home page + default-deny allow-list

> Detailed plan for **Milestone M1** of `plans/roadmap.md`. **Planning only — no code yet.**
> Per the CLAUDE.md two-tier gate, this plan is reviewed and approved *before* any code is written.
> Sources: roadmap M1 · techstack §2 (embedding, `will-navigate` / `setWindowOpenHandler`) ·
> brainstorm C3/C4 (kiosk + default-deny allow-list), feature 1 (branding) / feature 2 (home page).
> Builds directly on the **approved + verified M0** code in `src/main/` (cert handler, secure
> `webPreferences`, reusable `wipe()`).

## Goal

Turn the M0 spike (a bare window that loads a URL) into the **locked, single-purpose shell** the
user actually sees: it opens straight to the DTL portal, shows DTL branding, and behaves like a
kiosk — no address bar, tabs, bookmarks, history, or dev menu, same-window navigation only, and
**default-deny**: any navigation, redirect, or pop-up to a domain not on the allow-list is blocked.
M1 must do all this **without regressing M0** — the `select-client-certificate` handler must still
present the device cert to allow-listed hosts, and the renderer must stay locked down. OIDC (M2),
the mock backend + signed kill (M3), and OS-level packaging/branding (M4) are explicitly **out of M1**.

## Acceptance criteria (restated from roadmap M1)

1. **Home + locked window.** App opens directly to the configured home URL in a locked window — **no**
   address bar, tabs, bookmarks, or history menu.
2. **Branding visible.** DTL branding is visible (logo + product name); the app/window identity reads
   as **DTL**, not "Electron." *(OS-level branding — app icon, `.desktop` entry — is M4, not M1.)*
3. **Default-deny allow-list.** Allow-listed navigation succeeds **in the same window**; any
   navigation / redirect / pop-up to a **non-allow-listed** domain is **blocked** and observable.
4. **Renderer lockdown verified.** `contextIsolation` / `sandbox` / `nodeIntegration:false` /
   `webviewTag:false`, a narrow preload, `webSecurity` on; **no Node reachable from the portal view**.
   M0's mTLS still works (regression check).

## Prerequisites & key gotchas

- **Verification env (carried from M0):** GUI checks run on the **Ubuntu desktop VM** (`duccanh-test-pc.dtl`)
  via NoMachine — `dshell` is headless (`xvfb` fails: Chromium logind SIGTRAP). Code is built/pushed
  from `dshell`, pulled onto the VM. The redeploy tar **excludes `lab/certs/*`** (per-machine certs);
  do not overwrite them. Reuse the **M0 lab** (`:8443` designated, `:8444` non-designated) for nav tests.
- **`will-navigate` scope:** fires for **renderer-initiated top-level** navigations (link clicks,
  `location =`, form submits) — **not** for `webContents.loadURL()` called from Main (trusted), and
  **not** for sub-frame navigations. So the initial home load is never self-blocked. Sub-frames =
  `will-frame-navigate` (optional hardening; portals are top-level per brainstorm E3, so out of the
  PoC critical path).
- **`will-redirect` is mandatory too:** an allow-listed page can 30x-redirect to an external host;
  `will-navigate` alone misses server redirects. Enforce the allow-list in **both**.
- **`preventDefault()` blocks; it does not "stay put" automatically** — after blocking, the view simply
  remains on the current page. That is the desired, observable "blocked" behaviour.
- **`setWindowOpenHandler` must return `{ action: 'deny' }`** for every pop-up (no new windows/tabs).
  To honour "links open in the same window" (brainstorm C3), if the requested URL is allow-listed,
  load it into the **existing** view before returning `deny`.
- **Window title hijack:** a plain `BrowserWindow` adopts the loaded page's `<title>` (would read as
  the portal, not "DTL") unless you intercept `page-title-updated`. `BaseWindow` + `WebContentsView`
  does **not** auto-adopt the child view's title — one reason to prefer it (see Architecture).
- **mTLS must not regress:** the cert handler is registered as `app.on('select-client-certificate')`
  — **app-global**, fires for any `webContents`. It keeps working under `WebContentsView` unchanged.
  Carry the **same secure `webPreferences`** onto every view. **Never** touch the M0 cert/wipe logic
  except a DRY host-parsing refactor (see Step 2), which must be re-verified against M0 criteria.
- **Dev vs prod gating:** DevTools / shortcut locks must be off in `dev` (we need them to debug) and on
  in a "production" build. Until M4 packaging, `app.isPackaged` is always false, so gate on
  **`process.env.NODE_ENV === 'development'`** (electron-vite sets it) — verify the locked behaviour
  with `npm run build && electron .`, not `npm run dev`.
- **No new runtime deps.** M1 is standard Electron API only (KISS) — no new npm packages.

## Architecture (M1 shape)

**Embedding decision (the call M0 deferred) → recommend `BaseWindow` + `WebContentsView`.**
techstack §2 names it the primary primitive; §5 marks the choice **reversible**. Reasoning:

- M1 criterion 2 needs the **logo persistently visible *beside* the portal**. In a single
  `BrowserWindow` the one web view is the portal — the only ways to show persistent branding are to
  inject DOM into the portal page (fragile, touches third-party content) or accept a vanish-on-load
  splash. Two `WebContentsView`s — a thin **chrome bar** (our trusted local renderer: logo + product
  name) above a **portal view** (the remote home URL) — solves it cleanly.
- `BaseWindow` keeps the **window title** under our control (no portal-title hijack).
- It sets up M2 (auth state) / M3 ("managed by DTL" indicator) with no rework.

**Cost & reversibility (KISS honesty):** it is modestly more code than `BrowserWindow` (manual view
layout + a `resize` handler). The increment is small, it is the recommended primitive, and reverting
to a single `BrowserWindow` later is mechanical. The plan isolates the window construction in
`src/main/window.js` so the choice is swappable in one file.

```
BaseWindow  (title "DTL Secure Browser", app.setName)
├── chromeView  : WebContentsView  → local renderer (DTL logo + product name)   [~48px tall, top]
└── portalView  : WebContentsView  → HOME_URL (remote, mTLS)                     [fills the rest]
       │  secure webPreferences (contextIsolation/sandbox/nodeIntegration:false/webviewTag:false)
       │  navigation lockdown: will-navigate + will-redirect + setWindowOpenHandler  (NAV_ALLOWLIST)
       └─ triggers app.on('select-client-certificate')  ← M0, unchanged
```

- **Process separation unchanged:** all privilege stays in Main; both views are isolated; the preload
  stays empty (no privileged API needed in M1).
- **Two allow-lists, distinct on purpose, both in `config.js`:** `MTLS_ALLOWLIST` (M0 — hosts that get
  a *client cert*) and **`NAV_ALLOWLIST`** (M1 — hosts the user may *navigate to*). They overlap but
  are not the same concept; keeping them separate avoids coupling "can go here" to "present a cert here."

## Sub-steps (ordered: retire structural risk → core security feature → lock the shell → easy win)

> Order mirrors M0 (highest-uncertainty first; branding last, per brainstorm A2 "branding/home page
> are the easy wins"). Each step is independently verifiable on the VM before the next.

### Step 1 — Migrate window structure to `BaseWindow` + `WebContentsView` (retire structural risk)

- **Files:**
  - `src/main/window.js` *(new)* — `createShell()`: builds the `BaseWindow`, one `portalView`
    `WebContentsView` with the **exact M0 secure `webPreferences`** (+ the existing preload),
    `addChildView`, a `layout()` that sizes the portal to the full content area, a `resize` listener,
    and `portalView.webContents.loadURL(HOME_URL)`. (Chrome bar added in Step 4.)
  - `src/main/index.js` *(modify)* — replace the `BrowserWindow` block with `createShell()`; **keep**
    `app.on('select-client-certificate', handleCertSelect)` and the `--wipe` branch exactly as-is.
  - `src/main/config.js` *(modify)* — rename/add `HOME_URL` (= the current `TARGET_URL`/`PROTECTED_URL`,
    env-overridable) so "home page" is named per its M1 role.
- **What it does:** proves the new embedding primitive renders the portal **and that M0 mTLS still
  fires** through a `WebContentsView` — the one genuinely uncertain structural change in M1.
- **Verify (VM):** `npm run dev` → window opens, portal loads from `:8443`, page shows
  `verify=SUCCESS … CN=DTL-Ubuntu-Test-Device`, terminal logs `[cert-select] ALLOWED — localhost:8443`.
  **This is the M0 regression gate** — do not proceed until mTLS is confirmed under `WebContentsView`.

### Step 2 — Default-deny navigation allow-list (retire the core M1 security risk)

- **Files:**
  - `src/main/config.js` *(modify)* — add **`NAV_ALLOWLIST`** (host:port entries, same shape as
    `MTLS_ALLOWLIST`; PoC value `['localhost:8443']`). Env-overridable for tests.
  - `src/main/allowlist.js` *(new, small DRY refactor)* — `extractHost(url)` (moved from
    `cert-select.js`, which already needs the bare-`host:port` fix) + `isAllowed(url, list)`.
    `cert-select.js` *(modify)* imports `extractHost` from here instead of defining its own — **must
    re-verify M0 criteria 1–2 after** (behaviour unchanged, just relocated).
  - `src/main/navigation.js` *(new)* — `applyNavigationLockdown(webContents)`:
    - `on('will-navigate', (e,url) => { if(!isAllowed(url,NAV_ALLOWLIST)){ e.preventDefault(); log BLOCKED } })`
    - `on('will-redirect', …)` — same check (server-side redirects).
    - `setWindowOpenHandler(({url}) => { if(isAllowed(url,NAV_ALLOWLIST)) webContents.loadURL(url); return { action:'deny' } })`
      — no new windows ever; allow-listed pop-up targets load **in the same view** (honours C3).
  - `src/main/window.js` *(modify)* — call `applyNavigationLockdown(portalView.webContents)`.
  - `lab/nginx/nav-test.html` + `lab/nginx/mtls.conf` *(modify, test fixture only)* — serve a tiny
    page on `:8443` with links: same-host path (allow), `https://localhost:8444/` (block — not in
    NAV_ALLOWLIST), `https://example.com/` (block), and one `target="_blank"` to an allow-listed host
    (must open in-window, not a pop-up). `lab/README.md` *(modify)* — document the nav-test page.
- **What it does:** the heart of M1 — enforces brainstorm C4 default-deny at the navigation layer.
- **Verify (VM, reuse M0 lab):**
  - Click the same-host link → loads (allow-listed nav succeeds, same window) → **criterion 3a**.
  - Click `:8444` and `example.com` links → page does **not** change; terminal logs `[nav] BLOCKED …`
    → **criterion 3b** (blocked + observable; note `example.com` is blocked *before* any network call,
    so the VM needs no internet).
  - Click the `target="_blank"` allow-listed link → loads **in the same view**, no second window.
  - Re-run M0 checks: `:8443` still `verify=SUCCESS` (allow-list refactor didn't regress mTLS).

### Step 3 — Lock the shell (no menu / no DevTools / no escape shortcuts)

- **Files:**
  - `src/main/index.js` *(modify)* — `Menu.setApplicationMenu(null)` (removes the default
    File/Edit/View/Window menu incl. *Toggle DevTools*, *Reload*, *Force Reload*).
  - `src/main/window.js` *(modify)* — set `webPreferences.devTools` to **false in production**
    (`NODE_ENV !== 'development'`) on both views; add a `before-input-event` guard on
    `portalView.webContents` (production only) that swallows `Ctrl+R` / `F5` (reload),
    `Ctrl+Shift+I` / `F12` (DevTools), `Alt+←` / `Alt+→` (history), `Ctrl+L` (address focus — none
    exists, defensive). Dev keeps them for debugging.
  - *(Optional)* `src/main/shortcuts.js` *(new)* — the key blocklist, if it reads cleaner than inline.
- **What it does:** delivers the "locked window — no tabs/address bar/bookmarks/dev menu" half of
  criterion 1. (No address bar / tabs / bookmarks exist because we never build them — the lockdown is
  about removing the *default* affordances Electron ships and the keyboard escapes.)
- **Verify (VM):** `npm run build && electron .` → no application menu; `Ctrl+Shift+I` / `F12` open
  nothing; `Ctrl+R` / `F5` do not reload; `Alt+←` does not go back. In `npm run dev`, DevTools still
  open (confirming the dev/prod gate works).

### Step 4 — Branding: chrome bar + window/app identity (the easy win, last)

- **Files:**
  - `src/renderer/index.html` + `src/renderer/src/main.js` *(modify)* — repurpose the idle M0 scaffold
    into the **chrome bar**: DTL logo + product name on a thin branded strip (static, no logic).
  - `src/renderer/assets/logo.svg` *(new)* — placeholder DTL logo (simple wordmark/mark acceptable for
    a PoC; generate if no brand asset is supplied).
  - `src/main/config.js` *(modify)* — `PRODUCT_NAME = 'DTL Secure Browser'` (name TBD — open question).
  - `src/main/window.js` *(modify)* — add `chromeView` `WebContentsView` (loads the local renderer:
    dev → `ELECTRON_RENDERER_URL`, prod → `loadFile(out/renderer/index.html)`, mirroring the M0
    dev/prod branch); update `layout()` to reserve `~48px` for the chrome bar and place the portal
    below it; set the `BaseWindow` title to `PRODUCT_NAME`.
  - `src/main/index.js` *(modify)* — `app.setName(PRODUCT_NAME)` **before** `whenReady`.
  - `package.json` *(modify)* — add `"productName": "DTL Secure Browser"` (harmless now; electron-builder
    consumes it in M4).
- **What it does:** delivers criterion 2 — persistent in-app branding + a window/app identity that
  reads DTL, not Electron.
- **Verify (VM):** launch → a DTL logo + product name strip sits above the portal, persistent across
  navigation; window title reads "DTL Secure Browser"; portal still renders `verify=SUCCESS` below
  the bar; resizing the window keeps the layout (chrome fixed height, portal fills the rest).

## Risk assessment

- **R1 — mTLS regresses under `WebContentsView`** (the only real structural unknown). *Mitigation:*
  Step 1 is gated on re-confirming `verify=SUCCESS` before any further M1 work; cert handler is
  app-level and untouched.
- **R2 — `will-navigate` gaps** (sub-frames, `will-redirect`, in-page hash). *Mitigation:* enforce both
  `will-navigate` **and** `will-redirect`; note `will-frame-navigate` as optional hardening (portals are
  top-level per E3, so not on the PoC critical path); hash nav stays on an allow-listed origin (benign).
- **R3 — Over-blocking breaks the portal** (e.g. an internal SSO 30x to a host we forgot to list).
  *Mitigation:* default-deny + an explicit, easily-edited `NAV_ALLOWLIST`; every block is logged so a
  legitimate-but-missing host is visible immediately. (For the PoC the home is the self-contained M0
  fixture, so this is low.)
- **R4 — DRY refactor of `extractHost` regresses M0.** *Mitigation:* move-only, no behaviour change;
  re-run M0 criteria 1–2 in Step 2's verify.
- **R5 — `BaseWindow` view layout bugs** (portal mis-sized, gap/overlap on resize). *Mitigation:*
  single `layout()` recomputed on `resize`; visually confirmed on the VM in Step 4.
- **R6 — dev/prod gate confusion** (DevTools locked in dev, or open in "prod"). *Mitigation:* gate on
  `NODE_ENV`; verify both `npm run dev` (open) and `npm run build && electron .` (locked).

## Security considerations (PoC scope)

- **No regression of M0's posture:** both views keep `contextIsolation:true`, `sandbox:true`,
  `nodeIntegration:false`, `webviewTag:false`; preload stays empty; **`webSecurity` never disabled**.
- **Default-deny is the safe default:** unknown hosts are blocked, not allowed — the allow-list is the
  only way in. New windows/tabs are categorically denied.
- All navigation control lives in **Main** (`navigation.js`), never in renderer/portal content.
- **Out of scope (unchanged):** no DLP — M1 does **not** block downloads, DevTools-via-portal-content,
  copy/paste, or screenshots (brainstorm H2). "Locked shell" here = removing browser chrome + escape
  shortcuts + off-allow-list navigation, **not** content-level DLP.
- Branding assets are placeholders; no secrets introduced. The chrome view loads only **local** content.

## Definition of Done (mirrors roadmap M1)

- [ ] **DoD-1** — App launches straight to `HOME_URL` in a locked window: **no** address bar, tabs,
  bookmarks, history menu, or application menu; DevTools + reload/back shortcuts disabled in a prod build.
- [ ] **DoD-2** — DTL branding visible (logo + product name); window title + `app.setName` read
  "DTL Secure Browser", not "Electron". *(OS icon / `.desktop` deferred to M4.)*
- [ ] **DoD-3** — Allow-listed navigation succeeds in the **same window**; navigation **and** redirect
  **and** `window.open` to a non-allow-listed host are **blocked** and logged (default-deny).
- [ ] **DoD-4** — Renderer lockdown intact on both views (`contextIsolation`/`sandbox`/
  `nodeIntegration:false`/`webviewTag:false`, empty preload, `webSecurity` on); no Node reachable from
  the portal.
- [ ] **DoD-5 (regression)** — M0 still passes: `:8443` → `verify=SUCCESS`, cert handler fires through
  the `WebContentsView`; `wipe()` untouched.
- [ ] Window construction isolated in `src/main/window.js` so the `BaseWindow`↔`BrowserWindow` choice
  stays reversible; no new npm runtime deps.

## Next steps (after approval)

- Implement Steps 1 → 4 in order, verifying each on the VM before proceeding (Step 1 is the M0
  regression gate; Step 2 gates Step 4's layout).
- On M1 sign-off, write the detailed **M2 (OIDC, system browser + PKCE)** plan — gated, one milestone
  at a time.

## Open questions (flagged — not guessed)

1. **`NAV_ALLOWLIST` format/contents.** Recommend a `host:port` set (matching `MTLS_ALLOWLIST`),
   PoC value `['localhost:8443']`. Confirm: host-only vs scheme/path-aware? Should it be a *superset*
   that includes `MTLS_ALLOWLIST`, or fully independent? (Plan assumes independent, host:port.)
2. **Home URL target for the PoC.** Recommend keeping the **self-contained M0 fixture** (`:8443`) as
   `HOME_URL` — a real `.dtl` portal is HTTP-only *and* unreachable from the VM without NetBird. Confirm
   we are not expected to point M1 at a live internal portal.
3. **Branding approach + logo asset.** Plan recommends a **persistent chrome bar** (drives the
   `BaseWindow` + `WebContentsView` choice). Confirm that vs a minimal title-only/splash approach
   (which would allow staying on `BrowserWindow`). Also: is there a real **DTL logo asset**, or is a
   generated placeholder acceptable for the PoC? And the exact **product name** ("DTL Secure Browser"?).
4. **`BaseWindow` vs `BrowserWindow` final call.** Recommendation is `BaseWindow` + `WebContentsView`
   (reasoning above; reversible). Flagging for explicit sign-off since techstack marks it reversible
   and M0 used plain `BrowserWindow`.
5. **"Kiosk" = locked normal window vs forced fullscreen (`kiosk:true`).** Plan assumes a **normal,
   resizable, locked** window (brainstorm C3 = "just a window showing the portal"), not OS fullscreen
   kiosk mode. Confirm fullscreen lock is **not** required for the PoC.
6. **`window.open` / `target="_blank"` to an allow-listed host.** Plan loads it **in the same view**
   (no new window) to honour C3. Confirm that's the desired behaviour vs silently dropping it.
