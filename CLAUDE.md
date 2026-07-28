# DTL App PoC - CLAUDE.md

## Project overview
This is a proof-of-concept (PoC) for a custom managed/enterprise browser controlled by DTL. It is built as a locked-down native desktop application wrapping a WebView to securely access internal corporate portals. The Brainstorming phase is complete and the **Planning phase is now authorized**: plans are written to `docs/internal/`. **Implementation stays gated** - code for a milestone is written only after that milestone's plan has been reviewed and approved (see Rules).

## Scope (locked)
- **5 Core Features ONLY:** Custom branding, custom homepage, custom OIDC auth, device-bound mTLS, and an app-level remote wipe.
- **Platforms:** Desktop (Ubuntu and macOS delivered, Windows planned). iOS and Android are tabled.
- **Out of Scope:** Data Loss Prevention (DLP - no download/copy blocking), true MDM remote uninstall, real PKI infrastructure, and production backend.
- **Note:** The KIOSK shell + domain allow-list (see Tech stack) are *how the locked-down shell is built*, not a separate sixth feature - they are in scope per brainstorm decisions C3/C4.

## Tech stack & key decisions
Headline only - **full detail, comparison, gotchas, and rationale live in `docs/techstack.md`** (the single source of truth, validated 2026-06-24).
- **Framework:** Electron (one bundled Chromium for Ubuntu + Windows - no engine divergence).
- **Authentication:** OIDC (local Zitadel for the PoC; Google Workspace later).
- **mTLS:** Device-bound, per-domain via `select-client-certificate`. Provision certs via external `pk12util`/`certutil` - NOT `app.importCertificate` (broken on Linux).
- **UI / embedding:** KIOSK shell (no tabs/address bar, default-deny allow-list) built on `WebContentsView` + `BaseWindow`.
- **Kill switch:** App-level wipe - Electron session data + tokens + the OS-store client cert.
- *Comparison, mechanisms, phase-plan libraries, and mobile forward-look -> `docs/techstack.md`.*

## Repo layout
- `docs/internal/` - the roadmap and per-milestone detailed plans (Planning-phase output; each reviewed before its implementation). Untracked (git-ignored) by design - present on disk for the two-tier gate, kept out of the handoff repo state.
- *(Source layout to be populated as code is generated, per approved plans.)*

## Commands
*(To be populated with build/run commands once the Electron app is scaffolded)*
- Mock Cert Provisioning (Ubuntu): `pk12util -i <cert.p12> -d sql:$HOME/.pki/nssdb`

## Environment & gotchas
- **Host:** Running in `dshell` (a cloud dev container natively inside the datacenter, bypassing NetBird VPN).
- **Containers:** `dshell` provides **podman**, not docker (rootless, no daemon). Use `podman` for any local container (e.g. the nginx mTLS test endpoint). The CLI is largely docker-compatible.
- **Network:** All internal `.dtl` web apps are currently plain HTTP.
- **mTLS Testing:** Handled by spinning up a local HTTPS endpoint with `ssl_verify_client on` and an OpenSSL self-signed CA.
- **Cert Storage:** Ubuntu stores the client certificate in `~/.pki/nssdb`.
- **Wipe Gotcha:** The wipe MUST delete the cert from the OS store with `certutil -F` (Ubuntu NSS - removes key + cert; `pk12util` only imports/exports and cannot delete). Clearing Electron's app data alone is not enough.

## Conventions
- **Language:** All documentation, comments, and commit messages must be in English.
- *(Code style conventions to be defined in the Plan phase)*

## Rules (always / never)
- **Two-tier gate (planning vs implementation):** Writing plans is now authorized - Claude Code MAY create the roadmap and per-milestone plans under `docs/internal/`. But **NEVER write implementation code or scaffolding for a milestone until that milestone's plan has been reviewed and explicitly approved.** Approval is per-milestone, not blanket. After writing a plan, stop and wait for review.
- **NEVER** expand the scope beyond the 5 core features without explicit authorization. Do not add DLP features.
- **NEVER** over-engineer. This is a PoC to learn mechanics, not a production-hardened app.
- **NEVER** embed web content via the `<webview>` tag or `BrowserView` (deprecated/unstable). Use `WebContentsView`.
- **ALWAYS** enforce strict separation of concerns in Electron: Node.js / OS operations (like wiping and cert interception) MUST stay in the Main Process. The Renderer process must be isolated.
- **ALWAYS** default to KISS (Keep It Simple, Stupid) for infrastructure. Use local stubs/mocks instead of building full backends.

## dshell ↔ VM file transfer

The VM (`duccanh-test-pc.dtl`, user `khanhnhan`) is a **separate machine** - it does NOT share `/mnt/sg_code` with the dshell. Files built in the dshell (e.g. `dist/dtl-app_0.1.0_amd64.deb`) must be transferred explicitly.

**Raw `ssh`/`scp` fails** with "Host key verification failed" because the VM's host key is not in the dshell's standard `~/.ssh/known_hosts`. Do NOT bypass this by patching `known_hosts` manually - use `gimme` instead.

**Sanctioned transfer path - `gimme` + `scp` with the gimme key:**

```bash
# Test connectivity first (optional):
gimme ssh khanhnhan@duccanh-test-pc.dtl -- echo ping

# Copy a file dshell -> VM (mirrors gimme's own SSH flags internally):
scp -i ~/.ssh/gimme -P 22 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  /mnt/sg_code/users/khanhnhan/g_khanhnhan/intern_28/dtl-app-poc/dist/dtl-app_0.1.0_amd64.deb \
  khanhnhan@duccanh-test-pc.dtl:~/
```

`gimme` manages auth via its own token service and deliberately uses `StrictHostKeyChecking=no` internally - the above scp just replicates that sanctioned behaviour.

- **Dshell build output:** `dist/` under the dshell repo path (`/mnt/sg_code/users/khanhnhan/g_khanhnhan/intern_28/dtl-app-poc/`).
- **VM repo path:** `~/Downloads/dtl-app/` (used for source code, lab certs, and manual testing).
- **Gimme key location:** `~/.ssh/gimme` (generated by `gimme genkey`; already present).

## Reference docs
- `docs/techstack.md`: Single source of truth for the technology stack (decisions, gotchas, libraries, mobile look-ahead).
- `docs/task_description.md`: The original task description for this PoC.
- `images/*.svg`: Architecture & app-anatomy diagrams for quick onboarding.