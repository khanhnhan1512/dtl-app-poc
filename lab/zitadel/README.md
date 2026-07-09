# DTL OIDC Lab — Local Zitadel IdP (M2 Step 1)

Per-machine lab infra. **Not committed to git.** Rebuild on each dev box from scratch
(same discipline as `lab/certs/`). The issuer is pinned to `http://127.0.0.1:8090` — it
must match the Electron app's `ISSUER_URL` exactly or token `iss` validation fails (R1).

Admin creds (throwaway local only — not real secrets):
- Username / email: `admin` / `admin@localhost.local`
- Password: `Admin12345!`

Loopback callback port the Electron app will use: **`51234`**
(registered as `http://127.0.0.1:51234/callback` in Zitadel).

---

## ⚡ AUTOMATED PATH (preferred) — `lab/setup.sh`

**The manual BRING UP + MANUAL web-console steps below are now superseded by `lab/setup.sh`**, which
stands up the *entire* lab (certs, NSS, nginx, Postgres, Zitadel) **and auto-seeds** the Project +
Native PKCE App + `testuser@dtl.local` with **zero web-console clicks**. It writes the fresh
`client_id` into `lab/.runtime-env` (per-machine, git-ignored).

```bash
cd ~/Downloads/dtl-app
bash lab/setup.sh        # one command — certs → nginx(:8443/:8444/:8445) → Zitadel → seeded app+user
```

> **⚠️ ONE-WAY DOOR:** `setup.sh` starts by tearing down any existing manually-seeded Zitadel and
> re-seeding from a clean Postgres volume (reproducible-from-scratch). Running it **destroys the old
> hand-built instance and its hand-copied `client_id`** — only run it when you're ready to switch.

**Launch after setup — one command, no keyring prompt** (run from the NoMachine DESKTOP terminal):

```bash
cd ~/Downloads/dtl-app
bash lab/run-app.sh          # sources lab/.runtime-env + unlocks the keyring silently → launches
```

`run-app.sh` is the single source of truth for the launch wrapper. It sources `lab/.runtime-env`
(fresh `client_id` + absolute `DTL_KILL_CA_PATH` — a `.deb` never reads a build-time `.env`), then
does a **two-step keyring bootstrap** so `safeStorage` gets a real `gnome_libsecret` backend with
**no GUI dialog of any kind** — neither "Unlock Keyring" nor "Choose password for NEW keyring":

```bash
# 1. Unlock any EXISTING default collection with an empty password (no-op if none exists yet).
eval $(echo -n "" | gnome-keyring-daemon --unlock --components=secrets,pkcs11,ssh)
# 2. If no default collection exists at all, CREATE one with an empty password — non-interactively.
#    (--unlock alone does NOT do this: it only unlocks, confirmed empirically. Without this step,
#    the app's first safeStorage write hits the Secret Service's normal create-collection path,
#    which pops the interactive gcr-prompter "Choose password for NEW keyring" dialog.)
python3 lab/ensure-keyring.py
# Do NOT swap either step for --password-store=basic: that bypasses the OS keyring and DOWNGRADES
# token encryption. We remove only the PROMPT (an environment property), never the encryption.
```

`lab/ensure-keyring.py` uses the legacy `org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface
.CreateWithMasterPassword` D-Bus method — the one escape hatch that creates a collection with a
given password (here: empty) with **zero prompt**, unlike the normal `CreateCollection` path.
Verified end-to-end on this VM: fresh box (`~/.local/share/keyrings/` removed entirely), across
multiple independent relaunches — zero prompts, secrets store and read back correctly every time.

> Requires `python3-dbus` (checked by `lab/setup.sh` preflight). If you ever hit a keyring dialog
> anyway, run `bash lab/teardown.sh` then `bash lab/setup.sh` to reset to the verified clean state.
>
> Packaged `.deb`: `DTL_APP_BIN="<unpacked>/opt/DTL App/dtl-app" bash lab/run-app.sh`.

Tear it all back down (returns the VM to "never ran DTL App"): `bash lab/teardown.sh`.

> The manual `podman run` BRING UP and the click-through **MANUAL — Zitadel web UI steps** further
> below are kept only as **fallback / reference** for a machine where `setup.sh` can't run. On a normal
> VM, use `setup.sh` and skip them.

---

> **VM-specific note:** `podman compose` fails on this VM due to rootless systemd D-Bus issues
> (pod cgroups + bridge network routing both fail). The `podman run` commands below are the
> definitive path for this machine. `compose.yml` is kept for machines where compose works.
> Port 8080 is taken on this VM; Zitadel runs on **8090** here.

