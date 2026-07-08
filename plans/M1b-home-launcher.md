# M1b — Home launcher + three access-outcome screens

> Detailed plan for a **follow-on to Milestone M1** (`plans/M1-kiosk.md`), on branch
> `improve-ui-ux`. **Planning only — no code yet.** Per the CLAUDE.md two-tier gate, this plan is
> reviewed and approved *before* any code is written. Not a new roadmap milestone number — it
> revises M1's home-page concept ("load the portal URL directly") into a branded local launcher
> with multiple tools and three demonstrable access outcomes. Builds on the **approved + verified**
> M0–M4 code; must not regress M0 (cert selection), M2 (OIDC gate), M3 (kill switch), or M4
> (`[session]` identity line, `.deb` packaging).

## Goal

Replace the current "portal loads `HOME_URL` directly into `portalView`" behaviour with a local
branded home launcher (tool tiles) and three observable access outcomes: mTLS success (tool-1),
mTLS refusal by the server (tool-2, always-403 for this device), and app-layer navigation block
(outbound link inside tool-1). The chrome bar becomes dynamic — title/subtitle and a status badge
reflect whichever of the four states the portal is currently in (home / verified / blocked /
address-not-permitted).

## Fixed decisions (given, not re-litigated)

Restated from the task brief — these are inputs to this plan, not open questions:

1. Home page = local branded launcher, tiles `tool-1…tool-6` (generic labels), only `tool-1`/`tool-2` live.
2. `tool-1` → `https://localhost:8443`, cert accepted, HTTP 2xx → green "Device verified".
3. `tool-2` → new `https://localhost:8445`, cert presented but server's approved-CN list excludes
   `DTL-Ubuntu-Test-Device` → always HTTP 403 → red "Device blocked". One direction only, no toggle.
4. Nav-block demo is an outbound link **inside tool-1's page** to `https://market-data.example.com`
   (off-allowlist) → blocked at `will-navigate`/`will-redirect`, local amber page, **badge stays green**.
5. Persistent chrome bar (~52px): logo + "DTL App", live badge, identity indicator (device CN + user
   email). Neutral badge on home; green/red only inside a tool.
6. Colour/badge table, appendix markup (CSS tokens, chrome bar, home launcher, nginx tool page,
   access-denied page, address-not-permitted page) — reproduced **exactly**, light-mode only.

## Current state (as-built context, so implementation doesn't have to re-derive it)

- `src/main/window.js`: `createShell()` builds `chromeView` + `portalView` on one `BaseWindow`, both
  sharing one `webPreferences` object (including one preload, `src/preload/index.js`, currently
  empty). `portalView.webContents.loadURL(HOME_URL)` fires unconditionally on startup (after the
  M2 auth gate) — there is **no local home page today**; the portal goes straight to the mTLS
  fixture.
- `src/main/config.js`: `HOME_URL = process.env.DTL_TARGET_URL || 'https://localhost:8443'`,
  `MTLS_ALLOWLIST = ['localhost:8443']`, `NAV_ALLOWLIST = ['localhost:8443']` (env-overridable).
- `src/main/navigation.js` (`applyNavigationLockdown`): `will-navigate` / `will-redirect` /
  `setWindowOpenHandler` check `isAllowed()` (from `src/main/allowlist.js`) and `preventDefault()` +
  `console.log` on block — **no page swap, no chrome feedback today**.
- `src/main/index.js`: `ensureAuthenticated()` gates `createShell()` (M2). After shell creation, a
  `web-contents-created` → `did-navigate` hook checks `url.startsWith(HOME_URL)` and either calls
  `logSessionIdentity()` (2xx) or logs "transport blocked" (non-2xx) — **this is the M4 hook the
  task says to extend**, currently pure observability, no UI effect.
- `src/main/cert-select.js`: scopes purely off `MTLS_ALLOWLIST` (host-generic) — **needs no changes**;
  adding `localhost:8445` to `MTLS_ALLOWLIST` is sufficient for it to present the cert there too.
- `src/renderer/index.html` + `src/renderer/src/main.js`: static chrome bar (logo + "DTL App" text
  only, dark navy bar) — no dynamic state, no preload API.
