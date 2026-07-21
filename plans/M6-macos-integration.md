# M6 — macOS integration + packaging (native lab, Keychain, `.dmg`)

> Detailed plan for **Milestone M6** of `plans/roadmap.md`.
> **Status: PLANNED — not started. Awaiting review per the two-tier gate (CLAUDE.md).**
> Builds on **approved + verified M0–M4** (all merged to master): mTLS cert handler, custom shell,
> OIDC auth-gated portal, token-aware `wipe()`, signed kill switch, `.deb` packaging.

## Two things this plan flags rather than silently works around

1. **`CLAUDE.md`'s Scope section is stale.** It currently reads *"macOS, iOS, and Android are strictly
   tabled."* That line was accurate when written and is not accurate now — the manager has explicitly
   asked for a macOS build, this milestone exists because of that ask, and `docs/techstack.md`'s own
   "mobile forward-look" section already anticipated a macOS seam. Recommend `CLAUDE.md`'s Scope and
   Platforms lines get updated to reflect macOS as an active target the moment this plan is approved —
   done as part of implementation (Step 9 below), not silently assumed away during planning.
2. **`roadmap.md`'s M6 entry says M6 "Depends on: M5 (`CertStore` interface already formalized)."** M5
   (Windows) has not been started — no plan, no code. This plan proceeds with M6 anyway, per explicit
   instruction, and does **not** introduce the `CertStore` abstraction the roadmap envisioned M5 would
   formalize first. Instead `wipe.js` gets a plain `process.platform` branch (Linux NSS vs macOS
   Keychain) — see Step 3. This is a deliberate, recorded deviation: if/when M5 (Windows) happens later,
   formalizing `CertStore` at that point means retrofitting three branches at once (NSS, Keychain,
   Windows Cert Store) instead of growing the abstraction from two. Accepted tradeoff for doing M6 out
   of order — not an oversight.

## Goal

Make the macOS demo **equivalent** to the Linux one: the manager can run all five core features
(branding/homepage, OIDC auth, mTLS device cert, kill switch, remote wipe) from a `.dmg` the same way
he runs them today from the `.deb`. Two halves, same shape as M4:

1. **Lab port.** Reproduce `lab/setup.sh`'s three services (mTLS test server, Postgres, Zitadel) as
   native macOS processes — no containers, because containers are not possible on the target hardware
   (see verified inputs below). Same demo, same behavior, different plumbing underneath.
2. **App port.** One Linux-only code path exists in `src/main/` — `wipe.js`'s NSS cert deletion — and
   needs a macOS branch. Everything else in `src/main/` already works unchanged (see verified inputs).
   Packaging adds a `.dmg` target alongside the existing `.deb`.

## Acceptance criteria

1. `lab/setup-macos.sh` stands up the full native lab — Apache mTLS server, Postgres.app-backed
   Zitadel, seeded project + native PKCE app + test user + kill-switch keypair — with the same
   "zero console interaction, run one script" experience as `lab/setup.sh`, **except** the two
   `security` commands that require a real GUI session and a typed password (see verified inputs) —
   those are the one honest exception, documented up front, not discovered mid-setup.
2. All five core features work end-to-end on macOS through the packaged `.dmg`, mirroring M4's DoD:
   branding/custom homepage (M1), OIDC login (M2), mTLS device cert presented + accepted (M0), the
   kill switch wipes and locks the device out (M3), and the two-layer session compose (M4).
3. The three-case mTLS compose test from M4 (`no cert` / `cert, no token` / `cert + token`) is
   reproduced on macOS, with the "no cert" case producing a real HTTP 400 and the app's
   access-denied page — not a blank window. This exact case was the highest risk identified during
   smoke testing (see verified inputs) and must be explicitly re-verified here, not assumed durable.
