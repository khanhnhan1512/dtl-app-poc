# Brainstorm — DTL App PoC

> Working notes for the `dtl-app-poc` project.
> Answers two questions: what the project does, and what is in scope.

## 1. What will this project do?

DTL App is a **custom web browser controlled by DTL** — a "managed" or "enterprise"
browser. Employees use it to reach DTL's sensitive internal web apps (trading
dashboards, market data, internal portals) across all of their devices.

The reason it exists: when employees use a normal browser (Chrome, Safari), DTL has
almost no control, because those browsers belong to Google / Apple, not to DTL. With
its own browser, DTL can:

- make sure only the right person, on a recognised device, can reach internal apps;
- lock down what users can do inside the browser;
- remotely disable and wipe the app if a laptop is lost or an employee leaves.

**How it is built, in one line:** it is a native application *installed on the device*
(not a website on a server). Inside the app sits a *WebView* — the browser engine the
operating system already provides — which renders the web pages. Around that WebView
we write DTL's custom logic: branding, login, mTLS, remote wipe, and navigation
control. (Same pattern as Slack / VS Code desktop, plus security controls.)

**Target platforms:** Ubuntu, Windows, macOS, iOS, Android.

**This is a proof-of-concept.** The goal is to learn what it takes to build this and to
prove the hardest parts work — not to ship a finished product.

## 2. What functions are in scope?

The five modifications named in the task:

1. **Custom logo / branding** — the app shows DTL's identity (app icon, name, in-app
   logo), not a generic browser.
2. **Custom home page** — the app opens to DTL's internal portal instead of a default
   new-tab page.
3. **Custom authentication** — the user must prove they are a valid DTL employee before
   using the app (e.g. single sign-on to the company identity provider).
4. **mTLS for certain websites** — for designated internal domains, the app presents a
   client certificate so the server can verify the device / user. Internal sites then
   only talk to recognised devices; a correct password on an unknown machine is not
   enough.
5. **Remote kill switch / wipe** — a command from a DTL backend that makes the app erase
   its local data (including the client certificate) and / or disable itself.

Supporting function (implied — needed to deliver the five above):

6. **Management / config backend + channel** — a server, and a way for the app to talk
   to it, that pushes branding, home page, mTLS policy, and the kill command down to
   installed apps.

### Out of scope for the PoC

To keep the PoC focused and set expectations:

- **Full 5-platform coverage.** The PoC targets **Ubuntu (primary) + Windows** only, built
  with **Electron**; macOS, iOS, Android are tabled until a working desktop build exists.
- **Fully removing the app from a device remotely.** That requires device-management
  (MDM) enrollment. The PoC does an *app-level data wipe* (the app erases its own data),
  not a true uninstall.
- **Certificate provisioning at scale.** How the client certificate first gets onto each
  device, and how it is rotated, is a real sub-problem but not part of this PoC.
- **Production hardening** — security patching pipeline, auto-update, full distribution.

### Note on scope wording

The task says *"certain modification (**e.g.** ...)"*. "e.g." means these are
*examples*, not a closed list, so scope could grow. For the PoC we stick to the five
listed items and confirm with the task owner before adding anything — for example, a
locked-down navigation allow / block-list, which is common for this kind of product but
is **not** explicitly named in the task.

## Resolved questions — brainstorming complete ✅ (2026-06-23)

> Every group (A–I) below is **DECIDED** — see the **Findings** and **Decisions Log** sections
> for evidence and rationale. Scope = the **5 core features only** (no DLP / extras). The
> brainstorming phase is officially closed; the Plan / architecture phase has not started yet.

### A. Strategic — DECIDED ✅ (2026-06-23, with manager)

- **A1. Build vs buy → BUILD IT OURSELVES.** Prisma Access Browser would be the production
  choice (DTL is a Palo Alto shop), but the explicit goal here is a **PoC / learning
  exercise** — boss wants "to see what it takes to implement this." We build to understand
  the underlying mechanics and effort. Buying is *not* pursued for the PoC.
- **A2. Goal of the PoC → FEASIBILITY VERTICAL SLICE.** Not a product. Focus entirely on
  proving the hardest technical constraints (mTLS-in-WebView, remote wipe); do **not**
  polish for production. Branding / home page come last as easy wins.
