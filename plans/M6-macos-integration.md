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

1. `lab/setup-macos.sh` stands up the full native lab — Apache mTLS server, a dedicated Postgres
   instance driven via Postgres.app's bundled CLI binaries, Zitadel, seeded project + native PKCE
   app + test user + kill-switch keypair — with the same "zero console interaction, run one script"
   experience as `lab/setup.sh`, **except exactly two** `security` commands (`import` and
   `add-trusted-cert`) that require a real GUI session and a typed password (see verified inputs).
   Those two are the only exceptions — documented up front, not discovered mid-setup, and **not**
   joined by a third manual step to launch Postgres.app's GUI (see Step 1 and D-M6-8: Postgres is
   driven entirely through its bundled CLI binaries, the GUI app itself is never opened). **The `.dmg`
   must already be installed before `security import` runs** — confirmed empirically that `-T`
   requires its target binary to exist, not just be planned (see Step 1 and D-M6-10) — so the setup
   guide's documented order is app-install first, lab setup second, not the reverse.
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

**Postgres: Postgres.app's bundled binaries, driven directly — the GUI app itself is never launched.
Now fully verified end-to-end (Step 1 implementation), not just designed.** Homebrew's `postgresql@16`
formula ships no bottle older than macOS Sonoma — installing it here means compiling Postgres from
source on an emulated Core2Duo, a real risk of the "hours or fail outright" scenario. Postgres.app
v2.9.5 sidesteps the compile risk entirely: universal binary (Intel + Apple Silicon), requires macOS
10.15+ (comfortably covers Monterey), and — installed correctly — bundles **PostgreSQL 16.14**,
matching the pinned `postgres:16-alpine` major version exactly. No compile, no Homebrew, no sudo.

It bundles standard PostgreSQL CLI binaries at `/Applications/Postgres.app/Contents/Versions/16/bin/`
— `initdb`, `pg_ctl`, `createdb`, `dropdb`, `psql`. These are ordinary upstream PostgreSQL tools;
Postgres.app is a convenience bundler around them, nothing more. The GUI application never needs to
launch at all — `pg_ctl -D <data-dir> start` against a **dedicated data directory** (not Postgres.app's
own default one) is standard `pg_ctl`/`initdb` usage, unrelated to how the binaries happen to be
packaged. `setup-macos.sh` owns this data directory exclusively, so wiping it every run (`rm -rf` +
fresh `initdb`) is the direct, literal equivalent of Linux's `podman volume rm zitadel-db` — confirmed
by running `setup-macos.sh` twice in a row and observing a genuinely different Zitadel `client_id`
each time, not just designed to be that way. See Step 1 for the exact mechanics, D-M6-8/D-M6-9 for
why this is the right shape.

**Two real findings from actually installing it, not caught by research alone:**