4. `wipe()` on macOS removes the client cert **and** its private key from Keychain atomically (see
   Step 3 for why `security delete-identity`, not `security delete-certificate`, is required) and
   clears `tokens.enc`. The result object accurately reports `certDeleted`, matching the ordering fix
   already shipped on Linux (`da457b0`). **The existing `[wipe] Done. {...}` log line shape does not
   change** — `docs/*.png` (`kill-wipe-log.png`) depends on it reading identically across platforms.
5. `lab/teardown-macos.sh` returns the machine to a "never ran DTL App" state, **including removing
   the trusted CA from the keychain** — not just the client cert/identity. This is the macOS
   equivalent of Linux teardown's `certutil -D -n "$CA_NICK" -d "$NSS_DB"` step; a throwaway CA left
   in a user's trust store after teardown is a real hygiene gap, not a cosmetic one.
6. `.dmg` builds successfully (~2 min per smoke test) via `npm run dist:dmg`, and the macOS setup
   guide documents the Gatekeeper workaround needed to actually open an unsigned, downloaded `.dmg` —
   this is handled explicitly for the manager's benefit, not left to be discovered as a support ticket.
7. The behavioral contract between `lab/nginx/mtls.conf` and the new macOS Apache config is written
   down once, in one place, and both configs carry a comment pointing at it (see Step 7) — so a future
   change to one doesn't silently drift from the other.

## What's already verified on the real VM — treat as given inputs, not open questions

Everything in this section came from hands-on smoke testing on the actual target machine (macOS
12.7.6 Monterey, x86_64, running as a QEMU guest with no nested virtualization —
`kern.hv_support: 0`, confirmed via `sysctl`). Implementation should build on these directly rather
than re-deriving them.

**Containers are categorically impossible here.** `kern.hv_support: 0` means `podman machine` cannot
start (it needs Hypervisor.framework to run its own Linux VM). This is why the lab is a native-process
port, not a "swap podman for Docker Desktop" port — there is no container runtime option on this
hardware at all.

**Node must be 22.12+.** Electron 42's own `package.json` declares `"engines": {"node": ">= 22.12.0"}`.
Node 20 does not hard-fail — `npm install` succeeds with only an `EBADENGINE` warning — but this is a
red herring, not the real issue: **`electron`'s npm package ships no `postinstall` script at all, on
any Node version.** Its binary downloads lazily on first `require('electron')` (confirmed by reading
`node_modules/electron/index.js` — `getElectronPath()` calls `downloadElectron()` if `dist/` is
missing). `electron-builder` does its own separate download during packaging, independent of whatever
is or isn't in `node_modules/electron/dist`. Bottom line: pin Node to 22.12+ because Electron 42
requires it, not because it "fixes" the lazy-download behavior — nothing was broken there.

**Apache httpd 2.4.56 + `mod_ssl` already ship with base macOS 12.** Present at `/usr/sbin/httpd` and
`/usr/libexec/apache2/mod_ssl.so`. Not loaded by default — `/private/etc/apache2/httpd.conf` has
`LoadModule ssl_module` and the `httpd-ssl.conf` include both commented out — but nothing needs
installing. A throwaway config (`~/apache-test/httpd.conf` on the mac VM, left in place) reproduced
all five `mtls.conf` behaviors exactly:

| Port | Behavior | Apache directives that produce it |
|---|---|---|
| `:8443` valid cert | 200 | `SSLVerifyClient optional` |
| `:8443` no cert | **400** (matches nginx exactly) | Same `<Directory>` block: `RewriteEngine On` / `RewriteCond %{SSL:SSL_CLIENT_VERIFY} !=SUCCESS` / `RewriteRule ^ - [R=400,L]` |
| `:8445` wrong CN | 403 | `SSLVerifyClient require` + `<Directory>` block: `SSLRequire %{SSL_CLIENT_S_DN_CN} eq "DTL-Approved-Device"` |
| `:8444` no cert | 200 | `SSLVerifyClient optional` |
| `:8444 /kill` | serves JSON | `Alias /kill "<path>/kill-command.json"` |