- **A3. MDM → NONE at DTL.** No Intune / Jamf / Workspace ONE in play. Consequence: the
  remote kill switch is an **app-level data wipe** (not a true device uninstall). On
  trigger the app must erase **its own cache, cookies, localStorage, auth tokens, and
  client certificate(s)** so it is functionally locked out of the internal network. Cert
  *re-provisioning* after a wipe is therefore also our problem (see D4), not MDM's.

### B. Success criteria & constraints — DECIDED ✅ (2026-06-23, with manager)

- **B1/B2/B5 (priority + DoD) → DESKTOP-FIRST: Ubuntu (primary) + Windows ONLY.**
  macOS, iOS, Android are **tabled** (revisited only after a working Ubuntu/Windows build).
  All 5 features must work on these two. **DoD =** (1) app runs in a **local dev env** with
  the core hard features (mTLS, app-wipe, custom auth), then (2) a **working test build on
  Ubuntu**. Note: this *defers* the hardest risk (iOS WKWebView mTLS) rather than retiring
  it — fine for now, but it returns the day mobile is back on the table.
- **B3/B4 (budget) → none needed yet.** Local-dev + Ubuntu/Windows means no Apple Developer
  account, no mobile devices, no production code-signing budget at this stage.

### C. Architecture & tech stack — framework DECIDED ✅ (2026-06-23)

- **C1/C5 → Framework = ELECTRON; one desktop codebase for Ubuntu + Windows.** Rationale +
  the rejected alternatives (Tauri/Wails/Qt) are in the *Group C decision* findings section
  below. With macOS/mobile tabled (B), the "2–3 codebases" problem disappears for now — one
  Electron app covers both target OSes with one bundled Chromium engine.
- **C2 → engine divergence is now moot.** Electron ships the *same* Chromium on Ubuntu and
  Windows, so rendering/TLS behaviour is identical across both targets. (Divergence only
  returns if macOS/mobile come back.)
- **C3 → DECIDED ✅: locked single-purpose KIOSK shell.** No address bar, no tabs, no
  bookmarks, no history menu. The app is just a window showing the internal portal. Links
  open **in the same window** (no pop-ups / new windows).
- **C4 → DECIDED ✅: strict allow-list.** User cannot type URLs. The app **intercepts and
  blocks** navigation to any unauthorized / external domain (default-deny allow-list).

### D. mTLS — DECIDED ✅

- **D1. Storage → OS cert store** (NSS `~/.pki/nssdb` on Ubuntu; Windows cert store). The OS
  holds the key and signs; the app never touches the private key. Hardware-backing not required
  for the PoC (available later via TPM on Windows).
- **D2. Per-domain client cert in the WebView → YES on desktop**, via Electron
  `app.on('select-client-certificate')` (mechanism in the *Group C decision* findings section).
  iOS WKWebView (the genuinely hard case) is deferred with mobile.
- **D3. Binding → DEVICE-bound; no real PKI.** The cert proves *"a recognised company machine"*
  — not the user (user = Google Workspace OIDC, feature 3). PoC uses **OpenSSL**: a self-signed
  local CA + a mock device cert `CN=DTL-Ubuntu-Test-Device`. A production issuing CA is out of scope.
- **D4. Re-provisioning → OUT OF SCOPE for the app.** Without MDM, an app that wiped its own
  OS-store cert + lost network access cannot self-bootstrap a new one — accepted limitation. For
  PoC testing, a **manual out-of-band bash script (`pk12util`)** re-injects the test cert. The
  app never re-issues certs itself.

### E. Authentication — DECIDED ✅

- **E1. IdP / protocol → OIDC; ZITADEL for the PoC.** (Manager delegated the Google-vs-Zitadel
  choice.) Use a **local Zitadel test instance** — fully under our control (Docker-runnable),
  trivial test-client registration, no Google-Workspace-admin gatekeeping, and it matches the
  real NetBird Zitadel for later SSO parity. Google Workspace stays the production-path option.
- **E2. SSO ↔ mTLS → LAYERED & independent.** OIDC gates app launch (proves the *user*); mTLS
  proves the *device* per-domain. Both required; neither replaces the other.
- **E3. Embedding → load pages as top-level WebView navigations** (not iframes), so internal
  apps' `X-Frame-Options: DENY` is a non-issue. No SSO header-injection into portals for the
  PoC — their own auth stays as-is.
- **E4. Token storage → main process only, OS-encrypted** (`safeStorage`); silent refresh;
  re-auth on failure. (Headless `safeStorage` backend caveat noted in findings.)

### F. Kill switch / wipe — DECIDED ✅

