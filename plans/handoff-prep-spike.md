# Handoff-prep spike — one-command lab bring-up (`setup.sh` / `teardown.sh`)

> Detailed plan for a **handoff-prep spike** on branch `improve-ui-ux`. **Planning only — no code
> yet.** Per CLAUDE.md's two-tier gate, this plan is reviewed and approved before any script is
> written. This spike is **infra/scripts + the launch wrapper only** — it does **not** touch any
> M0–M4 or M1b application code (`cert-select.js`, `wipe.js`, `window.js`, the kill switch, the OIDC
> flow all stay byte-identical).

## Why this spike (context)

mhoang wants the working Linux build as a self-contained package: (a) the code, (b) the `.deb`,
(c) a feature list, and — the real ask — (d) the **effort estimate to roll out to Windows / macOS /
mobile**. His hard requirement: **he hand-configures nothing** — he runs one script and sees it
work. Today that's impossible: `lab/zitadel/README.md` Steps 3–5 (create Project → register Native
PKCE App → create test user) are all **manual Web Console clicks**, and the resulting `client_id` is
hand-copied into config. That manual seam is the single biggest friction in the handoff.

**This spike proves the riskiest piece first** — fully automated, repeatable lab bring-up with a real
Zitadel IdP and zero console interaction — *before* any handoff docs (feature list, multi-platform
effort memo) are written. If auto-seeding a real IdP headlessly turned out infeasible, every handoff
doc built on top of it would be worthless; so we de-risk the foundation first. The handoff docs
themselves are **out of scope for this spike** (see Next steps).

## Empirically confirmed before planning (the riskiest assumptions, proven on the VM)

Per the instruction "do not assume a seeding mechanism," I stood up a **fully isolated throwaway
Zitadel** (separate port 8091, separate Postgres on 5433, fresh volumes — the running lab instance on
8090 was never touched) and proved the whole path end-to-end, then tore the probe down:

1. **FirstInstance auto-seeds a machine (service-account) user + PAT to a file — zero console clicks.**
   With `ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_USERNAME`, `..._MACHINE_NAME`,
   `..._PAT_EXPIRATIONDATE`, and `ZITADEL_FIRSTINSTANCE_PATPATH=/pat/pat.txt` set on the container,
   `start-from-init` wrote a **72-byte PAT** to the bind-mounted file on first boot. Confirmed the PAT
   authenticates: `GET /auth/v1/users/me` → `user: zitadel-admin-sa`.
2. **The Management REST API creates everything else, authenticated by that PAT** (all endpoints
   returned 401 unauthenticated = present, not 404; then succeeded with the Bearer PAT):
   - `POST /management/v1/projects` → project created (real id).
   - `POST /management/v1/projects/{id}/apps/oidc` with `appType: OIDC_APP_TYPE_NATIVE`,
     `authMethodType: OIDC_AUTH_METHOD_TYPE_NONE`, grant types code+refresh → returned a real
     **`clientId`** with **`clientSecret` empty** (confirms a public PKCE native app — exactly what
     `oidc.js` expects: `token_endpoint_auth_method: 'none'`).
   - `POST /management/v1/users/human/_import` with `email.isEmailVerified: true`, `password: …`,
     `passwordChangeRequired: false` → user created, then `GET /management/v1/users/{id}` confirmed
     `state: USER_STATE_ACTIVE`, `email verified: True`. **No verification mail, no console.** This is
     exactly what `checkEmailDomain()` needs (`email_verified === true` AND `@dtl.local`).
3. **`--steps` overwrite files are supported** by `zitadel setup`/`start-from-init` (`--steps
   stringArray`), but the env-var FirstInstance surface above is sufficient — we do **not** need a
   custom steps file. **Terraform is not required** (the docs mention it, but the Management API +
   PAT path is lighter and confirmed working — KISS).