Two non-obvious things that cost real debugging time and must not be re-discovered:

- **The `%{SSL:varname}` prefix is mandatory in the `:8443` `RewriteCond`, not optional stylistic
  syntax.** A bare `%{SSL_CLIENT_VERIFY}` — even with `SSLOptions +StdEnvVars` set — silently returns
  the wrong value inside `RewriteCond`, because `mod_rewrite` evaluates before `mod_ssl` finishes
  populating the standard subprocess environment table. This was confirmed empirically with a debug
  `Header set X-Debug... "%{SSL_CLIENT_VERIFY}e"` directive (correct via `mod_headers`, evaluated
  later) that exposed the mismatch — `RewriteCond` needs the `SSL:` special-lookup form to force a
  live read from `mod_ssl` directly. `:8445`'s `SSLRequire` did **not** have this problem — only
  `RewriteCond` does.
- **Apple's `httpd` binary does not statically link an MPM.** `httpd -t` fails with
  `AH00534: ... No MPM loaded` unless `LoadModule mpm_prefork_module` is explicitly loaded. Full
  module list needed beyond the obvious `ssl_module`: `mpm_prefork_module`, `unixd_module`,
  `authz_core_module`, `authz_host_module`, `mime_module`, `log_config_module`, `dir_module`,
  `alias_module`, `rewrite_module`.
- **No sudo needed for any of this**, confirmed twice across two config iterations: unprivileged
  ports (8443–8445), and — critically — `PidFile`/`Mutex`/logs must all point at a directory the
  running user owns. The default `/private/var/run` mutex path is root-only and fails immediately
  (`Couldn't create the mpm-accept mutex`) the first time `httpd -k start` runs unprivileged. Omit
  `User`/`Group` directives entirely — specifying them is what would force a root-owned privilege
  drop; omitting them just runs the whole thing as the invoking user.

**Postgres: Postgres.app, not Homebrew.** Homebrew's `postgresql@16` formula ships no bottle older
than macOS Sonoma — installing it here means compiling Postgres from source on an emulated Core2Duo,
a real risk of the "hours or fail outright" scenario. Postgres.app v2.9.5 sidesteps this entirely:
universal binary (Intel + Apple Silicon), requires macOS 10.15+ (comfortably covers Monterey), bundles
**PostgreSQL 16.14** — matches the pinned `postgres:16-alpine` major version exactly — and installs by
dragging the `.app` to `/Applications`. No compile, no Homebrew, no sudo.

**Zitadel: darwin-amd64 binary exists for the exact pinned version.** Confirmed via the GitHub
releases API (not just "latest") — `v2.71.10` ships `zitadel-darwin-amd64.tar.gz` alongside the Linux
build. All 21 environment variables from `lab/setup.sh`'s `podman run` Zitadel invocation map directly
onto a bare `./zitadel start-from-init --masterkeyFromEnv --tlsMode disabled --port <port>`
invocation with the same env vars exported. The only value that changes in *shape* (not name) is
`ZITADEL_FIRSTINSTANCE_PATPATH` — the container-mount view `/pat/pat.txt` becomes a direct host path
(e.g. `$SEED_DIR/pat.txt`), no translation logic needed beyond that. `--network=host` becomes moot —
a bare process is already on localhost.

**`lab/zitadel/seed-zitadel.sh` needs zero changes.** Read in full — it's pure `curl` against `$BASE`
(the issuer URL, passed as a plain argument) plus reading a PAT from a plain file path. No
`podman exec`, no container DNS assumption, nothing platform-specific anywhere in the script.

**Cert provisioning, verified end-to-end with a real Electron app** (not just `curl`) — this is the
macOS equivalent of `provision-nss.sh`, and the most-requested-to-document part of this milestone:

```bash
# 1. Import the client cert+key. -T grants the presenting binary Keychain access without a
#    per-use prompt - point it at the actual Mach-O executable inside the .app bundle, not
#    the bundle directory itself.
security import client.p12 \
  -k ~/Library/Keychains/login.keychain-db \
  -P <p12-password> \
  -T "/path/to/DTL App.app/Contents/MacOS/DTL App"

# 2. Trust the throwaway CA for TLS. -r trustRoot, NOT -r trustAsRoot (that fails with
#    "SecTrustSettingsSetTrustSettings: One or more parameters passed to a function were not
#    valid" - hit this exact error during smoke testing; trustAsRoot is for pinning an
#    intermediate cert as if it were a root, not for an actual self-signed root CA). No -d flag
#    - scope to the user's own login keychain, the per-user equivalent of NSS's sql:~/.pki/nssdb.
security add-trusted-cert -r trustRoot -p ssl \
  -k ~/Library/Keychains/login.keychain-db \
  ca.pem
```

- **Both commands require a real GUI login session.** `security import` fails outright over SSH —
  `SecKeychainItemImport: User interaction is not allowed` — not a slow prompt, a hard refusal. This
  is why `lab/setup-macos.sh` **cannot** be a single fire-and-forget script the way `lab/setup.sh`
  is: it must either stop and hand these two commands to the person running it, or the whole script
  needs to be run interactively from Terminal.app inside a real login session from the start.
- `-T` reduced the confirmation prompt to zero visible dialogs in testing (clean
  `1 identity imported.` output, nothing else) — but this was only observed once, not independently
  re-verified across a second machine/keychain state. The setup guide should say "expect at most one
  confirmation click," not promise zero prompts unconditionally.
- **End-to-end proof, not just a curl check:** a standalone Electron script mirroring
  `src/main/cert-select.js`'s exact matching logic (same `MTLS_ALLOWLIST`, same `CERT_SUBJECT_CN`,
  same `extractHost()`) fired `select-client-certificate`, Keychain returned the cert in the
  `certificateList`, the `subjectName === CERT_SUBJECT_CN` match succeeded, and the mTLS page loaded.
  **`src/main/cert-select.js` needs no code changes** — confirmed by running it, not assumed from
  reading the API docs.

**Electron renders fine on this hardware.** 1.3s from process start to the `ready-to-show` event;
a continuous CSS animation (gradient sweep + pulsing dot) and a scrollable content area both looked
smooth under manual observation over VNC. **GPU-related errors appear in the console log on every
launch** (expected — this VM has no GPU passthrough) — these are noise, not failures, and the setup
guide must say so explicitly (see Step 6) or they will read as a real problem to whoever runs this
next.

**Toolchain note, dshell-side only (not something the macOS scripts themselves need to handle):**
non-interactive `ssh host 'command'` sessions only source `~/.zshenv`, never `~/.zshrc` — nvm's
default install only wires into `.zshrc`. A real user running `lab/run-app-macos.sh` from an actual
Terminal.app window gets a normal interactive login shell and never hits this; it only matters for
whoever scripts/CI-tests these scripts non-interactively later.

## Architecture (M6 shape)

Additive, mirroring M4: new macOS-specific files alongside the existing Linux ones, one small
platform branch inside `wipe.js`, no other `src/main/` changes.

```
lab/
  setup.sh              ← UNCHANGED (Linux, verified, do not touch)
  setup-macos.sh         ← NEW: Apache + Postgres.app + bare zitadel binary, same 11-step shape
  teardown.sh            ← UNCHANGED
  teardown-macos.sh      ← NEW: mirrors teardown.sh + Keychain CA-trust removal
  run-app.sh             ← UNCHANGED
  run-app-macos.sh        ← NEW: source .runtime-env + launch, no dbus/keyring bootstrap
  apache/                ← NEW: httpd.conf template (carried over from ~/apache-test), server/CA
                             cert templates mirroring lab/certs/*.ext
  nginx/mtls.conf        ← UNCHANGED (behavior contract comment added — see Step 7)

src/main/
  wipe.js                ← MODIFY: process.platform branch, NSS vs `security delete-identity`
  (everything else)      ← UNCHANGED — verified via the cert-select.js smoke test above

docs/
  setup-guide.md         ← UNCHANGED (Linux)
  setup-guide-macos.md    ← NEW

electron-builder.yml     ← MODIFY: add a `mac:` target block alongside the existing `linux:` one
package.json              ← MODIFY: add a `dist:dmg` script mirroring `dist:deb`
CLAUDE.md                 ← MODIFY: Scope/Platforms lines (Step 9)
```