> **Image pinning:** Use `v2.71.10` — do NOT use `:latest` (v4 moved the login UI to a separate
> "Login V2" app; `/ui/console` returns 404 in a single-container setup).

> **safeStorage (NoMachine sessions):** In a NoMachine remote session the gnome-keyring daemon is not
> auto-unlocked, so `safeStorage.isEncryptionAvailable()` returns `false` and `encryptString()` throws.
> **The correct fix is the `lab/run-app.sh` wrapper** — a private `dbus-run-session` + a non-interactive
> `gnome-keyring-daemon --unlock` (empty password) **plus `lab/ensure-keyring.py`** (creates the default
> collection with an empty password if none exists — `--unlock` alone only unlocks an *existing* one).
> Together they open a real `gnome_libsecret` keyring **silently** and give `isEncryptionAvailable() =
> true` with **no dialog of any kind** (neither "Unlock Keyring" nor "Choose password for NEW keyring").
> Do **NOT** use `--password-store=basic`: it forces the `basic_text` backend and **downgrades** token
> encryption off the OS keyring (an app-feature downgrade, not just an environment tweak). We keep real
> keyring encryption and remove only the *prompt*. On a physical desktop with an already-unlocked
> gnome-keyring, the plain launch works and safeStorage uses libsecret automatically.

---

## BRING UP (this VM — `podman run` path)

```bash
# 1. Pull images (once):
podman pull postgres:16-alpine
podman pull ghcr.io/zitadel/zitadel:v2.71.10

# 2. Start Postgres on host network (survives reboots when restarted):
podman run -d \
  --name zitadel-db \
  --network=host \
  -e POSTGRES_USER=root \
  -e POSTGRES_PASSWORD=rootpassword \
  -v zitadel-db:/var/lib/postgresql/data \
  postgres:16-alpine

# 3. Wait ~15 s for Postgres to be ready:
sleep 15 && podman exec zitadel-db pg_isready -U root

# 4. Start Zitadel on host network, port 8090:
podman run -d \
  --name zitadel \
  --network=host \
  -e ZITADEL_DATABASE_POSTGRES_HOST=127.0.0.1 \
  -e ZITADEL_DATABASE_POSTGRES_PORT=5432 \
  -e ZITADEL_DATABASE_POSTGRES_DATABASE=zitadel \
  -e ZITADEL_DATABASE_POSTGRES_USER_USERNAME=zitadel \
  -e ZITADEL_DATABASE_POSTGRES_USER_PASSWORD=zitadel \
  -e ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE=disable \
  -e ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME=root \
  -e ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD=rootpassword \
  -e ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE=disable \
  -e ZITADEL_EXTERNALDOMAIN=127.0.0.1 \
  -e ZITADEL_EXTERNALPORT=8090 \
  -e ZITADEL_EXTERNALSECURE=false \
  -e "ZITADEL_MASTERKEY=MasterkeyNeedsToHave32Characters" \
  -e ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME=admin \
  -e ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL_ADDRESS=admin@localhost.local \
  -e ZITADEL_FIRSTINSTANCE_ORG_HUMAN_EMAIL_VERIFIED=true \
  -e "ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD=Admin12345!" \
  -e ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD_CHANGE_REQUIRED=false \
  ghcr.io/zitadel/zitadel:v2.71.10 \
  start-from-init --masterkeyFromEnv --tlsMode disabled --port 8090
```

**Wait for healthy — Zitadel runs DB migrations on first boot (~60 s):**

```bash
# Watch logs until you see "server is listening":
podman logs -f zitadel
# Ctrl-C once you see: level=INFO msg="server is listening" address=[::]:8090

# Or poll the discovery endpoint:
until curl -sf http://127.0.0.1:8090/.well-known/openid-configuration > /dev/null; do
  echo "waiting..."; sleep 5
done && echo "UP"
```

**If Zitadel exits immediately:**
```bash
podman logs zitadel    # look for migration or password errors
# If "PasswordComplexityPolicy.MinLength": password too short — use Admin12345! (already correct above)
# If port conflict: ss -tlnp | grep 8090
```

---

## RESTART (after container stop or VM reboot)

```bash
# Restart both containers (DB data is in the named volume — survives stop/start):
podman start zitadel-db
sleep 10
podman start zitadel

# Verify:
podman ps
curl -s http://127.0.0.1:8090/.well-known/openid-configuration | python3 -m json.tool | grep '"issuer"'
```

> **Note:** `podman start zitadel` works because the container already has the correct config baked
> in from the initial `podman run`. On a full-reset (volumes deleted), re-run BRING UP from scratch.

---

## MANUAL — Zitadel web UI steps