- `src/preload/index.js`: empty (no privileged API exposed) — shared by both views today.
- `electron.vite.config.mjs`: no explicit preload entry list (default single `src/preload/index.js`).
- `lab/nginx/mtls.conf`: `:8443` (`ssl_verify_client on`, root = plain-text `verify=… subject=…`,
  `/nav` = the M1 nav-test page) and `:8444` (`ssl_verify_client optional`, root = plain text,
  `/kill` = M3 signed kill-command). Container run command (`lab/README.md`) maps `-p 8443:8443
  -p 8444:8444` only.

## Architecture

### Config (`src/main/config.js`)

- `MTLS_ALLOWLIST = ['localhost:8443', 'localhost:8445']`
- `NAV_ALLOWLIST = (process.env.DTL_NAV_ALLOWLIST || 'localhost:8443,localhost:8445').split(',')`
  (the external `market-data.example.com` host is deliberately **not** added — it is the block target)
- Replace the single `HOME_URL` export with a `TOOLS` map (tile → target URL or `null` for
  placeholders), keeping the existing `DTL_TARGET_URL` env override for tool-1 (backward compat with
  M1/M2/M4 docs that reference overriding the portal target):
  ```js
  export const TOOLS = {
    'tool-1': process.env.DTL_TARGET_URL || 'https://localhost:8443',
    'tool-2': 'https://localhost:8445',
    'tool-3': null, 'tool-4': null, 'tool-5': null, 'tool-6': null,
  }
  ```
- `CERT_SUBJECT_CN`, `KILL`, `OIDC` unchanged.

### Lab (`lab/nginx/mtls.conf`, `lab/README.md`)

- **`:8443` root location**: replace the bare `verify=$ssl_client_verify …` echo with the static
  internal-tool page (Appendix C), inline `return 200 '<html>…'` (same style already used for `/nav`)
  — includes its own `<style>:root{…}</style>` copy of the CSS tokens (nginx has no access to the
  Electron bundle's stylesheet; a small duplicated token block is the pragmatic KISS call here, not
  a shared-asset pipeline). Keep the existing `/nav` location untouched (M1 regression fixture).
- **New `:8445` server block**: copy of `:8443`'s TLS settings (`ssl_verify_client on`, same
  cert/key/CA), plus a CN gate in the root location:
  ```nginx
  location / {
      default_type text/plain;
      if ($ssl_client_verify != SUCCESS) {
          return 400 "verify=$ssl_client_verify subject=$ssl_client_s_dn";
      }
      if ($ssl_client_s_dn !~ "CN=DTL-Approved-Device") {
          return 403 "verify=$ssl_client_verify subject=$ssl_client_s_dn — device not approved for tool-2";
      }
      return 200 "verify=$ssl_client_verify subject=$ssl_client_s_dn";
  }
  ```
  `DTL-Approved-Device` never matches the provisioned test cert (`CN=DTL-Ubuntu-Test-Device`), so
  this device is **always** 403 here — matching decision 3 exactly, no toggle, no new cert needed.
- **`:8444` unchanged** (M3 kill endpoint + optional-mTLS regression fixture).
- `lab/README.md`: add `-p 8445:8445` to both the initial `podman run` and the "conf changed, restart
  container" commands; add `:8445` curl checks (400 no-cert scenario doesn't apply here since the app
  always presents the cert — the relevant checks are: with-cert → 403; confirm 400 only if cert
  omitted, for completeness parity with `:8443`).

### Main process wiring

- **`src/main/chrome-state.js` (new)** — the only new Main module; keeps `window.js` from bloating
  and mirrors the existing one-concern-per-file style (`navigation.js`, `allowlist.js`, …):
  - `TOOL_HOSTS`: reverse-derived from `TOOLS` (`extractHost(url) → label`), skipping `null` entries.
  - `CHROME_STATE_CHANNEL` / `CHROME_GO_HOME_CHANNEL` — IPC channel name constants (single source of
    truth shared between `window.js` and `src/preload/chrome.js`).
  - `buildState({ kind, label, userEmail })` → the small state object pushed to `chromeView`
    (`{ title, subtitle, badge, showBack, deviceCN, userEmail }`) for the four `kind`s: `home`,
    `tool-ok`, `tool-blocked`, and a no-op default for anything else (address-not-permitted pages and
    other Main-initiated local loads simply don't match a tool host or the home path, so the default
    branch — "leave the last state as-is" — requires no special-casing; see Decision 4 below).