## Out of scope (explicit)

- **Code signing and notarization.** The `.dmg` ships unsigned, same as the `.deb` ships unpackaged
  on a no-sudo VM. Gatekeeper's block on an unsigned, downloaded `.dmg` is handled as a documented
  one-time workaround for the manager (Step 6), not solved at the signing level.
- **Any change to the Linux lab.** `lab/setup.sh`, `lab/teardown.sh`, `lab/run-app.sh`, and
  `lab/nginx/mtls.conf` are verified and already handed over — this plan adds parallel macOS-specific
  files throughout rather than branching inside the existing ones, so there is no path by which this
  work regresses anything already working on Linux.
- **Windows / M5.** Not addressed here — see the roadmap-deviation note at the top.
- **Formalizing a `CertStore` interface abstraction.** Deferred — `wipe.js` gets a plain platform
  branch instead. See the roadmap-deviation note at the top.
- **Cryptographic device-token binding.** Same boundary M4 already documented (surfacing, not
  binding) — unchanged by this milestone.
- **Auto-update, MDM-driven install/config.**
- **Universal (`arm64` + `x64`) `.dmg` build.** Everything in this plan was verified against an
  `x64`-only build (`electron-builder --mac --x64`), matching the VM's actual architecture.
  `electron-builder` bundles `@electron/universal` already and a universal build is very likely a
  small follow-up (no native modules in the runtime dep tree to complicate the lipo merge — see the
  earlier research this plan builds on) — but it was never actually built or tested end-to-end, so
  it is **not** claimed as verified here. Ship `x64` for this milestone; treat `universal` as a fast
  follow once `x64` is proven in the manager's hands.

## Sub-steps (ordered: lab port first, then the one app change, then packaging, then the gate)

### Step 1 — `lab/setup-macos.sh`

- **Files:** `lab/setup-macos.sh` *(new)*, `lab/apache/httpd.conf` *(new, carried over from
  `~/apache-test/httpd.conf`)*, `lab/apache/certs/{server,ca}.ext` *(new, mirroring
  `lab/certs/*.ext`)*.
- **What it does:** native-process equivalent of `lab/setup.sh`'s 11 steps — generate the cert chain
  (same `openssl` calls, mac-local), start Apache (`httpd -f lab/apache/httpd.conf -k start`, no
  sudo per verified inputs), generate the kill-switch keypair, start Postgres.app (or confirm it's
  running — this is the one component started outside the script, since it's a GUI `.app`), start
  Zitadel as a background process with the mapped env vars, run `seed-zitadel.sh` unchanged, write
  `lab/.runtime-env`. **Stops and hands the operator the two `security import` /
  `security add-trusted-cert` commands** (with the actual generated cert paths substituted in)
  instead of attempting them itself — per the verified GUI-session requirement, a script invoked
  non-interactively cannot complete this step.
- **Verify:** `curl` the three ports with/without the client cert, matching the acceptance-criteria
  table above; confirm Zitadel discovery matches `config.js`'s issuer (same assertion `setup.sh`
  already makes); confirm `lab/.runtime-env` is written.

### Step 2 — `lab/teardown-macos.sh`