**Conclusion:** the seeding mechanism is **FirstInstance (env) for the bootstrap PAT + machine SA →
Management REST API (curl) for Project + Native PKCE App + human user.** No CLI `user add-human` (it
doesn't exist), no Terraform, no console. This is the mechanism the plan commits to.

## Numbered decisions

1. **Seeding mechanism = FirstInstance PAT bootstrap → Management API (curl + PAT).** Confirmed
   empirically (above). The machine SA + PAT is seeded by env on first `start-from-init`; a
   `seed-zitadel.sh` helper (called by `setup.sh`) then curls the Management API to create the
   Project, Native PKCE App, and `testuser@dtl.local`. No Terraform, no console, no ROPC.
2. **Client ID flows at RUNTIME via `lab/.runtime-env`, never build-time.** The seeded app's
   `client_id` differs every setup. `setup.sh` writes `export DTL_OIDC_CLIENT_ID=<fresh id>` (plus the
   other runtime env — see Decision 3) into `lab/.runtime-env`. The launch wrapper `source`s that file
   before exec'ing the packaged binary, injecting it into the `.deb`'s `process.env`. Confirmed the app
   reads it: `config.js` → `OIDC.clientId = process.env.DTL_OIDC_CLIENT_ID || <fallback>`. The
   build-time `.env` is irrelevant to a packaged binary — this is the whole point.
3. **`lab/.runtime-env` carries all cwd-independent runtime overrides, not just the client id.** The
   packaged app's `process.cwd()` is not the repo root, so `KILL.caPath`'s `'lab/certs/ca.pem'` default
   breaks (M4 as-built R2). The runtime-env file therefore also exports `DTL_KILL_CA_PATH=<abs path to
   lab/certs/ca.pem>`. Issuer/redirect/CN keep their config.js defaults (already correct for the lab) —
   only the two genuinely environment-derived values (fresh client_id, absolute CA path) are written.
   Keeps the file minimal (YAGNI).
4. **`setup.sh` initializes Zitadel from a CLEAN Postgres volume every run** (`start-from-init` on a
   fresh `zitadel-db` volume). Zitadel first-init is finicky on dirty state (migration / unique-key
   errors); a guaranteed-clean volume per run is the only reliable repeatable path. `setup.sh` is
   therefore **destructive-then-fresh** for the lab containers/volumes (it calls the teardown's
   container/volume cleanup first), not additive.
5. **`podman run` on host network, not `podman compose`.** The VM's rootless `podman compose` fails
   (documented in `lab/zitadel/README.md` — systemd D-Bus / cgroup / bridge issues). `setup.sh` uses
   the `podman run --network=host` path that already works on this VM. `compose.yml` stays as-is for
   machines where compose works (not used by the script).
6. **Zitadel stays REAL (Authorization Code + PKCE against the real IdP).** We remove only the *setup*
   friction (auto-seed), never the auth itself. No mock IdP. Non-negotiable per the task.
7. **Pin `v2.71.10`** (unchanged). `:latest`/v4 moved the login UI to a separate app and breaks the
   single-container console (documented). The seeding proof above ran on exactly `v2.71.10`.
8. **`teardown.sh` removes only app/test-created state; never prerequisites.** It returns the VM to a
   "never ran DTL App" state (NSS entries, containers+volumes, tokens.enc, generated certs/keys, kill
   signing key, `lab/.runtime-env`, kill command JSONs, unpacked `.deb`). It never touches
   node/podman/system packages — those are prerequisites, checked by `setup.sh` preflight (Decision 9).
9. **Prerequisites are preflight-checked with clear failure messages, not installed and not removed.**
   The VM can be *cleaned* (app traces removed) but not reset to blank Ubuntu; system deps outlive
   teardown, so they must be explicit. `setup.sh` fails fast if any are missing (see Prerequisite list).
10. **Idempotent + repeatable is the acceptance bar.** `teardown → setup → launch → login`, then
    `teardown → setup` again must both fully succeed. A one-shot script that only works on a pristine
    box is a fail (Decision 4 makes each run start clean, which is what buys repeatability).
11. **New lab secrets get `.gitignore` entries before anything is written.** `lab/.runtime-env` (holds
    the fresh client_id — not a secret per se but per-machine and must never be committed) and the
    Zitadel PAT output file (`lab/zitadel/.seed/` or similar) are added to `.gitignore`. Existing
    ignores already cover `lab/certs/*`, `lab/kill/*.key`, `lab/zitadel/.env`, `lab/zitadel/data/`.
    R1 secret-leak discipline (same as the `.deb` packaging) applies to the commit of these scripts.

## Prerequisite list (preflight-checked by `setup.sh`, documented for mhoang)

| Prerequisite | Check | Why | If missing |
|---|---|---|---|
| `podman` | `command -v podman` | nginx + Zitadel + Postgres containers | "install podman (rootless)" |
| `node` + `npm` | `command -v node npm` | build the app / run `sign-command.sh` | "install Node 20+ (nvm)" |
| `openssl` | `command -v openssl` | generate the cert chain | "install openssl" |
| `certutil` + `pk12util` | `command -v certutil pk12util` | NSS cert provisioning | "sudo apt install libnss3-tools" |
| `curl`, `python3` | `command -v curl python3` | Zitadel API seeding + JSON parse | "install curl / python3" |
| keyring / libsecret + `dbus-run-session` | `command -v dbus-run-session gnome-keyring-daemon` | `safeStorage` on NoMachine | "install gnome-keyring, dbus-x11" |

`setup.sh` prints the full list and the exact missing item(s), then exits non-zero — it never
auto-installs (no sudo assumed).

## `setup.sh` — step breakdown (all on the VM, `~/Downloads/dtl-app`)

0. **Preflight** — check every prerequisite (Decision 9); exit non-zero with the missing list if any.
1. **Clean slate** — call the teardown's container/volume/NSS/runtime-env cleanup (Decision 4) so the
   run starts from a known-empty state. (Does *not* remove prerequisites.)
2. **Certs** — `bash lab/certs/gen-certs.sh` (OpenSSL CA + server SAN cert + client `CN=DTL-Ubuntu-
   Test-Device` + `client.p12`).
3. **NSS provisioning** — `bash lab/provision-nss.sh` (import CA `CT,C,C` + client cert/key into
   `~/.pki/nssdb`).
4. **nginx** — `podman run` the `dtl-mtls-nginx` container mapping **all three ports** `:8443`
   (mTLS-on, tool-1), `:8444` (optional + `/kill`), `:8445` (CN-gated 403, tool-2 — M1b, kept),
   mounting `lab/nginx/mtls.conf`, `lab/certs`, `lab/kill`.
5. **Kill command** — initialize `lab/kill/kill-command.json` to the no-op (`cp lab/kill/kill-none.json
   lab/kill/kill-command.json`) so the poller stays quiet during the demo.
6. **Postgres** — `podman run` a fresh `zitadel-db` (clean named volume) on host network; wait for
   `pg_isready`.
7. **Zitadel init + PAT seed** — `podman run zitadel … start-from-init` with the FirstInstance
   **machine SA + PAT** env (Decision 1), `PATPATH` bind-mounted to `lab/zitadel/.seed/pat.txt`; poll
   `/.well-known/openid-configuration` until up (~60–90 s).
8. **Seed resources via Management API** — `seed-zitadel.sh` reads the PAT, then curls:
   Project `DTL App` → Native PKCE App `dtl-electron` (redirect `http://127.0.0.1:51234/callback`,
   auth method NONE) → capture `client_id` → import `testuser@dtl.local` (email verified, password
   `Test1234!`, no change required). All confirmed working in the proof.
9. **Write `lab/.runtime-env`** — `export DTL_OIDC_CLIENT_ID=<fresh id>` + `export
   DTL_KILL_CA_PATH=<abs lab/certs/ca.pem>` (Decisions 2, 3).
10. **Summary** — print the three curl checks to run and the exact launch command (below); exit 0.

## `seed-zitadel.sh` — the Management-API helper (called by step 8)

Thin, single-purpose: takes the PAT file path + issuer base URL, performs the four confirmed calls,
and echoes the `client_id` to stdout (captured by `setup.sh`). Fails loudly (non-zero) if any call
returns a non-2xx or an empty `client_id` — never writes a partial `.runtime-env`.

## Runtime-env wiring (the packaged-binary path, end-to-end)

The launch wrapper (the existing NoMachine `dbus-run-session` + keyring one) gains **one line** —
`source lab/.runtime-env` before the exec — so the fresh client_id + absolute CA path land in the
running `.deb`'s `process.env`:

```bash
cd ~/Downloads/dtl-app          # or the unpacked-.deb dir
source lab/.runtime-env         # ← injects DTL_OIDC_CLIENT_ID + DTL_KILL_CA_PATH
dbus-run-session -- bash -c '
  eval $(gnome-keyring-daemon --start --components=secrets)
  GNOME_DESKTOP_SESSION_ID=this-is-deprecated ELECTRON_DISABLE_SANDBOX=1 \
    "<path>/dtl-app"            # packaged binary, or ./node_modules/.bin/electron . for dev
'
```

`config.js` already reads both via `process.env` with the correct fallbacks — **no app code change**.
Wrapper env precedence confirmed: `source` sets the vars in the shell that `dbus-run-session` inherits,
so they reach the child process. (The `.deb`'s `.desktop` `Exec=` does not `source` anything — hence
the wrapper, not the menu entry, is the sanctioned launch path for the lab; documented for mhoang.)

## `teardown.sh` — step breakdown (returns VM to "never ran DTL App")

Removes **only** app/test-created state; every step is idempotent (`|| true`), none touch prerequisites:

1. `podman rm -f dtl-mtls-nginx zitadel zitadel-db` (+ any probe leftovers).
2. `podman volume rm zitadel-db` (clean slate for next init — Decision 4).
3. NSS: `certutil -F -n DTL-Ubuntu-Test-Device` + `certutil -D -n DTL-Test-Root-CA` from `~/.pki/nssdb`.
4. `rm -f` generated certs/keys: `lab/certs/{ca,server,client}.*` (`.key/.crt/.pem/.p12/.srl/.csr`).
5. `rm -f lab/kill/kill-signing.key` (regenerated per box) + reset `lab/kill/kill-command.json`.
6. `rm -f lab/.runtime-env` + `rm -rf lab/zitadel/.seed/` (PAT output).
7. `rm -f "~/.config/DTL App/tokens.enc"` + `rm -f "~/.config/DTL App/kill-ledger.json"` (wipe app state).
8. Remove the unpacked `.deb` dir (e.g. `rm -rf ~/dtl-app-installed`) — leaves the source repo intact.
9. Print what was removed + a reminder that prerequisites (node/podman/libnss3-tools/…) were left in
   place by design.

## VM verification plan (the acceptance bar — Decision 10)

**Curl-first (before app), all three nginx ports** (with the test cert):
- `:8443` with cert → 2xx, HTML comment `verify=SUCCESS subject=CN=DTL-Ubuntu-Test-Device`.
- `:8445` with cert → **403** (tool-2, CN not approved).
- `:8444` no cert → `verify=NONE`.

**Zitadel seeding (before app):**
- `/.well-known/openid-configuration` `issuer` = `http://127.0.0.1:8090`.
- `lab/.runtime-env` exists and contains a non-empty `DTL_OIDC_CLIENT_ID`.
- `GET /management/v1/users/{testuser}` (with PAT) → `USER_STATE_ACTIVE`, email verified.

**Full end-to-end (the success criterion):**
1. `teardown.sh` → confirm clean state (no lab containers, no NSS entries, no `.runtime-env`).
2. `setup.sh` → completes green, prints the launch command.
3. Launch via the wrapper (sources `.runtime-env`) → **`testuser@dtl.local` / `Test1234!` logs in
   end-to-end with ZERO Web Console interaction** → branded home launcher renders → tool-1 green,
   tool-2 red 403, nav-block amber (the M1b flows, proving the seeded app is fully wired).
4. **Repeatability:** `teardown.sh` → `setup.sh` again → login succeeds a second time (proves each run
   self-cleans and re-seeds; the fresh client_id round-trips through `.runtime-env` both times).

**Regression (unchanged app behaviour):** M0 cert presented to `:8443`; M2 gate still forces login;
M3 kill still wipes+locks; M4 `[session]` line still logs. No app file changed, so these are
confirmatory, not at-risk.

## Related files

**New (this spike):**
- `lab/setup.sh` — the one-command bring-up (orchestrates cert/NSS/nginx/Zitadel/seed/runtime-env).
- `lab/teardown.sh` — the app-trace remover.
- `lab/zitadel/seed-zitadel.sh` — Management-API resource seeder (Project + Native App + user).

**Modified (this spike):**
- The launch wrapper doc/snippet in `lab/zitadel/README.md` (add the `source lab/.runtime-env` line;
  replace manual Steps 3–5 with "run `setup.sh`").
- `.gitignore` — add `lab/.runtime-env` and `lab/zitadel/.seed/` (Decision 11).
- `lab/README.md` — point the run-order at `setup.sh` / `teardown.sh`.

**Untouched (hard guardrail — no app code):** `src/main/**` (all of it — `cert-select.js`, `wipe.js`,
`window.js`, `navigation.js`, `chrome-state.js`, `auth/**`, `kill/**`, `config.js`), `src/preload/**`,
`src/renderer/**`, `src/shared/**`, `electron.vite.config.mjs`, `electron-builder.yml`,
`lab/nginx/mtls.conf` (already correct with :8445), `lab/certs/gen-certs.sh`, `lab/provision-nss.sh`,
`lab/kill/sign-command.sh` (reused as-is).

## Risk assessment

- **R1 — dirty-state init failures.** Mitigated by Decision 4 (clean volume every run) + Decision 10
  (repeatability is an explicit acceptance test).
- **R2 — Zitadel init timing.** First boot runs migrations (~60–90 s). `setup.sh` polls discovery with
  a timeout and fails loudly if it never comes up (never proceeds to seed against a not-ready IdP).
- **R3 — PAT not written / seed call fails.** `seed-zitadel.sh` fails non-zero on any non-2xx or empty
  `client_id`; `setup.sh` aborts before writing a partial `.runtime-env` (FAIL LOUD — no silent
  fallback, no mock).
- **R4 — runtime-env not sourced → app uses the stale baked-in client_id.** The seeded app won't match
  the old id → login fails at discovery/authorize. Mitigated by making the wrapper `source` the file
  and by the verification step explicitly checking a fresh non-empty id is present and used.
- **R5 — secret leak in the commit.** `.gitignore` entries added *first* (Decision 11); R1-style
  `git status` grep before staging, same discipline as the `.deb` commit.
- **R6 — VM already runs a manually-seeded Zitadel on 8090.** `setup.sh`'s clean-slate step removes it
  and re-seeds; acceptable because the whole point is a reproducible-from-scratch instance. (The manual
  instance's hand-copied `client_id` in `config.js` stays only as a fallback; runtime-env overrides it.)

## Security considerations

- All seeded creds are **throwaway lab values** (`Test1234!`, `Admin12345!`, the masterkey) — already
  documented as non-secrets. The PAT is per-run, git-ignored, and removed by teardown.
- No app security posture changes (no app code touched): renderer isolation, mTLS cert selection,
  signed-kill verification, `safeStorage` token encryption all unchanged.
- Real IdP + real PKCE preserved (Decision 6) — the auth security is not weakened, only its *setup* is
  automated.
- FAIL LOUD retained end-to-end: no plaintext fallback, no mock IdP, no disabled TLS verification; any
  seeding failure aborts with a clear message for a joint decision.

## Definition of Done (this spike)

- [ ] `lab/setup.sh` brings up certs + NSS + nginx(:8443/:8444/:8445) + Zitadel + seeded
  Project/App/user + `lab/.runtime-env`, from clean, with zero console clicks.
- [ ] `lab/teardown.sh` returns the VM to "never ran DTL App" (app traces gone, prerequisites intact).
- [ ] Launch wrapper sources `lab/.runtime-env`; the packaged app picks up the fresh `client_id` +
  `DTL_KILL_CA_PATH` at runtime.
- [ ] Curl-verify all three nginx ports pass; Zitadel discovery + seeded-user API check pass.
- [ ] End-to-end: `teardown → setup → launch → testuser logs in` with no console interaction.
- [ ] Repeatability: a second `teardown → setup → login` cycle succeeds.
- [ ] No M0–M4/M1b app file modified; `.gitignore` updated; no secret staged.

## Next steps (after this spike is approved AND verified — NOT part of this spike)

Once one-command bring-up is proven, write the actual handoff deliverables for mhoang:
1. **Feature list** — the 5 core features + M1b access-outcome UI, mapped to their code.
2. **Multi-platform effort memo** — Windows (M5: Windows cert store + NSIS `.exe`), macOS (M6: Keychain
   + `.dmg`), mobile (separate codebase — iOS/WKWebView, the long pole) — sized against the
   `CertStore`-seam analysis already in `plans/roadmap.md` M5/M6.
3. **Handoff README** — "clone, run `lab/setup.sh`, launch" for a machine that has the prerequisites.

These are documentation deliverables built *on top of* the proven infra — deferred until the spike's
DoD is met. **Stop here for plan review (two-tier gate) — no scripts written yet.**