- **`src/main/window.js` (modify)**:
  - `createShell({ userEmail })` — new required param (the OIDC email from `ensureAuthenticated()`,
    needed for the identity indicator).
  - Two `webPreferences` variants: `chromeWebPrefs` (preload → `src/preload/chrome.js`) and
    `portalWebPrefs` (preload → existing empty `src/preload/index.js`, **unchanged** — the portal
    renders both trusted local pages and (allow-listed) remote content and must never get a
    privileged preload).
  - `portalView.webContents.loadFile(homePagePath)` replaces `loadURL(HOME_URL)` on startup.
  - `applyNavigationLockdown(portalView.webContents, { onBlocked: (url) => portalView.webContents
    .loadFile(addressNotPermittedPath, { query: { url } }) })` — extends `navigation.js` with an
    optional callback (see Decision 2).
  - `did-navigate` listener registered directly on `portalView.webContents` (moved out of `index.js`'s
    generic `app.on('web-contents-created')`, which today only *happens* to be safe because
    `chromeView`'s URL never matches `HOME_URL` — moving it removes that accidental coupling):
    - URL host in `TOOL_HOSTS` + 2xx → `logSessionIdentity(...)` (unchanged M4 log line, now fires for
      any successful mTLS host, not just the old single `HOME_URL`) + push `tool-ok` state (green).
    - URL host in `TOOL_HOSTS` + non-2xx → `console.log('[session] transport blocked …')` (unchanged
      text) + `portalView.webContents.loadFile(accessDeniedPath, { query: { code: httpResponseCode }
      })` + push `tool-blocked` state (red).
    - URL is the local home page → push `home` state (neutral, `showBack:false`).
    - anything else (address-not-permitted page, access-denied page reloading itself, chrome's own
      navigation) → no matching branch, **no state push** — last state stands (Decision 4).
  - `ipcMain.on(CHROME_GO_HOME_CHANNEL, () => portalView.webContents.loadFile(homePagePath))` — back
    arrow handler; the resulting `did-navigate` to the home path drives the neutral state push above,
    so no separate "reset" call is needed.
- **`src/main/navigation.js` (modify)**: `applyNavigationLockdown(webContents, { onBlocked } = {})`
  — after each existing `preventDefault()` + log, call `onBlocked?.(url)` if provided. No behaviour
  change when the callback is omitted (keeps the function's existing contract intact for any other
  caller).
- **`src/main/index.js` (modify)**: delete the `web-contents-created`/`did-navigate` block entirely
  (moved into `window.js`); `createShell({ userEmail: sessionEmail })`.

### Preload

- **`src/preload/chrome.js` (new)** — narrow `contextBridge` API, chrome bar only:
  ```js
  contextBridge.exposeInMainWorld('dtlChrome', {
    onState: (cb) => ipcRenderer.on(CHROME_STATE_CHANNEL, (_e, state) => cb(state)),
    goHome: () => ipcRenderer.send(CHROME_GO_HOME_CHANNEL),
  })
  ```
  Channel name constants imported from `src/main/chrome-state.js` (plain string constants, safe to
  share across the main/preload boundary — no Node/Electron API leakage).
- **`src/preload/index.js`** — **unchanged** (still empty; portal content never gets `dtlChrome`).

### Renderer

- **`src/renderer/index.html` + `src/renderer/src/main.js`** (Vite-processed, chrome bar only):
  rebuilt to Appendix A's structure/tokens — dynamic `#chrome-title`/`#chrome-subtitle`, badge pill
  (neutral/green/red via `dtlChrome.onState`), identity avatar + email/CN (from the first state push
  — identity doesn't change mid-session), back arrow (hidden on `showBack:false`) wired to
  `dtlChrome.goHome()`.
- **`src/renderer/public/pages/`** (new — **not** Vite-processed; Vite's `publicDir` copies these
  verbatim into `out/renderer/`, so they can be `loadFile()`d as plain static HTML with no build step):
  - `tokens.css` — the shared `:root` token block + `.pill` class from the appendix, linked by all
    three pages below (avoids triplicating the token list — the one bit of sharing that's cheap here).
  - `home.html` — Appendix B tiles (plain `<a href="https://…">` for tool-1/tool-2 — a top-level nav
    to an already-allow-listed host needs **no** JS/IPC at all; `will-navigate` just lets it through).
    Placeholder tiles (`tool-3…6`) are plain `<div>`s, no `href`, no handler.
  - `access-denied.html` — Appendix D; reads `?code=` from `location.search` to fill in the HTTP code
    line (400 vs 403) instead of hardcoding 403.
  - `address-not-permitted.html` — Appendix E; reads `?url=` from `location.search` for the "blocked:
    …" line.
  - Icons: inline SVG (Tabler-equivalent glyphs: arrow-left, device-desktop, lock, lock-off,
    app-window, clock, shield-check, shield-x, server-off, ban, link-off) duplicated per page where
    used — no icon-font dependency, no CDN, no new npm package (see Decision 5).

### `electron.vite.config.mjs`

- Add an explicit multi-entry `preload.build.rollupOptions.input` (`index` + `chrome`) so both
  preload scripts are built; verify the exact output filenames (`out/preload/index.js` /
  `chrome.js` vs `.mjs`) empirically in Step 1 and adjust `window.js`'s `join(__dirname, ...)`
  paths to match — electron-vite's default output extension isn't being guessed here, it's checked.

## Decisions (resolved before implementation)

1. **`HOME_URL` → `TOOLS` map.** Small blast radius confirmed (`grep -rn HOME_URL src/`): only
   `window.js` and `index.js` reference it. Replacing it is cleaner than bolting a tile map on top of
   a name that no longer means "the page we load first."
2. **`will-navigate`/`will-redirect` block → local page swap via an optional callback**, not a new
   event or a chrome-side responsibility. `navigation.js` stays purely "allow/deny + log"; the page
   swap is `window.js`'s call (it already owns `portalView`). `setWindowOpenHandler` is **not** wired
   to this callback — the task's nav-block demo is a same-window link, not a `window.open`.
3. **`webContents.loadFile(path, { query })` for dynamic error-page text**, not IPC, not a templating
   step. Both local pages are otherwise fully static; a query-string + `location.search` read in a
   ~5-line inline `<script>` is the smallest mechanism that avoids hardcoding the wrong HTTP code.
4. **No explicit "reset to green" logic on nav-block.** Because the address-not-permitted load is
   itself a `loadFile()` call, it fires `did-navigate` too — but its URL matches neither a tool host
   nor the home path, so the existing state-push logic's default (no branch matched → don't push)
   already leaves the last pushed state (green, from tool-1) untouched. Verified as correct by
   tracing the decision table, not by adding a special case.
5. **Icons: inline SVG, not the Tabler webfont.** The task's own guardrail permits "the Tabler icon
   font **or equivalent SVGs**." A font requires either a new npm package (conflicts with the
   project's no-new-runtime-deps discipline) or downloading font files from a CDN (explicitly
   forbidden). ~11 small inline `<svg>` glyphs, duplicated across 3 static pages, is the KISS choice
   for a PoC — no build step, no license file to vendor, no network fetch from `dshell`.
6. **CSS token duplication between the Electron static pages and the nginx-served tool-1 page is
   accepted.** They're genuinely different delivery mechanisms (bundled local files vs. a string
   returned by nginx) — sharing one file across both would need a build/copy step disproportionate to
   a ~15-line `:root` block. `src/renderer/public/pages/tokens.css` (one shared file) still applies
   *within* the Electron app's three local pages.