- **Any Postgres.app variant that includes PostgreSQL 16 works — only a PostgreSQL-18-only download
  does not.** The first install attempt during Step 1 grabbed a PG18-only variant and hit a real,
  confirmed upstream bug: Zitadel's migration `34_add_cache_schema` fails against Postgres 18
  (`ERROR: partitioned tables cannot be unlogged`). The fix (`zitadel/zitadel` PR #11484) exists but
  was backported to **v4+ only** — this project pins v2.71.10 deliberately (`lab/zitadel/README.md`:
  v4+ breaks the single-container console), so bumping Zitadel isn't an option. **Corrected after
  further testing:** both the "PostgreSQL 16" download and the "all currently supported versions"
  bundle ship a `Versions/16` directory and work — "all currently supported versions" is in fact the
  one actually installed on the test machine. Only a build that installs PostgreSQL 18 exclusively,
  with no `Versions/16` present, lacks it. `PGBIN` in `setup-macos.sh` is hardcoded to
  `.../Versions/16/bin` specifically because of this, not "latest" — using "latest" would silently
  regress into this exact bug if a future default install resolves to a newer bundled major only.
- **Installing the `.dmg` needs no GUI session at all** — corrects the plan's original assumption
  that this step needs a manual drag. `hdiutil attach <dmg> -nobrowse -quiet` mounts it, `cp -R
  "<mounted-volume>/Postgres.app" /Applications/` installs it, `hdiutil detach` + `rm` cleans up —
  all plain CLI operations, unlike `security import`/`add-trusted-cert` which are hard-blocked over
  SSH. Confirmed twice (once for the wrong PG18 download, once for the correct PG16 one). One
  practical catch, hit both times: downloading a `.dmg` and "moving it to Applications" without
  mounting it first just puts the disk-image *file* there, not the installed app — worth calling out
  explicitly in whatever install instructions get written, since it's an easy, silent mistake.
  **Recommendation for `setup-guide-macos.md`:** give the `hdiutil`/`cp -R` one-liner as the primary
  instruction instead of "drag to Applications" — fewer steps, and it sidesteps the
  dmg-vs-app confusion entirely rather than relying on the reader noticing it themselves.

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

**Cert *removal* — `security delete-identity` — is now verified too, not just designed.** This was
the one piece of the whole investigation still resting on an assumption (originally flagged as R3);
resolved by testing it directly against the real leftover identity from the cert-provisioning smoke
test above, over the same SSH session that could not run `security import`:

```bash
security delete-identity -c "DTL-Ubuntu-Test-Device" -t ~/Library/Keychains/login.keychain-db
```

- **Exists on macOS 12, exit 0.** Matching syntax is `-c <common-name>` (as guessed) — confirmed via
  `security delete-identity`'s own usage text: `[-c name] [-Z hash] [-t]`, matching by common-name
  substring or by SHA hash. `-t` additionally removes user trust settings for the identity.
- **Removes the certificate and its private key atomically** — confirmed by checking both
  independently afterward: `security find-certificate -c "DTL-Ubuntu-Test-Device"` and
  `security find-key -a "DTL-Ubuntu-Test-Device"` both returned "could not be found" post-deletion.
  This is the Keychain analogue of NSS's `-F` (not `-D`) — no orphaned-key trap, confirmed rather
  than inferred from the two APIs looking similar.
- **Does not require a GUI session — unlike `security import`.** Ran cleanly over plain SSH, no
  prompt, no `"User interaction is not allowed"` error. This is a genuinely different result from the
  import/trust side of cert provisioning, not just "also worked" — deletion and import apparently
  have different interaction requirements on this OS version. Confirmed the CA cert was left
  untouched (scoping by common name was precise, not a blunt "clear everything" match).
- This directly resolves Step 3 below — no longer an open risk.

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
  setup-macos.sh         ← NEW: Apache + Postgres CLI-driven + bare zitadel binary, same 11-step shape
  teardown.sh            ← UNCHANGED
  teardown-macos.sh      ← NEW: mirrors teardown.sh + Postgres $PGDATA wipe + Keychain CA-trust removal
  run-app.sh             ← UNCHANGED
  run-app-macos.sh        ← NEW: source .runtime-env + launch, no dbus/keyring bootstrap
  apache/                ← NEW: httpd.conf.template (paths as placeholders, resolved by
                             setup-macos.sh into git-ignored lab/.apache-runtime.conf), server/CA
                             cert templates mirroring lab/certs/*.ext
  .postgres-data/        ← GENERATED, git-ignored — dedicated $PGDATA, wiped every setup-macos.sh run
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
- ~~Universal (`arm64` + `x64`) `.dmg` build, deferred as a fast follow.~~ **Superseded by Step 5:**
  built and verified end-to-end (not just estimated) — `lipo -info` on the binary inside the mounted
  `.dmg` confirms both `x86_64` and `arm64` slices. 72s vs. 37s build time and 213MB vs. 120MB `.dmg`
  size, measured against an `x64`-only build, judged worth it to give mhoang (Apple Silicon) a native
  launch with no Rosetta prompt. `dist:dmg` ships universal by default now, no separate `x64` script.

## Sub-steps (ordered: lab port first, then the one app change, then packaging, then the gate)

### Step 1 — `lab/setup-macos.sh`

- **Files:** `lab/setup-macos.sh` *(new)*, `lab/apache/httpd.conf.template` *(new — see path note
  below)*, `lab/apache/certs/{server,ca}.ext` *(new, mirroring `lab/certs/*.ext`)*.
- **What it does:** native-process equivalent of `lab/setup.sh`'s 11 steps, in order:
  1. Generate the cert chain (same `openssl` calls, mac-local).
  2. **Generate the real `httpd.conf` from a template, not hand-copy `~/apache-test/httpd.conf`
     verbatim.** The throwaway config has absolute paths baked in throughout — `PidFile`, `Mutex`,
     `ErrorLog`/`CustomLog`, `SSLCertificateFile`/`SSLCertificateKeyFile`/`SSLCACertificateFile`,
     `DocumentRoot` — all hardcoded to `/Users/system/apache-test/...`. None of that survives being
     committed to the repo as-is (wrong on any other machine, wrong even on this one if the repo
     moves). The committed file is a **template** with placeholder tokens (e.g. `__REPO_ROOT__`);
     `setup-macos.sh` substitutes in the real `$REPO_ROOT`-based absolute paths at generation time
     (mirroring how `setup.sh` already does dynamic substitution for `ISSUER`/`REDIRECT_URI` pulled
     from `config.js`) and writes the resolved config to a git-ignored path (e.g.
     `lab/.apache-runtime.conf`), the same "generated fresh each run, never hand-edited" treatment
     `lab/.runtime-env` already gets.
  3. Start Apache against the generated config (`httpd -f lab/.apache-runtime.conf -k start`, no
     sudo per verified inputs).
  4. Generate the kill-switch keypair (unchanged from Linux).
  5. **Bring up Postgres with a clean slate, without launching the Postgres.app GUI.** This is the
     direct macOS analogue of Linux's `podman volume rm zitadel-db` + fresh container start:
     ```bash
     PGBIN="/Applications/Postgres.app/Contents/Versions/16/bin"
     PGDATA="$REPO_ROOT/lab/.postgres-data"    # per-machine, git-ignored — same treatment as .runtime-env
     rm -rf "$PGDATA"                            # clean slate, every run — the literal equivalent
     "$PGBIN/initdb" -D "$PGDATA" -U root -A trust
     "$PGBIN/pg_ctl" -D "$PGDATA" -l "$PGDATA-log" -o "-p 5432" start
     # poll with pg_isready, same pattern setup.sh already uses for the container
     ```
     Using `-U root` as the superuser name means Zitadel's existing `ADMIN_USERNAME=root` /
     `ADMIN_PASSWORD` env vars need no remapping — same 21 env vars, same values, matching Linux
     exactly. Because `setup-macos.sh` owns this data directory exclusively (never Postgres.app's
     own default one), wiping it every run is a full, faithful clean-slate — not a narrower
     "drop just the zitadel database" approximation. **Verified, not just designed:** ran
     `setup-macos.sh` twice in a row on the VM; the second run produced a genuinely different Zitadel
     `client_id` than the first, proving a real fresh init each time, not reuse of stale state. `-A
     trust` and `--locale=C` were both needed in practice (`initdb` otherwise refuses outright on
     this VM's broken `LANG`/`LC_*` settings — confirmed, not assumed) but aren't shown in the
     snippet above; see the real `lab/setup-macos.sh` for the exact invocation. See the Postgres.app
     entry in "verified inputs" above for the PG16-vs-PG18 finding this also surfaced.
  6. Start Zitadel as a background process with the mapped env vars (unchanged mapping from the
     verified-inputs section).
  7. Run `seed-zitadel.sh` unchanged.
  8. Write `lab/.runtime-env`.
  9. **Stop and hand the operator exactly two commands** — `security import` and
     `security add-trusted-cert`, with the actual generated cert paths substituted in — instead of
     attempting them itself, per the verified GUI-session requirement. **Nothing else in this script
     requires operator interaction** — Postgres is CLI-driven per step 5, so there is no third manual
     "launch Postgres.app" step, resolving the contradiction flagged in review.

  **Operational ordering constraint, confirmed empirically, not assumed (this is why Step 6 below
  reorders "install the app" ahead of "run the lab setup"):** `security import -T <path>` requires
  the target binary to **already exist** at import time — it does not accept a not-yet-installed
  app and defer the check. Confirmed directly on the mac VM with a clean side-by-side comparison:

  ```
  # -T pointing at a path that does not exist:
  $ security import client.p12 -k login.keychain-db -P ... -T "/path/does/not/exist"
  security: SecTrustedApplicationCreateFromPath ...: UNIX[No such file or directory]
  # fails immediately, at path validation — before the interactive-session check is even reached

  # -T pointing at the real, already-built app:
  $ security import client.p12 -k login.keychain-db -P ... -T "<real app path>"
  security: SecKeychainItemImport: User interaction is not allowed.
  # fails later, at the actual import step (needs a GUI session, as already known) - the path itself
  # validated fine
  ```

  This is a hard failure, not a soft warning — a not-yet-installed app is not a viable `-T` target.
  **`lab/setup-macos.sh`'s printed `security import` command must reference the app's real,
  already-installed path** (`/Applications/DTL App.app/Contents/MacOS/DTL App` — the standard
  post-`.dmg`-install location, not a dev build path that might move). Concretely, this means: the
  script should check whether that path exists before printing the two commands, and print a clear
  "install the app first, then re-run this script (or run these two commands directly, substituting
  the same generated cert paths)" message if it doesn't — rather than handing over a command that
  will fail with a confusing `SecTrustedApplicationCreateFromPath` error the operator has no context
  for. This is an operational-sequencing dependency on Step 5 (packaging) even though Step 5 is
  documented later in this plan for incremental-build reasons — see Step 6 for the corrected
  real-world order.
- **Verify:** `curl` the three ports with/without the client cert, matching the acceptance-criteria
  table above; confirm Zitadel discovery matches `config.js`'s issuer (same assertion `setup.sh`
  already makes); confirm `lab/.runtime-env` is written; **run `setup-macos.sh` twice in a row** and
  confirm the second run succeeds cleanly against a fresh Zitadel/Postgres state — this is the
  concrete test that the clean-slate step actually works, not just that the first run does.

### Step 2 — `lab/teardown-macos.sh`

- **Files:** `lab/teardown-macos.sh` *(new)*.
- **What it does:** mirrors `lab/teardown.sh`'s structure (both modes: full and `--for-setup`) —
  stop Apache (`httpd -k stop`), **stop Postgres and remove its dedicated data directory**
  (`"$PGBIN/pg_ctl" -D "$PGDATA" stop` then `rm -rf "$PGDATA"` — the `--for-setup` subset removes
  this too, same as it does for the container volume on Linux, since a stale `$PGDATA` defeats the
  whole point of Step 1's clean-slate design), stop the Zitadel process, remove `lab/.runtime-env`
  and the seed dir, clear `tokens.enc`/`kill-ledger.json`, remove the generated cert files, remove
  the kill signing keypair. **Full mode additionally removes the client identity and the trusted CA
  from Keychain** — `security delete-identity -c "$CLIENT_CN" -t` for the client cert+key (now
  verified — see Step 3), and `security remove-trusted-cert` **plus**
  `security delete-certificate -c "$CA_NICK"` for the CA (removing trust settings alone leaves the
  CA certificate object itself sitting in the keychain — both calls are needed for a clean removal,
  the direct analogue of Linux teardown's `certutil -D -n "$CA_NICK"`).
- **Verify:** `security find-identity` / `security find-certificate` show nothing matching after a
  full teardown; `$PGDATA` no longer exists; re-running `setup-macos.sh` afterward succeeds from a
  genuinely clean state (the same twice-in-a-row test from Step 1, run via a teardown in between
  this time).

### Step 3 — `src/main/wipe.js` macOS branch

- **Files:** `src/main/wipe.js` *(modify)*.
- **What it does:** wraps clause (b) — the NSS `certutil -F` call — in a `process.platform` branch.
  macOS: `security delete-identity -c "${CERT_SUBJECT_CN}" -t`, **not**
  `security delete-certificate`. This mirrors the existing NSS comment's own warning almost exactly
  (`"NEVER use -D - it removes only the cert, orphaning the private key"`) — `delete-certificate` on
  macOS is the same trap: it removes the certificate object but can leave the private key behind,
  whereas `delete-identity` removes the cert+key pair atomically, matching what `-F` does on NSS.
  **Verified directly during review** (no longer an open assumption, formerly R3): ran against the
  real leftover identity from the cert-provisioning smoke test, over plain SSH — exit 0, both the
  certificate and its private key confirmed gone independently afterward
  (`security find-certificate` / `security find-key` both returned "could not be found"), and —
  notably different from `security import` — ran cleanly over SSH with no
  `"User interaction is not allowed"` error. `wipe()`'s existing `runCertutil()`-style helper pattern
  (spawn, capture stderr, reject on non-zero exit) carries over directly for the `security`
  invocation.

  **This SSH evidence is necessary but not sufficient — it does not by itself prove `wipe()` will
  run unattended when it matters.** `wipe()` spawns `security delete-identity` as a child process of
  the running Electron app, not from a terminal. An SSH session can't display a Keychain
  authorization dialog at all, so "no prompt appeared over SSH" is consistent with two different
  realities: either the operation genuinely needs no authorization (what the evidence suggests), or
  it does need authorization and SSH's inability to show a prompt just failed differently than
  expected. On Linux, `certutil -F` runs silently with no such ambiguity — this is a macOS-only
  failure mode, and if it goes the wrong way the consequence is severe: the kill switch stalls on an
  authorization dialog, and an operator who clicks Cancel (or one who never sees the machine, since
  this is a *remote* kill switch) defeats it entirely.
- **Verify — two separate things, not one test covering both:**
  1. **The two-path result-accuracy test**, same as Linux's `da457b0` fix: success path (real
     cert+key in Keychain, real `tokens.enc`, confirm `[wipe] Done. { sessionCleared: true,
     certDeleted: true, tokensCleared: true }` byte-for-byte identical to the Linux log line);
     failure path (cert already absent, confirm `certDeleted: false` and `tokens.enc` still gets
     cleared). The log line shape must not change on either platform — `kill-wipe-log.png` depends
     on it.
  2. **A separate, explicitly named check: "wipe completes fully unattended, no Keychain
     authorization prompt appears, when triggered as a child process of the running packaged app."**
     Not inferred from (1) or from the SSH evidence above — observed directly, over VNC, by actually
     triggering a kill-switch wipe against the running `.app` (not `electron .`, not a terminal
     invocation) and watching whether a dialog appears. This is the check that actually answers the
     question raised in review; passing (1) alone does not.

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
  `"dist:dmg": "electron-vite build && electron-builder --mac dmg"`)*.
- **What it does:** produces `DTL App-<version>-universal.dmg` — **universal (x64+arm64), not
  x64-only.** No native modules exist in this app and `@electron/universal` was already present in
  `node_modules`, so a universal build is buildable from this Intel VM at low marginal cost.
  Measured on a real build (not estimated): **72s vs. 37s** build time, **213MB vs. 120MB** `.dmg`
  size, universal vs. x64-only. Single `dist:dmg` script, no separate x64 variant — the answer would
  always be universal, so a choice between the two scripts is a choice nobody actually needs to
  make. The extra cost is a non-issue for something built occasionally, not on every commit, and it
  buys a native launch on Apple Silicon (mhoang's Mac) with no Rosetta prompt and no slower cold
  start — worth more than the time/size delta for a demo. The `files` include-list from the existing
  config (excluding `lab/`, `*.key`, `*.pem`, etc.) applies unchanged — same R1 secret-leak risk as
  M4, same mitigation, verified separately against the universal artifact (not assumed identical to
  an earlier x64-only test build).
- **Icon:** `src/renderer/assets/logo.png` (446x448, used by `linux:`) is below electron-builder's
  mac `.icns` minimum (512x512 — confirmed by a real build error, not assumed). A separate
  `logo_macos.png` (512x512, cropped from a 512x514 source — 2px of pure-white margin trimmed, not
  the mark) is used for `mac.icon` instead. **Known gaps, not fixed now:** (1) 512px is the floor,
  not the 1024px electron-builder prefers for a crisp Retina icon — confirmed empirically, the
  generated `.icns` has no `512x512@2x` slot, so it'll look slightly soft at large Retina sizes;
  fixable if a higher-resolution source logo turns up. (2) `logo.png` and `logo_macos.png` are two
  files with no shared source that must be kept visually in sync by hand.
- **Verify:** `dpkg -c`'s macOS equivalent — inspect the `.dmg`/`.app` contents directly (mount +
  `find`, or extract `app.asar`) and confirm no `lab/`, cert, or key material is bundled, the same
  check already run for the `.deb`. Also confirm the `.icns` actually generated and the packaged
  `.app` shows the DTL logo (not the default Electron icon), and that the bundle is still named
  exactly `DTL App.app` (three places hardcode that path: `setup-macos.sh`'s `-T` hint,
  `run-app-macos.sh`'s `DEFAULT_BIN`, and the setup guide).

### Step 6 — `docs/setup-guide-macos.md`

- **Files:** `docs/setup-guide-macos.md` *(new)*.
- **What it does:** mirrors `docs/setup-guide.md`'s shape (prerequisites table, setup steps, launch
  instructions) with macOS specifics folded in explicitly, not left implicit. **The documented order
  is corrected from the plan's build order, per the `-T` finding in Step 1** — install the app
  *before* provisioning the cert, not after:
  1. Build/install the `.dmg` first, including the Gatekeeper right-click → Open workaround (below)
     — the app must exist at `/Applications/DTL App.app` before the next step, because `-T` requires
     its target to already exist (confirmed empirically — see Step 1).
  2. Run `lab/setup-macos.sh` — generates certs, stands up Apache/Postgres/Zitadel, and hands over
     the two `security` commands, now referencing the real installed app path.
  3. Run those two commands, with a note that they need a real login session (not SSH) and to expect
     at most one confirmation click.
  4. Launch via `lab/run-app-macos.sh`.
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
  short comment block at the top of **both** files with the literal five-row Port/Behavior table
  (not a paraphrase — this document is git-ignored, so the comment is the only shipped copy of the
  contract), each file naming the other as its mirror, and pointing at the "Check the endpoints"
  section of `docs/setup-guide.md`/`docs/setup-guide-macos.md` as the executable, actually-committed
  form of the check to re-run on **both** platforms whenever either config changes. **Correction
  from the original plan:** do NOT cite this document (`M6-macos-integration.md`) as the thing to
  consult — it's git-ignored, unavailable to most readers, and doing so was a real bug caught during
  Step 7 itself (Apache's Step-1 comment already pointed here). Background-only mention is fine;
  it must not be presented as the source of truth.
- **Verify:** the comment exists in both files with the literal table, `httpd -t` still passes
  after regenerating the Apache config from the edited template (comment-only changes shouldn't
  break parsing, confirmed rather than assumed).

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
3. **D-M6-3 · Postgres binaries = Postgres.app's bundle, but driven directly via `pg_ctl`/`initdb`
   against a dedicated data directory — the GUI app is never launched.** Avoids the real risk of a
   multi-hour or failing source compile on emulated hardware (the reason Homebrew was rejected);
   bundles the exact matching major version; and, because `setup-macos.sh` owns its own `$PGDATA`
   rather than sharing Postgres.app's default one, wiping it every run is a literal equivalent of
   Linux's `podman volume rm zitadel-db` rather than an approximation — see D-M6-8.
4. **D-M6-4 · `wipe.js` gets a `process.platform` branch, not a formalized `CertStore` interface.**
   Deliberate deviation from `roadmap.md`'s stated M5 dependency — see the top of this document.
5. **D-M6-5 · Separate scripts throughout (`*-macos.sh`), never a branch inside the existing Linux
   scripts.** `lab/setup.sh`, `teardown.sh`, and `run-app.sh` are verified and already handed over;
   this plan does not touch them, eliminating any path by which this work regresses Linux.
6. **D-M6-6 · `.dmg` ships unsigned, universal (`x64`+`arm64`) as of Step 5.** Signing/notarization
   stays out of scope — see "Out of scope" above. Universal was originally deferred as a fast follow
   but built and verified in Step 5 itself once the marginal build cost (72s vs. 37s) proved small.
7. **D-M6-7 · No automated config-sync between `mtls.conf` and the Apache config.** A documented,
   manually-checked behavioral contract (Step 7) is the right amount of rigor for a PoC; a
   templated/generated shared config would be solving a problem this project doesn't have yet.
8. **D-M6-8 · Zitadel's Postgres database gets a full clean-slate every `setup-macos.sh` run**,
   matching Linux's every-run container-volume nuke, via `rm -rf $PGDATA` + fresh `initdb` rather
   than a narrower `DROP DATABASE zitadel` (which would need a persistent, already-initialized
   cluster to drop *against*, adding its own bootstrapping problem). Full-cluster wipe is simpler
   and more faithful to what Linux actually does. Genuinely closes the gap flagged in review: without
   this, a second `setup-macos.sh` run would hit an already-initialized Zitadel and either fail
   `start-from-init` or seed on top of stale data, breaking the "equivalent to Linux" claim outright.
9. **D-M6-9 · Acceptance criterion 1's manual-step count is exactly two, not three.** Resolves the
   contradiction flagged in review — D-M6-3's CLI-driven Postgres means the GUI app is never opened,
   so the only manual steps anywhere in `setup-macos.sh` are the two `security` commands.
10. **D-M6-10 · The documented operational order is app-install first, lab setup second — the
    reverse of the plan's own build order.** Confirmed empirically, not assumed: `security import -T
    <path>` fails immediately (`SecTrustedApplicationCreateFromPath ...: No such file or directory`)
    if the target binary doesn't exist yet — it does not defer the check. `setup-macos.sh` prints the
    two `security` commands referencing `/Applications/DTL App.app/...`, so that path must already
    be real when the operator runs them. This only affects the *documented runbook* (Step 6) and
    `setup-macos.sh`'s own path-existence check before printing its commands — it does not change
    which order the scripts themselves get *written* in during implementation (Step 1 can still be
    built and tested before Step 5, using a manually-placed test binary the way this finding itself
    was verified).

## Risk assessment

- **R1 (highest) — a secret leaks into the `.dmg`.** Same class of risk M4 already identified for
  the `.deb`. *Mitigation:* same files include-list, same explicit content check in Step 5.
- **R2 — the `:8443` no-cert 400 regresses.** This is the single most fragile piece of this whole
  plan — it took two failed attempts and a debug header to get right during smoke testing (see
  verified inputs), and depends on the non-obvious `%{SSL:...}` prefix. *Mitigation:* the exact
  working directives are carried over into the committed template verbatim (only the absolute paths
  around them get substituted at runtime — see Step 1), and Step 7's behavioral-contract comment
  exists specifically so nobody "simplifies" this `RewriteCond` back to the broken form later.
- **R3 (partially resolved) — `security delete-identity`'s behavior.** The command's existence,
  syntax, and atomic cert+key removal are fully verified (see Step 3) — that part is closed. **What
  remains genuinely open:** whether it prompts for authorization when run as a child process of the
  packaged GUI app specifically, as opposed to a terminal/SSH context. The SSH test that closed the
  syntax question cannot answer this — an SSH session can't display a prompt at all, so its clean
  exit is consistent with either "no prompt needed" or "would have prompted, failed differently
  instead." This is why Step 3's verification now has a dedicated, separately-named check for it
  rather than treating the SSH result as sufficient — see Step 3.
- **R4 (resolved) — the Postgres clean-slate design.** Was open going into Step 1 implementation;
  now verified — `setup-macos.sh` run twice in a row on the VM produced a genuinely different
  Zitadel `client_id` each time, proving real fresh-init behavior, not reuse of stale state. Also
  surfaced a real, unrelated finding along the way: the PG18 download (easy to grab by mistake -
  it's more prominent on Postgres.app's download page than the "PostgreSQL 16" one) hits a
  confirmed upstream Zitadel/Postgres-18 migration bug whose fix isn't available on our pinned
  Zitadel version - see the Postgres.app entry in "verified inputs."
- **R5 — the two interactive `security` prompts break the "one script, zero interaction" promise
  `lab/setup.sh` set on Linux.** *Mitigation:* documented as an explicit, known exception in the
  acceptance criteria and the setup guide, not discovered mid-setup by whoever runs this next.
- **R6 — Gatekeeper blocks the manager's `.dmg` on first open with no explanation.**
  *Mitigation:* Step 6 documents the workaround as a first-class part of the setup guide.
- **R7 — over-claiming verification.** R3 and R4 are now resolved; the universal-build question
  (out of scope for this milestone - see D-M6-6) remains genuinely unverified. *Mitigation:* called
  out explicitly wherever that's true, rather than writing every step in the same confident voice as
  the smoke-tested parts.

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