> These are click-through steps. Do them once after BRING UP completes and Zitadel is healthy.

Open **http://127.0.0.1:8090/ui/console** in the browser on this machine.

**Step 1 — Log in as admin**
- Username: `admin@localhost.local` (try just `admin` if that fails)
- Password: `Admin12345!`

**Step 2 — Identify the default organisation**
- Top-left menu → **Organizations** — there is already a default org (usually named **ZITADEL** or
  **Default-Organisation**). Do NOT create a new org; use this existing one.
- Click the default org → **Settings** (gear icon) — note the **Org ID** (UUID in the URL or the
  settings page). This should be `379670152104444547`.

**Step 3 — Create a project**
- While in the default org → **Projects** → **Create project**
- Name: `DTL App`

**Step 4 — Register the native PKCE app**
- Inside DTL App project → **Applications** → **Add application**
- Type: **Native** (not Web, not API)
- Name: `dtl-electron`
- Auth method: **PKCE** — confirm **no client secret** is shown
- Redirect URI: `http://127.0.0.1:51234/callback`
- Post-logout URI: *(leave blank)*
- Click **Save** — copy the **Client ID** shown (save it below).

**Step 5 — Create a test user**
- Ensure you are in the default org → **Users** → **New user**
- First name: `Test`, Last name: `User`
- Username: `testuser`
- Email: `testuser@dtl.local` → check **Email verified**
- Set initial password: `Test1234!` → uncheck "force change on next login"
- Click **Create**.

---

## Record these values (M2 Step 2 Electron config — already baked in)

These values are baked into `src/main/config.js` (all env-overridable via `DTL_OIDC_*`).
Recorded here for reference; no manual copy needed unless changing the lab setup.

```
ISSUER_URL=http://127.0.0.1:8090
CLIENT_ID=379679934110564995          # native PKCE app "dtl-electron" in the default Zitadel org
ORG=ZITADEL (default org, id 379670152104444547)
CALLBACK_PORT=51234
TEST_USER_EMAIL=testuser@dtl.local
TEST_USER_PASSWORD=Test1234!
```

> **Auth against the DEFAULT org:** we do NOT create a separate "DTL-PoC" org. The `dtl-electron` app
> lives in the default "ZITADEL" org (id `379670152104444547`). Org scoping is enforced at Zitadel
> (the client belongs to that org); the Electron Main-process claim check uses **email domain**
> (`email_verified === true` AND `email` ends with `@dtl.local`), NOT org-id — the org-id claim is
> absent for normal users and the scope that surfaces it hangs the v2 login page.

---

## VERIFY (lab-first gate — no Electron)

Do NOT start M2 Step 2 (Electron OIDC code) until all four pass.

### (a) Discovery endpoint returns the correct issuer

```bash
curl -s http://127.0.0.1:8090/.well-known/openid-configuration | python3 -m json.tool | grep '"issuer"'
# Expected: "issuer": "http://127.0.0.1:8090"
```

### (a2) Console UI is reachable (NOT 404)

```bash
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8090/ui/console
# Expected: 200 (or 30x redirect to a login page that itself returns 200). 404 = wrong image (v4+).
```

### (b) Zitadel login page loads in the browser

Open **http://127.0.0.1:8090** in the browser — Zitadel UI must render (not a network error).

### (c) Manual auth-code round-trip (proves OIDC flow end-to-end)

Substitute `<CLIENT_ID>` with the value from Step 4, then paste the full URL into the browser:

```
http://127.0.0.1:8090/oauth/v2/authorize?client_id=<CLIENT_ID>&redirect_uri=http%3A%2F%2F127.0.0.1%3A51234%2Fcallback&response_type=code&scope=openid%20profile%20email%20offline_access&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&state=manual-test-001&nonce=manual-test-nonce-001
```

*(The `code_challenge` above is the RFC 7636 example value — fine for a manual test.)*

1. Zitadel shows the login form → log in as `testuser@dtl.local` / `Test1234!`.
2. The browser tries to redirect to `http://127.0.0.1:51234/callback?code=...&state=manual-test-001`.
3. The page shows **"connection refused"** (nothing is listening on 51234 yet) — this is **expected and correct**.
4. Look at the browser address bar — you must see `?code=<some-code>&state=manual-test-001`.

All three checks pass → the Zitadel lab is ready. Proceed to M2 Step 2.

---

## TEAR DOWN

```bash
# Stop (keeps volumes — state and DB survive):
podman stop zitadel zitadel-db

# Full reset (deletes DB — must redo MANUAL steps after BRING UP):
podman rm -f zitadel zitadel-db
podman volume rm zitadel-db
```