- **F1. Delivery → poll / heartbeat** for the PoC (+ server-side token revocation). Push
  (APNs/FCM) deferred with mobile. Offline-can't-be-killed-until-reconnect is accepted.
- **F2. Authenticity → signed kill command**, verified against a pinned public key (no spoof/DoS).
- **F3. Scope of wipe → cert + tokens + cookies + cache + localStorage.** Recovery is manual
  (D4), not in-app.
- **F4. Tamper resistance → accepted limitation.** Desktop data dir / NSS are user-accessible;
  real hardening needs MDM/OS and is out of scope. No root/jailbreak detection.
- **F5. Triggers → manual / admin for the PoC** (a local stub flips the kill flag). Automatic
  triggers (lost-device, offboarding, geofence) out of scope.

### G. Management backend — DECIDED ✅

- **G1 → STUB / MOCK for the PoC** — a tiny local endpoint serving config + the kill flag. A
  real backend (Django/DRF behind nginx + GitLab CI, matching DTL's stack) is future work.
- **G2. Device registry → minimal / local** (a device id + kill flag); full enrolment later.
- **G3. Config → baked into the build** for the PoC (allow-list, home URL, mTLS domains,
  branding); remote config is future work.

### H. Security / threat model — DECIDED ✅

- **H1. Defending against → a lost/left device and an unrecognised machine.** Identity + device
  are already enforced by NetBird ZTNA + Google SSO at L3; the browser adds data-at-rest wipe,
  L7 per-domain device binding (mTLS), and a locked UI.
- **H2. DLP → OUT OF SCOPE.** No download blocking, no DevTools/F12 blocking, no copy-paste /
  screenshot / print restrictions. Strictly the 5 core features.
- **H3. Certificate pinning → out of scope** for the PoC (client-cert mTLS is the focus).
- **H4. Compromised / rooted OS → accepted limitation** — software controls can be bypassed;
  not defended in the PoC.

### I. Distribution — DECIDED ✅

- **I1. iOS distribution → N/A** (mobile tabled, per B).
- **I2. Code signing → not needed for the PoC** — an unsigned local / Ubuntu build is acceptable.
- **I3. Linux format → AppImage** (primary) + optional `.deb`.

---

## Findings — exploring DTL's internal environment (2026-06-23)

> Source: live recon from `dshell` (the cloud container this work runs on) + web research.
> Confidence tags: **[verified]** = probed directly · **[inferred]** = strong evidence ·
> **[open]** = still a human/business decision, can't be discovered by exploring.

### Environment & what DTL is

- `dshell` = cloud dev container, backend host `sg-dshell03.dtl` ("sg" = Singapore). Logged
  in as `khanhnhan`, unix group `intern` → this is the `intern_28` PoC. **[verified]**
- DTL = **DyTech Lab** (public domain `dytechlab.com`), a quant **trading firm**. The
  (unauthenticated!) roster at `todo.dtl/api/auth/user/` lists roles: `employee, dev, trade,
  intern`, plus `is_superuser` / `mentor`. **[verified]**
- Stack signals: **nginx 1.18** fronts everything; **Next.js** front-ends + **Django/DRF**
  APIs (todo.dtl); **GitLab** x2 (gitlab.dtl source, build.dtl CI) + `.gitlab-ci.yml` in
  this repo; Docker **registry.dtl**; internal Python pkg repo **pandora.dtl**; an internal
  **MCP** API (api.mcp.dtl). **[verified]**

### Internal web tools discovered (the universe the browser must serve)

| Host | Purpose | Scheme | Auth | X-Frame-Options |
|---|---|---|---|---|
| **todo.dtl** | Onboarding + project/task portal (Next.js+Django) | HTTP | token in `localStorage` (`auth.user`+`auth.token`), header `Authorization: "<user> <token>"` | none → **embeddable** |
| **gatsby.dtl** | Compute box + **Django SSO/auth GUI** (`/gui/auth/`, LDAP) | HTTP | LDAP/session | ALLOWALL → embeddable |
| **keycloak.dtl** | Identity service (up; exact OIDC role unconfirmed) | HTTP | ? | ? |
| **gitlab.dtl** | GitLab (source) | HTTP | LDAP | SAMEORIGIN |
| **build.dtl** | GitLab #2 (CI/builds) | HTTP | LDAP | SAMEORIGIN |
| **pandora.dtl** | Python package repo (`/packages/`) | HTTP | SSO → gatsby | DENY |
| **gimme.dtl** | Resource portal (redirects to SSO) | HTTP | → gatsby | DENY |
| **data.dtl** | Data portal (`/login/?next=`) | HTTP | own login | DENY |
| **grafana.dtl** | Dashboards / observability | HTTP | own login | deny |
| **registry.dtl** | Docker registry (v2 API) | HTTP | token/basic | none |
| **api.mcp.dtl** | Internal MCP API | HTTP | ? | DENY |
| **wiki.dtl** | Wiki (currently 502 / backend down) | HTTP | ? | ? |

**Every internal web app is plain HTTP — no TLS anywhere.** All `.dtl` hosts resolve to a
**single reverse proxy `10.1.1.250` (`sg-nginx.dtl`)** — every site is an nginx virtual
host on one box. Security model today = "trusted internal network", not per-service TLS.
**[verified]** (Implication: mTLS would be configured at this *one* central nginx — convenient,
but it currently terminates no TLS at all.)

### Network & access model — NetBird ZTNA (added 2026-06-23)

How end-user devices reach `.dtl` (this `dshell` is exempt — it's a backend container *inside*
the datacenter, native L3 routing, **no NetBird installed**):

- **`.dtl` is gated by NetBird** — a WireGuard-based **zero-trust mesh VPN**. A device must
  install the NetBird client and connect (mgmt URL `https://netbird.dytechlab.com/`) before
  any `.dtl` host is reachable. **[user-confirmed]**
- **IdP = Zitadel brokering Google Workspace.** NetBird's OIDC issuer is
  `https://netbird.dytechlab.com` with `/oauth/v2/…` + `/oidc/v1/…` endpoints (= **Zitadel**,
  NetBird's bundled IdP); users log in "with Google account / company email" → **Google
  Workspace (`@dytechlab.com`) federates in.** **[verified issuer; Google login user-confirmed]**
- **DTL already has device+identity ZTNA at the network layer (L3).** "Only the right person
  on a recognised device reaches internal apps" is *already substantially provided by
  NetBird* — independent of the browser.

**Why this matters for the PoC (brutal honesty):**

1. **mTLS partially overlaps with NetBird.** NetBird already binds network access to an
   enrolled device + Google identity. The browser's mTLS adds **L7, per-domain, per-app
   binding** (defense-in-depth, and binds *the app* not just the device's tunnel) — real but
   *incremental* value. Fine as a learning goal; don't oversell it as a brand-new capability.
2. **Auth question is largely answered → use OIDC.** Cleanest "custom auth" = reuse the
   employees' existing login: **Google Workspace** directly, or **Zitadel** (same IdP as the
   VPN, for SSO parity). This **supersedes** the earlier "integrate with legacy LDAP/gatsby"
   lean — LDAP/keycloak are the *old* internal plane; Google/Zitadel OIDC is the modern one.
3. **Network reachability is a hard prerequisite — especially on mobile.** The browser can't
   reach `.dtl` unless NetBird is connected. On **iOS/Android** NetBird runs as a *separate
   system VPN app* (one VPN NetworkExtension at a time) — **the managed browser cannot embed
   or replace it.** So mobile = NetBird app installed+connected *alongside* our app; best the
   browser can do is detect "is the tunnel up?" and prompt. This caps what the mobile PoC can
   own end-to-end.

### Answers to the open questions

- **A1 (build vs buy) → DECIDED: BUILD ✅.** Evidence that informed it: DTL's machines trust
  **Palo Alto Networks** root CAs (`paloalto_RootCA_new`, `paloalto_Untrust` in the NSS
  trust store) → Palo Alto firewall + **SSL-decryption forward-proxy** on managed laptops
  **[verified CA]**. *(Correction to earlier note: the `.dtl` **VPN is NetBird**, not Palo
  Alto GlobalProtect — see the Network & access model section.)* Palo Alto sells
  **Prisma Access Browser** (ex-Talon), a managed Chromium browser covering ~4.5/5 features
  OOTB from the same console — the rational *production* buy. **Decision (with manager):
  build it ourselves anyway**, because the goal is a PoC / learning exercise to see what it
  takes — not to ship. Prisma stays on record as the production recommendation if this ever
  graduates beyond a PoC.
- **A2 (PoC goal) → DECIDED: feasibility vertical slice ✅.** Prove the hardest constraints
  (mTLS-in-WebView, remote wipe) first; do not polish for production; branding + home page
  are last/easy.
- **A3 (MDM?) → DECIDED: no MDM at DTL ✅.** No Intune/Jamf/Workspace ONE (confirmed by
  manager; also no evidence from `dshell`). ⇒ kill switch = **app-level data wipe**: on
  trigger, erase the app's own cache, cookies, localStorage, auth tokens, and client
  cert(s) so it's functionally locked out of the internal network. No true device
  uninstall. Re-provisioning a cert after a wipe is our problem too (see D4).
- **C1/C2 → see the "Group C decision" section below.** With desktop-only scope (B), the
  answer is **one Electron app (Ubuntu+Windows), one bundled Chromium engine** — the
  multi-codebase / engine-divergence concerns are deferred with mobile.
- **D-block (mTLS):**
  - **D2 → desktop is the low-risk path (full mechanism in the Group C decision section).**
    On Ubuntu+Windows, Electron's `app.on('select-client-certificate', …)` does per-domain
    client-cert selection from the OS store (NSS `~/.pki/nssdb` on Linux, Windows cert store
    on Windows); the OS holds the key and signs, so it can be non-exportable / TPM-backed.
    *(iOS WKWebView remains the real long pole — deferred with mobile, not solved.)*
  - **D3 (PKI) → decided: DEVICE-bound, self-signed test CA.** No mTLS client certs exist
    today (NSS key store empty) **[verified]**; a real issuing CA is net-new and out of scope.
    PoC = OpenSSL self-signed CA + mock device cert `CN=DTL-Ubuntu-Test-Device` (binds the
    *machine*; the *user* is proven by OIDC).
  - **D4 → decided: no app re-provisioning.** Post-wipe, a manual `pk12util` script re-injects
    the test cert (out-of-band). The app never self-bootstraps a cert.
  - Hidden cost: since **internal apps are HTTP-only**, real mTLS needs HTTPS + client-cert
    verification on the central nginx (`10.1.1.250`) — doesn't exist yet. For the PoC we
    stand up a **local HTTPS endpoint with `ssl_verify_client on`** to prove the flow without
    touching prod. **[verified]**
- **E-block (auth):**
  - **E1 (updated):** TWO identity planes. **Modern/primary = OIDC via Zitadel + Google
    Workspace** (`netbird.dytechlab.com` issuer; employees log in with their `@dytechlab.com`
    Google account — it already gates the NetBird VPN). **Legacy/internal = LDAP** (gatsby
    Django SSO, GitLab, keycloak.dtl) used by older `.dtl` tools; todo.dtl layers its own
    localStorage token on top. **DECIDED for feature 3: OIDC via a local Zitadel test instance**
    for the PoC (fast to register a client, no Workspace-admin gatekeeping, matches the real
    NetBird Zitadel); Google Workspace = production-path option. LDAP treated as legacy.
    **[verified Zitadel issuer + Google login; the two planes' federation not fully traced].**
  - **E3 (embedding):** most apps send `X-Frame-Options: DENY` — **but that only blocks
    iframes, not top-level WebView navigation.** A managed browser loads pages as the top
    frame, so XFO:DENY is fine. Only matters if the design embeds apps in iframes. todo.dtl
    & gatsby.dtl are also iframe-embeddable. **[verified]**
- **F (kill switch) → app-level wipe is the chosen mechanism (per A3, no MDM).** On a
  signed kill command the app erases its own cache, cookies, localStorage, auth tokens, and
  client cert(s). Delivery: **push (APNs/FCM) + poll/heartbeat fallback + server-side token/
  session revocation** (so a still-cached client can't keep using the network). No true
  device uninstall — out of scope without MDM.
- **G (backend):** management backend is net-new; natural fit = DTL's existing stack
  (Django/DRF behind nginx, GitLab CI). Device registry/enrolment is net-new.
- **H (threat model) → DECIDED.** Device+identity is **already enforced by NetBird ZTNA +
  Google SSO** at L3, so the browser uniquely addresses: **(a) data-at-rest on a lost/left
  device** → app-level wipe (✓ A3), **(b) per-domain L7 device binding** → mTLS, **(c) a locked
  UI** → kiosk + allow-list. **DLP is OUT OF SCOPE** (no download / DevTools / copy-paste /
  screenshot blocking) — strictly the 5 core features. Compromised-OS bypass = accepted limit.
- **I (distribution) → desktop only.** Linux = **AppImage** (+ optional `.deb`); **no code
  signing** needed for the PoC. iOS App-Store/WebKit issues + signing owners are deferred with mobile.

### Tech stack — consolidated into `docs/techstack.md` (updated 2026-06-24)

> The detailed framework comparison (Electron vs Tauri / Wails / Qt / ...), the Electron
> mTLS mechanism (`select-client-certificate`), the embedding / kiosk pattern, the wipe
> gotcha, the phase-plan library recommendations, and the mobile forward-look now live in
> **`docs/techstack.md`** — the single source of truth for tech-stack detail (validated &
> expanded via research on 2026-06-24). Decisions C and D above remain the brainstorming
> record; see `techstack.md` for the current, validated technical detail.
>
> Headline (unchanged): **framework = Electron** (one bundled Chromium for Ubuntu + Windows;
> mature per-domain `select-client-certificate` mTLS; JS/TS fits the team). One research
> correction: provision client certs via external `pk12util` / `certutil`, **not**
> `app.importCertificate` (broken on Linux).

### Decisions Log

| # | Date | Decision | Rationale |
|---|---|---|---|
| A1 | 2026-06-23 | **Build a custom browser ourselves** (not buy Prisma Access Browser) | PoC / learning exercise — "see what it takes." Prisma noted as the production buy if it graduates. |
| A2 | 2026-06-23 | **Feasibility vertical slice** — prove hardest constraints first, don't polish | Goal is mechanics + effort, not a shippable product. |
| A3 | 2026-06-23 | **No MDM → kill switch = app-level data wipe** (cache, cookies, localStorage, tokens, client certs) | DTL has no Intune/Jamf. App locks itself out of the internal network; no true device uninstall. |
| B | 2026-06-23 | **Desktop-first: Ubuntu (primary) + Windows ONLY**; macOS/iOS/Android tabled. DoD = local-dev with mTLS+wipe+auth, then Ubuntu test build. No mobile/signing budget. | Ubuntu is the company OS; prove all 5 features on 2 OSes before negotiating mobile. |
| C | 2026-06-23 | **Framework = Electron** (one codebase, Ubuntu+Windows) | Bundled Chromium = identical engine + proven `select-client-certificate` mTLS on both; team is JS/TS; Tauri/Wails fail on WebKitGTK Linux client-cert. |
| C3/C4 | 2026-06-23 | **Kiosk shell + strict allow-list** — no address bar/tabs/bookmarks/history; same-window nav, no pop-ups; default-deny domain allow-list | Minimise attack surface + frontend complexity; the app is a locked portal viewer, not a general browser. |
| D3 | 2026-06-23 | **Device-bound mTLS cert; OpenSSL self-signed CA + mock `CN=DTL-Ubuntu-Test-Device`** (no real PKI) | Cert proves the machine; user proven by OIDC. PoC, not production PKI. |
| D4 | 2026-06-23 | **No in-app re-provisioning** — manual `pk12util` script re-injects the test cert out-of-band | Without MDM an app can't self-bootstrap a cert after wiping it; accepted PoC limitation. |
| E1 | 2026-06-23 | **Auth = OIDC via a local Zitadel test instance** (Google Workspace = prod-path option) | Manager delegated the choice; Zitadel is fastest to self-host + register a test client locally, no Workspace-admin gatekeeping, matches the real NetBird IdP. |
| H | 2026-06-23 | **DLP OUT OF SCOPE** — no download / DevTools / copy-paste / screenshot blocking | Strictly the 5 core features; identity+device already covered by NetBird ZTNA. |

### Brainstorming phase — COMPLETE ✅ (2026-06-23)

All questions (A–I) are decided; **no open blockers remain.** Locked scope:

- **5 core features only** (branding · home page · OIDC auth · mTLS · kill-switch wipe) — **no DLP**.
- **Desktop only**: Ubuntu (primary) + Windows · **Electron** · **kiosk UI + strict allow-list**.
- **mTLS**: device-bound, OpenSSL self-signed CA (`CN=DTL-Ubuntu-Test-Device`), OS cert store.
- **Auth**: OIDC via a local **Zitadel** test instance.
- **Kill switch**: app-level wipe (storage + tokens + OS-store cert); **no in-app re-provisioning**.
- **Backend**: stubbed/mocked locally.

Intentionally excluded: DLP, real PKI / cert re-provisioning, mobile (macOS/iOS/Android),
production backend, code-signing, auto-update.

> **The Plan / architecture phase has NOT been started** — to be written only when explicitly
> authorised.