7. **`logSessionIdentity()` now fires for any 2xx mTLS host**, not only the historical `HOME_URL`
   host. Since `tool-2` never returns 2xx in this design (always 403), this is a behavior-preserving
   generalization for `tool-1` and a no-op-in-practice extension for `tool-2` — not scope creep.

## Related files

**New:**
- `src/main/chrome-state.js`
- `src/preload/chrome.js`
- `src/renderer/public/pages/tokens.css`
- `src/renderer/public/pages/home.html`
- `src/renderer/public/pages/access-denied.html`
- `src/renderer/public/pages/address-not-permitted.html`

**Modified:**
- `src/main/config.js` (allowlists, `TOOLS` map)
- `src/main/window.js` (two preloads, home page load, did-navigate move + generalize, IPC handler)
- `src/main/navigation.js` (`onBlocked` callback param)
- `src/main/index.js` (remove moved hook, pass `userEmail`)
- `src/renderer/index.html`, `src/renderer/src/main.js` (dynamic chrome bar)
- `electron.vite.config.mjs` (preload multi-entry)
- `lab/nginx/mtls.conf` (`:8443` page swap, new `:8445` block)
- `lab/README.md` (port mapping, curl checks)

**Untouched (regression-critical):** `src/main/cert-select.js`, `src/main/wipe.js`,
`src/main/allowlist.js` (functions reused as-is), `src/main/auth/**`, `src/main/kill/**`,
`src/main/session-identity.js` (function signature unchanged, just called from a new call site).