---

## RUNNING THE ELECTRON APP ON THIS VM (token encryption / M2 Step 3)

### Why it's fiddly here

On a native GDM login, `pam_gnome_keyring.so` runs automatically and unlocks the `login`
keyring so libsecret (and Electron's `safeStorage`) can encrypt via the OS keyring.

On **NoMachine**, the PAM hook is absent (only `gdm-*` PAM files include it). The
gnome-keyring daemon that systemd starts at user-login runs **headless** (no `DISPLAY`) and
only registers a degraded `org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface` on
D-Bus — it does **NOT** expose `org.freedesktop.secrets.Service`. Electron's libsecret finds
the bus name and selects `gnome_libsecret` backend, but `isEncryptionAvailable()` returns
`false` because the Service interface is absent. Symptoms:

```
[token-store] storage backend      : gnome_libsecret
[token-store] encryption available : false   ← the headless daemon problem
```

### The working command (NoMachine desktop terminal only)

**Must run in the NoMachine terminal** — needs the session's `DISPLAY`. Do not run over SSH.
Prefer `bash lab/run-app.sh` (the automated path above); the expanded form is shown here for
reference. Note the two-step keyring bootstrap — `--unlock` (empty password) **plus**
`ensure-keyring.py` — **not** `--start` alone, so **no dialog of any kind** appears (see the
automated-path section above for why `--unlock` alone isn't enough, and why NOT `--password-store=basic`):

```bash
cd ~/Downloads/dtl-app
source lab/.runtime-env

dbus-run-session -- bash -c '
  eval $(echo -n "" | gnome-keyring-daemon --unlock --components=secrets,pkcs11,ssh)
  python3 lab/ensure-keyring.py
  GNOME_DESKTOP_SESSION_ID=this-is-deprecated ELECTRON_DISABLE_SANDBOX=1 \
    ./node_modules/.bin/electron . --login
'
```

`dbus-run-session` creates a private D-Bus session bus. `gnome-keyring-daemon --unlock` (empty
password on stdin) registers the full `org.freedesktop.secrets.Service` on it and unlocks the
default collection **if one already exists**. `ensure-keyring.py` then handles the case that trips
up `--unlock` alone: if NO default collection exists yet (e.g. right after `lab/teardown.sh`, or on
a machine that never had one), it creates one with an empty password via the legacy
`CreateWithMasterPassword` D-Bus call — the one creation path with **no GUI prompt**. Electron,
launched into the same private bus, then selects `gnome_libsecret` and gets
`isEncryptionAvailable() = true` with zero dialogs. (`--start` alone pops an "Unlock Keyring" dialog
when locked; `--unlock` alone without `ensure-keyring.py` pops a "Choose password for NEW keyring"
dialog when no collection exists yet — both confirmed empirically and both eliminated by this pairing.)

Expected output:
```
[token-store] logBackend() — storage backend      : gnome_libsecret
[token-store] logBackend() — encryption available : true
[login] PASS — email domain check passed
[token-store] save() — encryptString() SUCCEEDED, NNN bytes
[token-store] tokens.enc written to /home/khanhnhan/.config/DTL App/tokens.enc
[login] getValidAccessToken: returned valid token from store
```

Verify:
```bash
ls   ~/.config/"DTL App"/             # tokens.enc present; NO .keyfile
xxd  ~/.config/"DTL App"/tokens.enc | head -2  # binary — NOT {"access":"...
```

### Gotchas

| Gotcha | Reason |
|--------|--------|
| Do NOT use `--password-store=basic` | Forces `basic_text`; on Electron 42 `IsEncryptionAvailable()` returns `false` for it and `encryptString` throws. |
| `ELECTRON_DISABLE_SANDBOX=1` required | `chrome-sandbox` lacks SUID bit; user has no root. |
| `GNOME_DESKTOP_SESSION_ID=this-is-deprecated` required | Without it Electron sees no GNOME session and falls back to `basic_text`. |
| "gcr-prompter couldn't connect" / "Network service crashed" | Benign noise from the private D-Bus session; `encryptString` succeeds despite these lines. |
| After VM reboot | The headless systemd daemon returns. Re-run the `dbus-run-session` wrapper. |
| Native desktop / WSLg | No wrapping needed — `safeStorage` auto-picks `gnome_libsecret` with a working keyring. |

---

## WARNING — per-machine

This Zitadel instance is **local to this machine**. A home box or WSL environment must run
its own instance from scratch (re-run BRING UP) and redo the MANUAL steps.
The `compose.yml` is committed; the DB data (named volume `zitadel-db`) and any secrets are not.
