# DTL App PoC — CLAUDE.md

## Project overview
This is a proof-of-concept (PoC) for a custom managed/enterprise browser controlled by DTL. It is built as a locked-down native desktop application wrapping a WebView to securely access internal corporate portals. The Brainstorming phase is complete; the Architecture/Plan phase has **NOT** started and must only begin when explicitly authorized.

## Scope (locked)
- **5 Core Features ONLY:** Custom branding, custom homepage, custom OIDC auth, device-bound mTLS, and an app-level remote wipe.
- **Platforms:** Desktop-first (Ubuntu primary, Windows secondary). macOS, iOS, and Android are strictly tabled.
- **Out of Scope:** Data Loss Prevention (DLP - no download/copy blocking), true MDM remote uninstall, real PKI infrastructure, and production backend.
- **Note:** The KIOSK shell + domain allow-list (see Tech stack) are *how the locked-down shell is built*, not a separate sixth feature — they are in scope per brainstorm decisions C3/C4.
- *Refer to `docs/brainstorm.md` for full rationale.*

## Tech stack & key decisions
- **Framework:** Electron (bundled Chromium ensures no engine divergence).
- **Authentication:** OIDC via a local Zitadel test instance.
- **mTLS:** Device-bound. Handled via Electron's `select-client-certificate` intercepting the OS cert store.
- **UI:** Locked single-purpose KIOSK shell (no tabs, no address bar, same-window navigation) with a strict domain allow-list.
- **Web embedding:** Use `WebContentsView` (with `BaseWindow`) — NOT the `<webview>` tag (Chromium architectural churn; Electron officially advises against it) nor the deprecated `BrowserView`. Many older online examples use those; do not copy them.
- **Kill Switch:** App-level data wipe — clears cache, cookies, localStorage, auth tokens, AND the OS-level client cert.
- *Refer to `docs/brainstorm.md` (Decisions Log) for details.*

## Repo layout
*(To be populated as code is generated during the Plan phase)*

## Commands
*(To be populated with build/run commands once the Electron app is scaffolded)*
- Mock Cert Provisioning (Ubuntu): `pk12util -i <cert.p12> -d sql:$HOME/.pki/nssdb`

## Environment & gotchas
- **Host:** Running in `dshell` (a cloud dev container natively inside the datacenter, bypassing NetBird VPN).
- **Network:** All internal `.dtl` web apps are currently plain HTTP.
- **mTLS Testing:** Handled by spinning up a local HTTPS endpoint with `ssl_verify_client on` and an OpenSSL self-signed CA.
- **Cert Storage:** Ubuntu stores the client certificate in `~/.pki/nssdb`.
- **Wipe Gotcha:** The wipe command MUST explicitly invoke OS tools (like `pk12util` or `certutil`) to delete the cert from the OS store; clearing Electron's app data is not enough.
- **Stack validation (2026-06-24):** Electron + `select-client-certificate` mTLS confirmed current and sound; latest stable is Electron 42–43 (Chromium 148, Node 24). When scaffolding, use `electron-vite` (build/dev) + `electron-builder` (packaging/auto-update), and wrap any native module behind an interface to ease future Electron upgrades.

## Conventions
- **Language:** All documentation, comments, and commit messages must be in English.
- *(Code style conventions to be defined in the Plan phase)*

## Rules (always / never)
- **NEVER** start the Architecture/Plan phase — or generate implementation code/scaffolding — unless explicitly authorized. Brainstorming is the only completed phase.
- **NEVER** expand the scope beyond the 5 core features without explicit authorization. Do not add DLP features.
- **NEVER** over-engineer. This is a PoC to learn mechanics, not a production-hardened app.
- **NEVER** embed web content via the `<webview>` tag or `BrowserView` (deprecated/unstable). Use `WebContentsView`.
- **ALWAYS** enforce strict separation of concerns in Electron: Node.js / OS operations (like wiping and cert interception) MUST stay in the Main Process. The Renderer process must be isolated.
- **ALWAYS** default to KISS (Keep It Simple, Stupid) for infrastructure. Use local stubs/mocks instead of building full backends.

## Reference docs
- `docs/brainstorm.md`: The source of truth for all decisions.
- `docs/task_description.md`: The original task description for this PoC.
- `images/*.svg`: Architecture & app-anatomy diagrams for quick onboarding.