## Implementation steps (each verified on the VM before the next)

1. **Config + lab first (curl before app).** Update `config.js` (`TOOLS`, allowlists), `mtls.conf`
   (`:8443` page swap + new `:8445` block), `lab/README.md`. Deploy conf to VM, restart the nginx
   container, curl-verify all three ports (see Verification plan) — **before touching any Electron
   code.**
2. **Preload + vite config.** Add `src/preload/chrome.js`, wire the multi-entry preload build, run
   `npm run build`, inspect `out/preload/` to confirm both files exist and note actual filenames.
3. **Main wiring.** `chrome-state.js`, `window.js` (two preloads, `did-navigate` move, IPC handler,
   `loadFile` for the home page), `navigation.js` (`onBlocked`), `index.js` (remove old hook, pass
   `userEmail`). Build + launch on the VM; confirm no crash, home page loads (even with a bare/unstyled
   page at this point — static pages land in Step 4).
4. **Static pages + chrome bar UI.** `public/pages/*`, `tokens.css`, updated `index.html`/`main.js`.
   Build + full GUI verification pass (see below).
5. **Regression pass.** M0 cert presentation, M2 login gate, M3 kill (wipe + lockout), M4 `[session]`
   line — all four, explicitly, before declaring done.

## Verification plan (VM, before any commit)

**curl (with the provisioned test cert):**
```bash
cd ~/Downloads/dtl-app/lab/certs
curl -s --cacert ca.pem --cert client.crt --key client.key https://localhost:8443/    # expect 2xx, Appendix C page
curl -s -o /dev/null -w "%{http_code}\n" --cacert ca.pem --cert client.crt --key client.key https://localhost:8445/   # expect 403
curl -s --cacert ca.pem https://localhost:8444/                                       # expect verify=NONE (unchanged M3 fixture)
```

**GUI (NoMachine):**
- Launch → home launcher renders (tiles, neutral "Managed device" badge, identity shows CN + email).
- Click `tool-1` → Appendix C page renders inside portal, badge → green "Device verified", chrome
  title → `tool-1`.
- Click the outbound link on the tool-1 page → address-not-permitted page (amber), badge **stays
  green**, blocked URL shown matches `market-data.example.com`.
- Back arrow → home launcher, badge → neutral.
- Click `tool-2` → access-denied page (red "Device blocked"), HTTP code shown = 403.
- `tool-3…6` tiles: no-op on click, "Coming soon" styling.

**Regression:**
- M0: cert still presented to `:8443` (curl above + GUI tool-1 success).
- M2: cold start still requires OIDC login before the shell appears.
- M3: kill command still wipes cert + tokens and locks out `:8443`/`:8445` afterward.
- M4: `[session] device=… user=…` line still logs on tool-1 success.

## Security considerations