- **Files:** `lab/teardown-macos.sh` *(new)*.
- **What it does:** mirrors `lab/teardown.sh`'s structure (both modes: full and `--for-setup`) —
  stop Apache (`httpd -k stop`), stop the Zitadel process, remove `lab/.runtime-env` and the seed
  dir, clear `tokens.enc`/`kill-ledger.json`, remove the generated cert files, remove the kill
  signing keypair. **Full mode additionally removes the client identity and the trusted CA from
  Keychain** — `security delete-identity` for the client cert+key (see Step 3 for why not
  `delete-certificate`), and `security remove-trusted-cert` **plus** `security delete-certificate`
  for the CA (removing trust settings alone leaves the CA certificate object itself sitting in the
  keychain — both calls are needed for a clean removal, the direct analogue of Linux teardown's
  `certutil -D -n "$CA_NICK"`).
- **Verify:** `security find-identity` / `security find-certificate` show nothing matching after a
  full teardown; re-running `setup-macos.sh` afterward succeeds from a genuinely clean state.

### Step 3 — `src/main/wipe.js` macOS branch

- **Files:** `src/main/wipe.js` *(modify)*.
- **What it does:** wraps clause (b) — the NSS `certutil -F` call — in a `process.platform` branch.
  macOS: `security delete-identity` matched by the same `CERT_SUBJECT_CN`, **not**
  `security delete-certificate`. This mirrors the existing NSS comment's own warning almost exactly
  (`"NEVER use -D - it removes only the cert, orphaning the private key"`) — `delete-certificate`
  on macOS is the same trap: it can remove the certificate object while leaving the private key
  behind, whereas `delete-identity` removes the cert+key pair atomically, matching what `-F` does on
  NSS. **This exact command has not been tested yet** — flagged honestly rather than presented as
  verified; confirming `security delete-identity`'s exact matching syntax and atomic behavior is
  part of this step's own verification, not a carried-over smoke-test fact like the rest of this
  plan.
- **Verify:** repeat the same two-path test already run on Linux for the `da457b0` fix (success
  path: real cert+key in Keychain, real `tokens.enc`, confirm `[wipe] Done. { sessionCleared: true,
  certDeleted: true, tokensCleared: true }` byte-for-byte identical to the Linux log line; failure
  path: cert already absent, confirm `certDeleted: false` and `tokens.enc` still gets cleared). The
  log line shape must not change on either platform — `kill-wipe-log.png` depends on it.

### Step 4 — `lab/run-app-macos.sh`

- **Files:** `lab/run-app-macos.sh` *(new)*.
- **What it does:** the macOS equivalent of `lab/run-app.sh`, much simpler — source
  `lab/.runtime-env`, launch target auto-detection (packaged `.app` if present, else dev source),
  and launch directly. **No `dbus-run-session`, no `gnome-keyring-daemon`, no
  `lab/ensure-keyring.py`** — `safeStorage` on macOS talks to Keychain directly via the OS, with none
  of the Linux keyring-bootstrap dance `run-app.sh`'s extensive comments describe.
- **Verify:** launch via this script, confirm `[token-store] logBackend() - platform : darwin` logs
  (the guard fixed in `da457b0`), confirm no keyring-related prompts or errors.

### Step 5 — Packaging: `.dmg`

- **Files:** `electron-builder.yml` *(modify — add a `mac:` block)*, `package.json` *(modify — add
  `"dist:dmg": "electron-vite build && electron-builder --mac dmg --x64"`)*.
- **What it does:** produces `DTL App-<version>.dmg`, matching the ~2-minute build time and output
  shape already observed during smoke testing (`dist/DTL App-<version>.dmg`,
  `dist/DTL App-<version>-mac.zip`). The `files` include-list from the existing config (excluding
  `lab/`, `*.key`, `*.pem`, etc.) applies unchanged — same R1 secret-leak risk as M4, same mitigation.
- **Verify:** `dpkg -c`'s macOS equivalent — inspect the `.dmg`/`.app` contents directly (mount +
  `find`, or extract `app.asar`) and confirm no `lab/`, cert, or key material is bundled, the same
  check already run for the `.deb`.

### Step 6 — `docs/setup-guide-macos.md`

