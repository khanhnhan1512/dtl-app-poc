# DTL OIDC Lab — Local Zitadel IdP (M2 Step 1)

Per-machine lab infra. **Not committed to git.** Rebuild on each dev box from scratch
(same discipline as `lab/certs/`). The issuer is pinned to `http://127.0.0.1:8090` — it
must match the Electron app's `ISSUER_URL` exactly or token `iss` validation fails (R1).

Admin creds (throwaway local only — not real secrets):
- Username / email: `admin` / `admin@localhost.local`
- Password: `Admin12345!`

Loopback callback port the Electron app will use: **`51234`**
(registered as `http://127.0.0.1:51234/callback` in Zitadel — see Manual steps below).

> **VM-specific note:** `podman compose` fails on this VM due to rootless systemd D-Bus issues
> (pod cgroups + bridge network routing both fail). The `podman run` commands below are the
> definitive path for this machine. `compose.yml` is kept for machines where compose works.
> Port 8080 is taken on this VM; Zitadel runs on **8090** here.

> **Image pinning:** Use `v2.71.10` — do NOT use `:latest` (v4 moved the login UI to a separate
> "Login V2" app; `/ui/console` returns 404 in a single-container setup).

> **safeStorage / `--password-store=basic` (NoMachine sessions):** In a NoMachine remote session the
> gnome-keyring daemon is not auto-unlocked, so `safeStorage.isEncryptionAvailable()` returns `false`
> and `encryptString()` throws. The fix is to run Electron with `--password-store=basic`, which forces
> the built-in `basic_text` backend (no keyring needed, `isEncryptionAvailable()` returns `true`).
> Tokens are Chromium-encrypted with the basic_text key (obfuscated, not keyring-backed — Decision 8 /
> F4 PoC limitation; acceptable for PoC). On a physical desktop with an unlocked gnome-keyring, omit the
> flag and safeStorage uses libsecret automatically (real OS keyring encryption).

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

```bash
cd ~/Downloads/dtl-app

dbus-run-session -- bash -c '
  eval $(gnome-keyring-daemon --start --components=secrets)
  GNOME_DESKTOP_SESSION_ID=this-is-deprecated ELECTRON_DISABLE_SANDBOX=1 \
    ./node_modules/.bin/electron . --login
'
```

`dbus-run-session` creates a private D-Bus session bus. `gnome-keyring-daemon --start`
registers the full `org.freedesktop.secrets.Service` on it (this time WITH `DISPLAY` set, so
it initialises the full interface). Electron, launched into the same private bus, selects
`gnome_libsecret` and gets `isEncryptionAvailable() = true`.

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