- No change to renderer isolation posture: both `chromeView` and `portalView` keep
  `contextIsolation:true`, `sandbox:true`, `nodeIntegration:false`, `webviewTag:false`.
- The new `chrome.js` preload exposes exactly two functions (`onState`, `goHome`) — no generic
  `ipcRenderer` passthrough, no filesystem/Node access. `portalView`'s preload is untouched (empty).
- All navigation/allow-list decisions remain Main-only (`navigation.js`, `allowlist.js`,
  `cert-select.js`); the local static pages contain no logic that decides what's allowed — they only
  render outcomes already decided by Main.
- `:8445`'s CN gate is a **lab-only** demo mechanism (nginx `if` on `$ssl_client_s_dn`), not a
  production authorization model — consistent with the PoC's existing mock-backend posture.
- No secrets, no new external network calls, no CDN assets.

## Definition of Done

- [ ] Home launcher shows on cold start (local `loadFile`, not `HOME_URL`/`TOOLS['tool-1']` directly).
- [ ] `tool-1` → 2xx → Appendix C page + green badge + `[session]` line logs.
- [ ] `tool-2` → 403 → local access-denied page + red badge, HTTP code shown matches actual response.
- [ ] Outbound link inside tool-1 → local address-not-permitted page, badge stays green, blocked URL matches.
- [ ] Back arrow returns to home launcher, badge resets to neutral.
- [ ] `tool-3…6` tiles are inert.
- [ ] Chrome bar matches Appendix A layout/colours/copy; identity indicator shows CN + email.
- [ ] No new npm runtime dependency; no icon CDN.
- [ ] M0/M2/M3/M4 regression checks all pass.
- [ ] `lint --check` and `make test` still pass.

## Confirmations from review (2026-07-08 — plan approved with these folded in)

1. **`:8443` body-swap regression, checked.** `grep -rn "verify=\$ssl_client_verify\|verify=SUCCESS\|verify=NONE"` across `src/`, `docs/`, `plans/`, `lab/`, `Makefile` — every hit is a **human-readable** instruction in a plan/README telling a person to eyeball `verify=SUCCESS` in curl output; `make test` is the no-op stub (confirmed earlier this session), nothing automated parses the `:8443` body. Still, to keep the documented curl checks meaningful: the new Appendix C page embeds an HTML comment `<!-- verify=$ssl_client_verify subject=$ssl_client_s_dn -->` at the top of the response (nginx substitutes the real values), so `curl ... | grep verify=` still works for anyone following `lab/README.md`. `lab/README.md`'s `:8443` curl comment is updated to say "grep the HTML comment for `verify=SUCCESS`" instead of implying a plain-text body.
2. **`did-fail-load` boundary — confirmed, not built.** The access-denied page is driven by `did-navigate`'s HTTP code (tool-2 = 403, an HTTP-layer response after a successful TLS handshake). A TLS-layer handshake failure (e.g. no cert / cert rejected at the TLS layer, not the app layer) fires `did-fail-load` instead and falls through to Electron's default error page — none of the three demo cases in this plan hit that path by design (tool-1/tool-2 both complete the TLS handshake; the nav-block never reaches TLS at all). This is a known, explicitly accepted boundary, not something this plan's pages cover.
3. **`showBack:true` on the red (`tool-blocked`) state.** `buildState()`'s `tool-ok` and `tool-blocked` branches share the same `showBack:true` (both are "inside a tool," differing only in badge colour) — so the access-denied page always has a way back to home. Called out explicitly since Decision 7 above focuses on the badge/title and could otherwise be read as silent on `showBack`.
4. **Device CN sourced from `CERT_SUBJECT_CN`, never hardcoded.** `chrome-state.js` imports `CERT_SUBJECT_CN` from `config.js` (the same constant M4's `logSessionIdentity()` call uses) and includes it in every pushed state; the static pages never hardcode `DTL-Ubuntu-Test-Device` — the identity indicator is rendered client-side from the pushed state object, so the two can't drift.

## Next steps (after approval)

Implement Steps 1 → 5 in order, verifying each on the VM before the next, per working discipline.
Do not commit until the human confirms the GUI is verified end-to-end.