- **Files:** `docs/setup-guide-macos.md` *(new)*.
- **What it does:** mirrors `docs/setup-guide.md`'s shape (prerequisites table, setup steps, launch
  instructions) with macOS specifics folded in explicitly, not left implicit:
  - The two interactive `security` commands, with a note that they need a real login session (not
    SSH) and to expect at most one confirmation click.
  - **Gatekeeper workaround for the `.dmg`:** since it's unsigned and will carry a quarantine
    attribute once downloaded (browser/Slack/etc.), document the right-click → Open → confirm flow
    as the primary instruction (no Terminal needed), with `xattr -cr` as a secondary one-liner for
    whoever preps the machine.
  - **The GPU console noise disclaimer** from the verified inputs above, stated plainly so it doesn't
    read as a bug report waiting to happen.
  - A note that `run-app-macos.sh` is the only supported launch path, same rule as the Linux guide's
    "never use the desktop menu entry" warning, for the same underlying reason (per-machine runtime
    config).

### Step 7 — Behavioral-contract comment linking the two mTLS configs

- **Files:** `lab/nginx/mtls.conf` *(modify — comment only)*, `lab/apache/httpd.conf`
  *(comment only, part of Step 1's new file)*.
- **What it does:** this is a PoC, and a templated/generated single-source config for two entirely
  different web servers would be over-engineering for what it solves — KISS wins here. Instead: a
  short comment block at the top of **both** files stating the five behaviors they must both produce
  (the acceptance-criteria table above), pointing at this document (`M6-macos-integration.md`) as the
  source of truth, with an explicit instruction to re-run the five-case `curl` check against
  **both** platforms whenever either config changes.
- **Verify:** the comment exists in both files and the five-case table matches this document
  verbatim.

### Step 8 — Full regression pass (the gate, mirrors M4 Step 4)

- **Files:** none — verification only.
- **What it does:** launch the packaged `.dmg`-installed app and confirm the entire feature set works
  end-to-end on macOS, the acceptance criteria in full:
  - M1 shell: branding bar, logo, custom home.
  - M0 mTLS: three-case compose test (no cert → 400 + access-denied page renders, not a blank
    window; cert + no token → forced login; cert + token → portal loads).
  - M2 auth: OIDC login flow completes via the system browser.
  - M4 session line: device CN + user email logged.
  - M3 kill switch: sign a fresh `wipe` command, confirm the app wipes (session + Keychain identity
    + tokens) and quits; relaunch forces re-login and `:8443` returns 400 again (cert gone);
    `lab/setup-macos.sh` recovery restores it.
- **Verify:** every item above, on the actual packaged `.dmg`, not the dev source tree — matching
  M4's own insistence that the gate is the installed artifact, not `electron .`.

### Step 9 — `CLAUDE.md` scope update

- **Files:** `CLAUDE.md` *(modify — Scope and Platforms lines only)*.
- **What it does:** replaces the stale "macOS, iOS, and Android are strictly tabled" framing with
  language reflecting macOS as an active, delivered target (iOS/Android remain tabled — this
  milestone says nothing about mobile). Minimal, surgical edit — not a rewrite of the file.
- **Verify:** the line no longer contradicts the shipped `.dmg`.

## Decisions (resolved before implementation)

1. **D-M6-1 · macOS lab = native processes, not containers.** Forced by the hardware
   (`kern.hv_support: 0`), not a preference — see verified inputs.
2. **D-M6-2 · Web server = Apache `httpd` + `mod_ssl` (already on the machine), not compiled nginx.**
   Verified to reproduce all five `mtls.conf` behaviors exactly, including the highest-risk one
   (`:8443` no-cert → 400, not a TLS-layer handshake failure). Rejected a Node.js hand-rolled mTLS
   server alternative early — reimplementing mTLS semantics by hand risks subtle divergence from
   nginx (e.g. wrong status code) in a PoC specifically about device security, where that divergence
   would be the whole point being undermined.
3. **D-M6-3 · Postgres = Postgres.app, not Homebrew-compiled `postgresql@16`.** Avoids the real risk
   of a multi-hour or failing source compile on emulated hardware; bundles the exact matching major
   version.
4. **D-M6-4 · `wipe.js` gets a `process.platform` branch, not a formalized `CertStore` interface.**
   Deliberate deviation from `roadmap.md`'s stated M5 dependency — see the top of this document.
5. **D-M6-5 · Separate scripts throughout (`*-macos.sh`), never a branch inside the existing Linux
   scripts.** `lab/setup.sh`, `teardown.sh`, and `run-app.sh` are verified and already handed over;
   this plan does not touch them, eliminating any path by which this work regresses Linux.
6. **D-M6-6 · `.dmg` ships unsigned, `x64`-only for this milestone.** Signing/notarization and a
   universal build are both explicitly out of scope — see "Out of scope" above.
7. **D-M6-7 · No automated config-sync between `mtls.conf` and the Apache config.** A documented,
   manually-checked behavioral contract (Step 7) is the right amount of rigor for a PoC; a
   templated/generated shared config would be solving a problem this project doesn't have yet.

## Risk assessment

- **R1 (highest) — a secret leaks into the `.dmg`.** Same class of risk M4 already identified for
  the `.deb`. *Mitigation:* same files include-list, same explicit content check in Step 5.
- **R2 — the `:8443` no-cert 400 regresses.** This is the single most fragile piece of this whole
  plan — it took two failed attempts and a debug header to get right during smoke testing (see
  verified inputs), and depends on the non-obvious `%{SSL:...}` prefix. *Mitigation:* the exact
  working config is carried over verbatim in Step 1, and Step 7's behavioral-contract comment exists
  specifically so nobody "simplifies" this `RewriteCond` back to the broken form later.
- **R3 — `security delete-identity`'s exact behavior is unverified.** Unlike almost everything else
  in this plan, this command was never smoke-tested — flagged explicitly in Step 3 rather than
  assumed to work like its NSS analogue.
- **R4 — the two interactive `security` prompts break the "one script, zero interaction" promise
  `lab/setup.sh` set on Linux.** *Mitigation:* documented as an explicit, known exception in the
  acceptance criteria and the setup guide, not discovered mid-setup by whoever runs this next.
- **R5 — Gatekeeper blocks the manager's `.dmg` on first open with no explanation.**
  *Mitigation:* Step 6 documents the workaround as a first-class part of the setup guide.
- **R6 — over-claiming verification.** Several pieces of this plan (Step 3's `delete-identity`, the
  universal build) are genuinely unverified. *Mitigation:* called out explicitly wherever that's
  true, rather than writing every step in the same confident voice as the smoke-tested parts.

## Security considerations (PoC scope)

- **Teardown must remove the trusted CA, not just the client cert** (acceptance criterion 5) — a
  leftover throwaway root CA in a user's trust store is a real, if low-severity, hygiene gap on a
  shared or reused machine.
- **`wipe()`'s Keychain deletion must be atomic (cert + key together)**, mirroring the exact NSS
  concern already documented in `wipe.js` — an orphaned private key defeats the point of the wipe.
- **The `.dmg` ships the app, not the lab** — same boundary as the `.deb`, same verification step.
- **Unsigned `.dmg` + Gatekeeper bypass is a real, if standard, PoC-scope tradeoff** — documented
  openly in the setup guide rather than silently worked around, so it's a known, accepted risk for
  this PoC's audience (the manager, running it once) rather than a production distribution pattern.
- **Out of scope (documented):** code signing/notarization, `CertStore` abstraction, cryptographic
  device-token binding (unchanged from M4's boundary), auto-update, MDM-driven install.

## Next steps

This plan is **not approved**. Per `CLAUDE.md`'s two-tier gate, no implementation code is written
until this document is reviewed and explicitly approved — stopping here.
